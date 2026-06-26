#!/usr/bin/env python3

import argparse
import json
import os
import re
import sys
from pathlib import Path

from deep_translator import GoogleTranslator
import pysrt
from tqdm import tqdm


DEFAULT_BLOCK_MAX_LINES = 20
DEFAULT_BLOCK_MAX_CHARS = 3500
TRANSLATION_MEMORY_SUFFIX = ".translation-memory.json"
MARKER_TEMPLATE = "[[SRT-{index:04d}]]"
DEFAULT_BACKEND = "google"
DEFAULT_NLLB_MODEL_DIR = "models/nllb/facebook-nllb-200-distilled-600M"


def parse_args():
    parser = argparse.ArgumentParser(
        description="Traduz um arquivo SRT para português brasileiro."
    )
    parser.add_argument("input_srt", type=Path, help="Arquivo SRT de entrada.")
    parser.add_argument("output_srt", type=Path, help="Arquivo SRT de saída traduzido.")
    parser.add_argument(
        "source_lang",
        nargs="?",
        default="auto",
        help="Idioma de origem (ex: es, zh-CN, auto).",
    )
    parser.add_argument(
        "--block-max-lines",
        type=int,
        default=DEFAULT_BLOCK_MAX_LINES,
        help="Quantidade máxima de legendas por bloco contextual.",
    )
    parser.add_argument(
        "--block-max-chars",
        type=int,
        default=DEFAULT_BLOCK_MAX_CHARS,
        help="Quantidade máxima aproximada de caracteres por bloco contextual.",
    )
    parser.add_argument(
        "--backend",
        choices=["google", "nllb_local"],
        default=os.getenv("TRANSLATION_BACKEND", DEFAULT_BACKEND),
        help="Backend de tradução: google (atual) ou nllb_local (offline).",
    )
    parser.add_argument(
        "--nllb-model-dir",
        type=Path,
        default=Path(os.getenv("NLLB_MODEL_DIR", DEFAULT_NLLB_MODEL_DIR)),
        help="Diretório local do modelo NLLB offline.",
    )
    return parser.parse_args()


def normalize_text(text):
    return re.sub(r"\s+", " ", (text or "").replace("\r", " ").replace("\n", " ")).strip()


def memory_path_for(output_path, backend, source_lang_key):
    safe_backend = normalize_text(backend).replace(" ", "_") or "backend"
    safe_lang = normalize_text(source_lang_key).replace(" ", "_") or "lang"
    return output_path.parent / f".{output_path.stem}.{safe_backend}.{safe_lang}{TRANSLATION_MEMORY_SUFFIX}"


class BaseTranslator:
    def translate(self, text):
        raise NotImplementedError()


class GoogleBackendTranslator(BaseTranslator):
    def __init__(self, source_lang):
        self.translator = GoogleTranslator(source=source_lang, target="pt")

    def translate(self, text):
        return self.translator.translate(text)


class NLLBLocalTranslator(BaseTranslator):
    SOURCE_LANG_MAP = {
        "zh-cn": "zho_Hans",
        "es": "spa_Latn",
    }

    def __init__(self, model_dir, source_lang_key):
        if source_lang_key not in self.SOURCE_LANG_MAP:
            raise ValueError(
                "Backend nllb_local suporta apenas source_lang es ou zh-CN."
            )
        if not model_dir.exists():
            raise FileNotFoundError(
                f"Diretorio de modelo NLLB nao encontrado: {model_dir}"
            )

        try:
            import torch
            from transformers import AutoModelForSeq2SeqLM, AutoTokenizer
        except Exception as exc:
            raise RuntimeError(
                "Dependencias ausentes para nllb_local. Rode setup/setup-nllb-local.sh"
            ) from exc

        self._torch = torch
        self.tokenizer = AutoTokenizer.from_pretrained(str(model_dir), use_fast=False)
        self.model = AutoModelForSeq2SeqLM.from_pretrained(str(model_dir))
        self.model.eval()

        self.source_lang = self.SOURCE_LANG_MAP[source_lang_key]
        self.target_lang = "por_Latn"
        self.tokenizer.src_lang = self.source_lang
        self.forced_bos_token_id = self.tokenizer.convert_tokens_to_ids(self.target_lang)
        if self.forced_bos_token_id is None or self.forced_bos_token_id < 0:
            raise RuntimeError("Nao foi possivel resolver token de destino por_Latn")

    def translate(self, text):
        normalized = normalize_text(text)
        if not normalized:
            return normalized

        inputs = self.tokenizer(
            normalized,
            return_tensors="pt",
            truncation=True,
            max_length=1024,
        )
        input_len = int(inputs["input_ids"].shape[1])
        generation_max_length = min(2048, input_len + 512)

        with self._torch.no_grad():
            output_tokens = self.model.generate(
                **inputs,
                forced_bos_token_id=self.forced_bos_token_id,
                max_length=generation_max_length,
            )
        translated = self.tokenizer.batch_decode(output_tokens, skip_special_tokens=True)[0]
        return translated


def build_translator(args, source_lang_key, source_lang_normalized):
    backend = args.backend

    if backend == "nllb_local":
        if source_lang_key == "auto":
            print("Aviso: source_lang=auto nao e suportado em nllb_local. Usando backend google.")
            return GoogleBackendTranslator(source_lang_normalized), "google"
        translator = NLLBLocalTranslator(args.nllb_model_dir, source_lang_key)
        return translator, "nllb_local"

    return GoogleBackendTranslator(source_lang_normalized), "google"


