#!/usr/bin/env python3

import argparse
from datetime import datetime, timezone
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
DEFAULT_GEMINI_MODEL = "gemini-1.5-flash"
DEFAULT_NLLB_MODEL_DIR = "models/nllb/facebook-nllb-200-distilled-600M"
DEFAULT_ZH_CALIBRATION_DIR = "config/translation/zh"
DEFAULT_ZH_GLOSSARY_LIMIT = 500
DEFAULT_NLLB_MAX_INPUT_LENGTH = 768
DEFAULT_NLLB_MAX_NEW_TOKENS = 192
DEFAULT_NLLB_USE_GPU = os.getenv("NLLB_USE_GPU", "1") == "1"
DEFAULT_NLLB_LEGACY_GENERATION = os.getenv("NLLB_LEGACY_GENERATION", "0") == "1"
CALIBRATION_PROFILE_FILE = "calibration_profile.json"
CALIBRATION_STATE_FILE = "calibration_state.json"
GLOSSARY_FILE = "glossary.json"
LOCAL_KNOWLEDGE_FILE = "local_knowledge.json"


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
        choices=["google", "nllb_local", "gemini"],
        default=os.getenv("TRANSLATION_BACKEND", DEFAULT_BACKEND),
        help="Backend de tradução: google (atual), nllb_local (offline) ou gemini (API Google).",
    )
    parser.add_argument(
        "--gemini-model",
        default=os.getenv("GEMINI_MODEL", DEFAULT_GEMINI_MODEL),
        help="Modelo Gemini usado no backend gemini.",
    )
    parser.add_argument(
        "--nllb-model-dir",
        type=Path,
        default=Path(os.getenv("NLLB_MODEL_DIR", DEFAULT_NLLB_MODEL_DIR)),
        help="Diretório local do modelo NLLB offline.",
    )
    parser.add_argument(
        "--nllb-max-input-length",
        type=int,
        default=int(os.getenv("NLLB_MAX_INPUT_LENGTH", str(DEFAULT_NLLB_MAX_INPUT_LENGTH))),
        help="Tamanho máximo de entrada para NLLB local.",
    )
    parser.add_argument(
        "--nllb-max-new-tokens",
        type=int,
        default=int(os.getenv("NLLB_MAX_NEW_TOKENS", str(DEFAULT_NLLB_MAX_NEW_TOKENS))),
        help="Máximo de novos tokens por geração no NLLB local.",
    )
    parser.add_argument(
        "--nllb-use-gpu",
        action="store_true",
        default=DEFAULT_NLLB_USE_GPU,
        help="Tenta usar GPU para acelerar o NLLB local (quando disponível).",
    )
    parser.add_argument(
        "--nllb-legacy-generation",
        action="store_true",
        default=DEFAULT_NLLB_LEGACY_GENERATION,
        help="Usa a geração antiga do NLLB (fallback).",
    )
    parser.add_argument(
        "--zh-calibration-dir",
        type=Path,
        default=Path(os.getenv("ZH_CALIBRATION_DIR", DEFAULT_ZH_CALIBRATION_DIR)),
        help="Diretório com perfil/glossário de calibração para chinês.",
    )
    parser.add_argument(
        "--zh-glossary-limit",
        type=int,
        default=int(os.getenv("ZH_GLOSSARY_LIMIT", str(DEFAULT_ZH_GLOSSARY_LIMIT))),
        help="Limite de entradas de glossário/contexto autoajustável para chinês.",
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


class GeminiBackendTranslator(BaseTranslator):
    def __init__(self, api_key, model_name, source_lang):
        if not normalize_text(api_key):
            raise ValueError("GEMINI_API_KEY nao definida para backend gemini.")

        try:
            import google.generativeai as genai
        except Exception as exc:
            raise RuntimeError(
                "Dependencia ausente para gemini. Rode setup/install_all.sh"
            ) from exc

        self._genai = genai
        self.source_lang = source_lang or "auto"
        self.model_name = normalize_text(model_name) or DEFAULT_GEMINI_MODEL
        genai.configure(api_key=api_key)
        self.model = genai.GenerativeModel(
            self.model_name,
            generation_config={"temperature": 0.0, "top_p": 1, "top_k": 1},
        )

    def translate(self, text):
        normalized = (text or "").strip()
        if not normalized:
            return ""

        prompt = (
            "Traduza do idioma de origem para portugues brasileiro. "
            "Responda apenas com a traducao, sem explicacoes. "
            "Preserve exatamente quaisquer marcadores no formato [[SRT-0001]], "
            "sem alterar indice, colchetes ou ordem. "
            f"Idioma de origem esperado: {self.source_lang}.\n\n"
            f"Texto:\n{normalized}"
        )
        response = self.model.generate_content(prompt)
        translated = normalize_text(getattr(response, "text", ""))
        if not translated:
            raise RuntimeError("Resposta vazia do backend Gemini.")
        return translated


class NLLBLocalTranslator(BaseTranslator):
    SOURCE_LANG_MAP = {
        "zh-cn": "zho_Hans",
        "es": "spa_Latn",
    }

    def __init__(
        self,
        model_dir,
        source_lang_key,
        max_input_length=DEFAULT_NLLB_MAX_INPUT_LENGTH,
        max_new_tokens=DEFAULT_NLLB_MAX_NEW_TOKENS,
        use_gpu=DEFAULT_NLLB_USE_GPU,
        legacy_generation=DEFAULT_NLLB_LEGACY_GENERATION,
    ):
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
        self.max_input_length = max(256, int(max_input_length))
        self.max_new_tokens = max(64, int(max_new_tokens))
        self.legacy_generation = bool(legacy_generation)
        self.device = "cuda" if (use_gpu and torch.cuda.is_available()) else "cpu"

        torch_dtype = torch.float16 if self.device == "cuda" else torch.float32
        self.tokenizer = AutoTokenizer.from_pretrained(str(model_dir), use_fast=False)
        self.model = AutoModelForSeq2SeqLM.from_pretrained(
            str(model_dir),
            torch_dtype=torch_dtype,
            low_cpu_mem_usage=True,
        )
        self.model.to(self.device)
        self.model.eval()

        if not self.legacy_generation:
            self.model.generation_config.max_length = None

        self.source_lang = self.SOURCE_LANG_MAP[source_lang_key]
        self.target_lang = "por_Latn"
        self.tokenizer.src_lang = self.source_lang
        self.forced_bos_token_id = self.tokenizer.convert_tokens_to_ids(self.target_lang)
        if self.forced_bos_token_id is None or self.forced_bos_token_id < 0:
            raise RuntimeError("Nao foi possivel resolver token de destino por_Latn")

        mode = "legacy" if self.legacy_generation else "fast"
        print(
            "[nllb_local] modo=%s device=%s max_input=%s max_new=%s"
            % (mode, self.device, self.max_input_length, self.max_new_tokens),
            flush=True,
        )

    def _prepare_inputs(self, normalized):
        inputs = self.tokenizer(
            normalized,
            return_tensors="pt",
            truncation=True,
            max_length=self.max_input_length,
        )
        if self.device != "cpu":
            inputs = {key: value.to(self.device) for key, value in inputs.items()}
        return inputs

    def _translate_legacy(self, inputs):
        input_len = int(inputs["input_ids"].shape[1])
        generation_max_length = min(2048, input_len + 512)
        output_tokens = self.model.generate(
            **inputs,
            forced_bos_token_id=self.forced_bos_token_id,
            max_length=generation_max_length,
        )
        return self.tokenizer.batch_decode(output_tokens, skip_special_tokens=True)[0]

    def _translate_fast(self, inputs):
        output_tokens = self.model.generate(
            **inputs,
            forced_bos_token_id=self.forced_bos_token_id,
            max_new_tokens=self.max_new_tokens,
            num_beams=1,
            do_sample=False,
        )
        return self.tokenizer.batch_decode(output_tokens, skip_special_tokens=True)[0]

    def translate(self, text):
        normalized = normalize_text(text)
        if not normalized:
            return normalized

        inputs = self._prepare_inputs(normalized)

        with self._torch.no_grad():
            if self.legacy_generation:
                translated = self._translate_legacy(inputs)
            else:
                translated = self._translate_fast(inputs)
        return translated


def build_translator(args, source_lang_key, source_lang_normalized):
    backend = args.backend

    if backend == "nllb_local":
        if source_lang_key == "auto":
            print("Aviso: source_lang=auto nao e suportado em nllb_local. Usando backend google.")
            return GoogleBackendTranslator(source_lang_normalized), "google"
        translator = NLLBLocalTranslator(
            args.nllb_model_dir,
            source_lang_key,
            max_input_length=args.nllb_max_input_length,
            max_new_tokens=args.nllb_max_new_tokens,
            use_gpu=args.nllb_use_gpu,
            legacy_generation=args.nllb_legacy_generation,
        )
        return translator, "nllb_local"

    if backend == "gemini":
        api_key = os.getenv("GEMINI_API_KEY", "")
        translator = GeminiBackendTranslator(
            api_key=api_key,
            model_name=args.gemini_model,
            source_lang=source_lang_normalized,
        )
        return translator, "gemini"

    return GoogleBackendTranslator(source_lang_normalized), "google"


def contains_cjk(text):
    return bool(re.search(r"[\u3400-\u9fff\uf900-\ufaff]", text or ""))


def load_json_file(path, default_value):
    if not path.exists():
        return default_value
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data
    except Exception:
        return default_value


def save_json_file(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2, sort_keys=True)


def enforce_dict_limit(mapping, limit):
    if limit <= 0:
        mapping.clear()
        return
    while len(mapping) > limit:
        first_key = next(iter(mapping))
        mapping.pop(first_key, None)


def merge_unique_glossary_entries(base_entries, extra_entries):
    merged = list(base_entries)
    seen = {
        (
            normalize_text(entry.get("source_regex", "")),
            normalize_text(entry.get("target", "")),
        )
        for entry in merged
        if isinstance(entry, dict)
    }

    for entry in extra_entries:
        if not isinstance(entry, dict):
            continue
        key = (
            normalize_text(entry.get("source_regex", "")),
            normalize_text(entry.get("target", "")),
        )
        if not all(key) or key in seen:
            continue
        merged.append(entry)
        seen.add(key)

    return merged


def merge_local_knowledge(profile, glossary, local_knowledge):
    local_global_replacements = local_knowledge.get("global_replacements", {})
    if isinstance(local_global_replacements, dict):
        profile_global = profile.setdefault("global_replacements", {})
        for wrong, correct in local_global_replacements.items():
            if wrong and correct:
                profile_global[wrong] = correct

    local_glossary_entries = local_knowledge.get("glossary_entries", [])
    if isinstance(local_glossary_entries, list):
        glossary_entries = glossary.setdefault("entries", [])
        glossary["entries"] = merge_unique_glossary_entries(glossary_entries, local_glossary_entries)


def scan_watch_patterns(text, watch_patterns):
    hits = []
    for pattern in watch_patterns:
        if not isinstance(pattern, dict):
            continue
        pattern_id = normalize_text(pattern.get("id", ""))
        regex = pattern.get("regex")
        if not pattern_id or not regex:
            continue
        try:
            if re.search(regex, text, flags=re.IGNORECASE):
                hits.append(pattern_id)
        except re.error:
            continue
    return hits


def load_zh_calibration_bundle(calibration_dir):
    profile_path = calibration_dir / CALIBRATION_PROFILE_FILE
    glossary_path = calibration_dir / GLOSSARY_FILE
    state_path = calibration_dir / CALIBRATION_STATE_FILE
    local_knowledge_path = calibration_dir / LOCAL_KNOWLEDGE_FILE

    profile_default = {"cases": [], "global_replacements": {}}
    glossary_default = {"entries": []}
    local_knowledge_default = {
        "global_replacements": {},
        "glossary_entries": [],
        "watch_patterns": [],
        "domain_terms_pt": [],
    }
    state_default = {
        "last_run": None,
        "backend": None,
        "active_replacements": {},
        "case_results": [],
        "auto_glossary": {},
        "watch_hits": {},
        "watch_samples": [],
    }

    profile = load_json_file(profile_path, profile_default)
    glossary = load_json_file(glossary_path, glossary_default)
    local_knowledge = load_json_file(local_knowledge_path, local_knowledge_default)
    state = load_json_file(state_path, state_default)

    merge_local_knowledge(profile, glossary, local_knowledge)

    return {
        "profile_path": profile_path,
        "glossary_path": glossary_path,
        "state_path": state_path,
        "local_knowledge_path": local_knowledge_path,
        "profile": profile,
        "glossary": glossary,
        "local_knowledge": local_knowledge,
        "state": state,
    }


def run_zh_precalibration(tradutor, profile):
    active_replacements = dict(profile.get("global_replacements", {}))
    case_results = []

    for case in profile.get("cases", []):
        source = normalize_text(case.get("source", ""))
        if not source:
            continue

        translated = normalize_text(translate_single_line(tradutor, source))
        translated_lower = translated.lower()

        forbid_hits = [term for term in case.get("forbid", []) if term.lower() in translated_lower]
        must_include = [term for term in case.get("must_include", []) if term.strip()]
        missing_terms = [term for term in must_include if term.lower() not in translated_lower]

        triggered = bool(forbid_hits or missing_terms)
        if triggered:
            for wrong, correct in case.get("preferred_replacements", {}).items():
                if wrong and correct:
                    active_replacements[wrong] = correct

        case_results.append(
            {
                "id": case.get("id", "case"),
                "source": source,
                "translated": translated,
                "triggered": triggered,
                "forbid_hits": forbid_hits,
                "missing_terms": missing_terms,
            }
        )

    return active_replacements, case_results


def apply_case_replacements(text, replacements):
    updated = text
    for wrong, correct in replacements.items():
        if wrong and correct:
            updated = updated.replace(wrong, correct)
    return updated


def apply_glossary_for_source(source_text, translated_text, glossary_entries):
    updated = translated_text
    for entry in glossary_entries:
        source_regex = entry.get("source_regex")
        target = normalize_text(entry.get("target", ""))
        forbidden_targets = [normalize_text(term) for term in entry.get("forbidden_targets", [])]
        if not source_regex or not re.search(source_regex, source_text):
            continue

        for forbidden in forbidden_targets:
            if forbidden:
                updated = re.sub(re.escape(forbidden), target, updated, flags=re.IGNORECASE)
    return updated


def update_auto_glossary(state, source_text, translated_text, limit):
    auto_glossary = state.setdefault("auto_glossary", {})
    src = normalize_text(source_text)
    tgt = normalize_text(translated_text)
    if not src or not tgt or not contains_cjk(src):
        return

    current = auto_glossary.get(src)
    if isinstance(current, dict):
        count = int(current.get("count", 0)) + 1
    else:
        count = 1

    auto_glossary[src] = {"target": tgt, "count": count}

    if len(auto_glossary) > limit:
        ranked = sorted(auto_glossary.items(), key=lambda item: int(item[1].get("count", 0)), reverse=True)
        trimmed = dict(ranked[:limit])
        auto_glossary.clear()
        auto_glossary.update(trimmed)


def get_auto_glossary_target(state, source_text):
    auto_glossary = state.get("auto_glossary", {})
    entry = auto_glossary.get(source_text)
    if isinstance(entry, dict):
        return normalize_text(entry.get("target", ""))
    if isinstance(entry, str):
        return normalize_text(entry)
    return ""


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
    calibration_bundle,
    glossary_limit,
):
    profile = calibration_bundle["profile"]
    glossary_entries = calibration_bundle["glossary"].get("entries", [])
    local_knowledge = calibration_bundle.get("local_knowledge", {})
    watch_patterns = local_knowledge.get("watch_patterns", [])
    state = calibration_bundle["state"]

    watch_hits = state.setdefault("watch_hits", {})
    watch_samples = state.setdefault("watch_samples", [])

    active_replacements, case_results = run_zh_precalibration(tradutor, profile)
    state["last_run"] = datetime.now(timezone.utc).isoformat()
    state["active_replacements"] = active_replacements
    state["case_results"] = case_results

    blocks = split_into_blocks(subtitles, block_max_lines, block_max_chars)
    total_blocks = len(blocks)

    for block_index, block in enumerate(
        tqdm(blocks, desc="[traducao]", unit="bloco", leave=False, disable=not sys.stderr.isatty()),
        start=1,
    ):
        block_texts = [normalize_text(subtitle.text) for subtitle in block]
        if all((text in source_memory) or get_auto_glossary_target(state, text) for text in block_texts if text):
            translated_lines = []
            for text in block_texts:
                cached = source_memory.get(text)
                if not cached:
                    cached = get_auto_glossary_target(state, text) or text
                translated_lines.append(cached)
        else:
            translated_lines = translate_block_text(tradutor, block, source_memory, block_max_chars)
            if translated_lines is None or len(translated_lines) != len(block):
                translated_lines = [translate_single_line(tradutor, text) for text in block_texts]

        for subtitle, source_text, translated_text in zip(block, block_texts, translated_lines):
            if translated_text:
                calibrated = apply_case_replacements(translated_text, active_replacements)
                calibrated = apply_glossary_for_source(source_text, calibrated, glossary_entries)
                for pattern_id in scan_watch_patterns(calibrated, watch_patterns):
                    watch_hits[pattern_id] = int(watch_hits.get(pattern_id, 0)) + 1
                    if len(watch_samples) < 200:
                        watch_samples.append(
                            {
                                "pattern": pattern_id,
                                "source": source_text,
                                "translated": calibrated,
                            }
                        )
                subtitle.text = calibrated
                source_memory[source_text] = calibrated
                update_auto_glossary(state, source_text, calibrated, glossary_limit)

        enforce_dict_limit(source_memory, glossary_limit)
        save_json_file(calibration_bundle["state_path"], state)

        save_translation_memory(memory_path, source_memory)

def translate_simple_srt(subtitles, tradutor):
    for subtitle in tqdm(subtitles, desc="[traducao]", unit="item", leave=False, disable=not sys.stderr.isatty()):
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
        calibration_bundle = load_zh_calibration_bundle(args.zh_calibration_dir)
        calibration_bundle["state"]["backend"] = selected_backend

        translate_chinese_srt(
            subtitles,
            tradutor,
            memory_path,
            max(1, args.block_max_lines),
            max(1, args.block_max_chars),
            translation_memory,
            calibration_bundle,
            max(1, args.zh_glossary_limit),
        )
        save_translation_memory(memory_path, translation_memory)
        save_json_file(calibration_bundle["state_path"], calibration_bundle["state"])
    else:
        translate_simple_srt(subtitles, tradutor)

    subtitles.save(str(output_path), encoding="utf-8")

    print(f"Concluído. Arquivo gerado em: {output_path}")


if __name__ == "__main__":
    main()
