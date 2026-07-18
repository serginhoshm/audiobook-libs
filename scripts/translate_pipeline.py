#!/usr/bin/env python3

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
import sys
import textwrap
from typing import Dict, List

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from lib.checkpoint_store import CheckpointStore, sha256_text
from lib.quality_checks import choose_best_candidate, evaluate_candidate, validate_structure
from lib.reporting import ExecutionReport, write_report
from lib.subtitle_parser import SubtitleBlock, dump_subtitle, load_subtitle
from lib.translator_backends import (
    DeepTranslatorBackend,
    GoogleSimpleBackend,
    OllamaBackend,
    OrchestratorConfig,
    TranslationOrchestrator,
)


@dataclass
class Window:
    window_id: int
    block_ids: List[int]


def _ts() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def _log(message: str) -> None:
    print(f"[{_ts()}] {message}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Robust subtitle translation pipeline")
    parser.add_argument("--in", dest="input_file", type=Path, required=True, help="Input subtitle (.srt or .vtt)")
    parser.add_argument("--out", dest="output_file", type=Path, required=True, help="Output translated subtitle")
    parser.add_argument("--src", required=True, help="Source language code (explicit, e.g. en, es, zh-cn)")
    parser.add_argument("--tgt", default="pt", help="Target language code")
    parser.add_argument("--offline", action="store_true", help="Disable online backends")
    parser.add_argument("--strict-quality", action="store_true", help="Enable triple-compare for suspicious blocks")
    parser.add_argument("--window-blocks", type=int, default=40)
    parser.add_argument("--max-chars-window", type=int, default=3500)
    parser.add_argument("--retries-per-backend", type=int, default=3)
    parser.add_argument("--timeout-online", type=int, default=20)
    parser.add_argument("--timeout-local", type=int, default=45)
    parser.add_argument("--backoff-base", type=float, default=1.0)
    parser.add_argument("--jitter", type=float, default=0.2)
    parser.add_argument("--max-chars-per-line", type=int, default=42)
    parser.add_argument("--max-lines-per-block", type=int, default=2)
    parser.add_argument("--doubt-threshold", type=float, default=0.65)
    parser.add_argument("--ollama-host", default="http://127.0.0.1:11434")
    parser.add_argument("--ollama-model", default="qwen2.5:14b")
    parser.add_argument("--checkpoint", type=Path, default=None)
    parser.add_argument("--report", type=Path, default=None)
    return parser.parse_args()


def _validate_lang_code(code: str, arg_name: str) -> str:
    normalized = code.strip().lower()
    if normalized in {"", "auto", "unknown", "desconhecido"}:
        raise ValueError(
            f"{arg_name} must be an explicit language code compatible with the backend (for example: en, es, zh-cn, pt)."
        )
    return normalized


def _build_windows(blocks: List[SubtitleBlock], max_blocks: int, max_chars: int) -> List[Window]:
    windows: List[Window] = []
    current_ids: List[int] = []
    current_chars = 0
    window_id = 0

    translatable = [b for b in blocks if b.is_translatable]
    for block in translatable:
        block_chars = len("\n".join(block.text_lines))
        must_close = False
        if current_ids and len(current_ids) >= max_blocks:
            must_close = True
        if current_ids and (current_chars + block_chars) > max_chars:
            must_close = True

        if must_close:
            windows.append(Window(window_id=window_id, block_ids=current_ids))
            window_id += 1
            current_ids = []
            current_chars = 0

        current_ids.append(block.block_id)
        current_chars += block_chars

    if current_ids:
        windows.append(Window(window_id=window_id, block_ids=current_ids))

    return windows


def _normalize_subtitle_lines(text: str, max_chars_per_line: int, max_lines_per_block: int) -> List[str]:
    clean = "\n".join(line.strip() for line in text.splitlines() if line.strip())
    if not clean:
        return [""]

    wrapped: List[str] = []
    for paragraph in clean.split("\n"):
        wrapped.extend(textwrap.wrap(paragraph, width=max_chars_per_line) or [paragraph])

    if len(wrapped) > max_lines_per_block:
        merged = " ".join(wrapped)
        wrapped = textwrap.wrap(merged, width=max_chars_per_line)[:max_lines_per_block]
    return wrapped or [clean]


def _build_backends(args: argparse.Namespace) -> List[object]:
    backends: List[object] = []
    if not args.offline:
        backends.append(DeepTranslatorBackend())
        backends.append(GoogleSimpleBackend(timeout_seconds=args.timeout_online))
    backends.append(
        OllamaBackend(
            host=args.ollama_host,
            model=args.ollama_model,
            timeout_seconds=args.timeout_local,
        )
    )
    return backends