def load_translation_memory(memory_path):
    if not memory_path.exists():
        return {}

    try:
        with open(memory_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return {}

    if not isinstance(data, dict):
        return {}

    memory = {}
    for key, value in data.items():
        if isinstance(key, str) and isinstance(value, str):
            memory[key] = value
    return memory


def save_translation_memory(memory_path, memory):
    memory_path.parent.mkdir(parents=True, exist_ok=True)
    with open(memory_path, "w", encoding="utf-8") as f:
        json.dump(memory, f, ensure_ascii=False, indent=2, sort_keys=True)


def split_into_blocks(subtitles, max_lines, max_chars):
    blocks = []
    current_block = []
    current_chars = 0

    for subtitle in subtitles:
        text = normalize_text(subtitle.text)
        if not text:
            current_block.append(subtitle)
            continue

        would_exceed_lines = len(current_block) >= max_lines
        would_exceed_chars = current_block and (current_chars + len(text) > max_chars)
        if current_block and (would_exceed_lines or would_exceed_chars):
            blocks.append(current_block)
            current_block = []
            current_chars = 0

        current_block.append(subtitle)
        current_chars += len(text)

    if current_block:
        blocks.append(current_block)

    return blocks


def translate_single_line(tradutor, text):
    try:
        return normalize_text(tradutor.translate(text))
    except Exception:
        return text


def translate_block_text(tradutor, subtitles, source_memory, max_chars):
    payload_parts = []
    source_texts = []

    for index, subtitle in enumerate(subtitles, start=1):
        source_text = normalize_text(subtitle.text)
        source_texts.append(source_text)
        payload_parts.append(f"{MARKER_TEMPLATE.format(index=index)} {source_text}")

    payload = "\n".join(payload_parts)
    if len(subtitles) > 1 and len(payload) > max_chars:
        return None

    try:
        translated_payload = tradutor.translate(payload)
    except Exception:
        return None

    marker_regex = re.compile(r"\[\[SRT-(\d{4})\]\]")
    matches = list(marker_regex.finditer(translated_payload))
    if len(matches) != len(subtitles):
        return None

    translated_lines = []
    for position, match in enumerate(matches):
        start = match.end()
        end = matches[position + 1].start() if position + 1 < len(matches) else len(translated_payload)
        translated_text = normalize_text(translated_payload[start:end])
        if not translated_text:
            return None
        translated_lines.append(translated_text)

    for source_text, translated_text in zip(source_texts, translated_lines):
        if source_text and translated_text:
            source_memory[source_text] = translated_text

    return translated_lines


def translate_chinese_srt(
    subtitles,
    tradutor,
    memory_path,
    block_max_lines,
    block_max_chars,
    source_memory,
):
    blocks = split_into_blocks(subtitles, block_max_lines, block_max_chars)
    total_blocks = len(blocks)

    for block_index, block in enumerate(tqdm(blocks), start=1):
        block_texts = [normalize_text(subtitle.text) for subtitle in block]
        if all(text in source_memory for text in block_texts if text):
            translated_lines = [source_memory.get(text, text) for text in block_texts]
        else:
            translated_lines = translate_block_text(tradutor, block, source_memory, block_max_chars)
            if translated_lines is None or len(translated_lines) != len(block):
                translated_lines = [translate_single_line(tradutor, text) for text in block_texts]

        for subtitle, translated_text in zip(block, translated_lines):
            if translated_text:
                subtitle.text = translated_text

        save_translation_memory(memory_path, source_memory)
        print(f"Bloco {block_index}/{total_blocks} traduzido")


def translate_simple_srt(subtitles, tradutor):
    for subtitle in tqdm(subtitles):
        texto = normalize_text(subtitle.text)
        if not texto:
            continue

        try:
            subtitle.text = tradutor.translate(texto)
        except Exception:
            continue


def main():
    args = parse_args()
    input_path = args.input_srt
    output_path = args.output_srt

    source_lang = (args.source_lang or "").strip()
    source_lang_key = source_lang.lower()
    if source_lang_key not in {"es", "zh-cn", "auto"}:
        print("Erro: idioma de origem inválido. Use 'es', 'zh-CN' ou 'auto'.")
        sys.exit(1)

    if source_lang_key == "es":
        source_lang_normalized = "es"
    elif source_lang_key == "zh-cn":
        source_lang_normalized = "zh-CN"
    else:
        source_lang_normalized = "auto"

    if not input_path.exists():
        print(f"Erro: arquivo de entrada não encontrado: {input_path}")
        sys.exit(1)

    output_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        subtitles = pysrt.open(str(input_path), encoding="utf-8")
    except Exception:
        subtitles = pysrt.open(str(input_path), encoding="iso-8859-1")

    if len(subtitles) == 0:
        print(f"Erro: arquivo de entrada não possui legendas: {input_path}")
        sys.exit(1)

    tradutor, selected_backend = build_translator(args, source_lang_key, source_lang_normalized)

    if source_lang_key == "zh-cn":
        memory_path = memory_path_for(output_path, selected_backend, source_lang_key)
        translation_memory = load_translation_memory(memory_path)
        translate_chinese_srt(
            subtitles,
            tradutor,
            memory_path,
            max(1, args.block_max_lines),
            max(1, args.block_max_chars),
            translation_memory,
        )
        save_translation_memory(memory_path, translation_memory)
    else:
        translate_simple_srt(subtitles, tradutor)

    subtitles.save(str(output_path), encoding="utf-8")

    print(f"Concluído. Arquivo gerado em: {output_path}")


if __name__ == "__main__":
    main()