def _translate_with_triple_compare(
    text: str,
    src: str,
    tgt: str,
    backends: List[object],
    args: argparse.Namespace,
) -> Dict[str, object]:
    candidates: List[Dict[str, object]] = []
    for backend in backends:
        try:
            translated = backend.translate(text=text, src=src, tgt=tgt, context={"mode": "triple_compare"})
        except Exception:
            continue
        decision = evaluate_candidate(
            source_text=text,
            translated_text=translated,
            backend_name=backend.name,
            max_chars_per_line=args.max_chars_per_line,
            max_lines_per_block=args.max_lines_per_block,
        )
        candidates.append(
            {
                "backend": backend.name,
                "translated_text": translated,
                "decision": decision,
            }
        )

    if not candidates:
        raise RuntimeError("Triple-compare failed: no backend produced output")
    return choose_best_candidate(candidates)


def main() -> int:
    args = parse_args()
    args.src = _validate_lang_code(args.src, "--src")
    args.tgt = _validate_lang_code(args.tgt, "--tgt")

    if not args.input_file.exists():
        raise FileNotFoundError(f"Input file not found: {args.input_file}")

    source_doc = load_subtitle(args.input_file)
    blocks_by_id = {block.block_id: block for block in source_doc.blocks}
    windows = _build_windows(source_doc.blocks, args.window_blocks, args.max_chars_window)

    report = ExecutionReport(
        input_file=str(args.input_file),
        output_file=str(args.output_file),
        src_lang=args.src,
        tgt_lang=args.tgt,
        total_blocks=sum(1 for b in source_doc.blocks if b.is_translatable),
        total_windows=len(windows),
    )

    checkpoint_path = args.checkpoint or args.output_file.with_suffix(args.output_file.suffix + ".checkpoint.json")
    checkpoint_store = CheckpointStore(checkpoint_path=checkpoint_path)
    checkpoint_payload = checkpoint_store.init_or_resume(source_hash=sha256_text(args.input_file.read_text(encoding="utf-8", errors="replace")))

    backends = _build_backends(args)
    orchestrator = TranslationOrchestrator(
        config=OrchestratorConfig(
            retries_per_backend=args.retries_per_backend,
            backoff_base_seconds=args.backoff_base,
            jitter=args.jitter,
        ),
        backends=backends,
    )

    translated_ids = CheckpointStore.get_translated_block_ids(checkpoint_payload)
    for window in windows:
        if window.window_id in checkpoint_payload.get("completed_windows", []):
            continue

        for block_id in window.block_ids:
            if block_id in translated_ids:
                continue

            block = blocks_by_id[block_id]
            source_text = "\n".join(block.text_lines)

            result = orchestrator.translate(
                text=source_text,
                src=args.src,
                tgt=args.tgt,
                context={"window_id": window.window_id, "block_id": block_id},
            )
            decision = evaluate_candidate(
                source_text=source_text,
                translated_text=result.text,
                backend_name=result.backend,
                max_chars_per_line=args.max_chars_per_line,
                max_lines_per_block=args.max_lines_per_block,
            )

            selected_backend = result.backend
            selected_text = result.text
            if decision.suspicious and (args.strict_quality or decision.score < args.doubt_threshold):
                best = _translate_with_triple_compare(
                    text=source_text,
                    src=args.src,
                    tgt=args.tgt,
                    backends=backends,
                    args=args,
                )
                selected_backend = str(best["backend"])
                selected_text = str(best["translated_text"])
                report.reprocessed_blocks += 1

            report.usage_by_backend[selected_backend] = report.usage_by_backend.get(selected_backend, 0) + 1
            if selected_backend != "deep_translator":
                report.fallback_count += 1
            if decision.suspicious:
                report.suspicious_blocks += 1
            report.total_latency_ms += result.latency_ms

            normalized_lines = _normalize_subtitle_lines(
                selected_text,
                max_chars_per_line=args.max_chars_per_line,
                max_lines_per_block=args.max_lines_per_block,
            )
            CheckpointStore.set_block_translation(checkpoint_payload, block_id, normalized_lines)
            checkpoint_store.save(checkpoint_payload)

        CheckpointStore.mark_window_complete(checkpoint_payload, window.window_id)
        checkpoint_store.save(checkpoint_payload)

    translated_doc = load_subtitle(args.input_file)
    translated_map = checkpoint_payload.get("translated_blocks", {})
    for block in translated_doc.blocks:
        stored = translated_map.get(str(block.block_id))
        if stored is not None:
            block.text_lines = [str(line) for line in stored]

    structure_errors = validate_structure(source_doc, translated_doc)
    if structure_errors:
        report.errors.extend(structure_errors)
        report.finalize()
        report_path = args.report or Path("logs") / "translation" / f"report-{datetime.now().strftime('%Y%m%d-%H%M%S')}.json"
        write_report(report, report_path)
        raise RuntimeError("Structural validation failed: " + ", ".join(structure_errors))

    dump_subtitle(translated_doc, args.output_file)
    report.finalize()
    report_path = args.report or Path("logs") / "translation" / f"report-{datetime.now().strftime('%Y%m%d-%H%M%S')}.json"
    write_report(report, report_path)

    _log(f"DONE: translated file -> {args.output_file}")
    _log(f"REPORT: {report_path}")
    _log(f"CHECKPOINT: {checkpoint_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
