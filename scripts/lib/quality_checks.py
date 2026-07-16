from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Dict, List

from lib.subtitle_parser import SubtitleDocument


CONTROL_CHAR_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")


@dataclass
class QualityDecision:
    accepted: bool
    suspicious: bool
    score: float
    reasons: List[str]
    selected_backend: str


def validate_structure(source_doc: SubtitleDocument, target_doc: SubtitleDocument) -> List[str]:
    reasons: List[str] = []
    if len(source_doc.blocks) != len(target_doc.blocks):
        reasons.append("block_count_changed")
        return reasons

    for idx, (source_block, target_block) in enumerate(zip(source_doc.blocks, target_doc.blocks)):
        if source_block.timestamp_line != target_block.timestamp_line:
            reasons.append(f"timestamp_changed_at_block_{idx}")
        if source_block.pre_lines != target_block.pre_lines:
            reasons.append(f"pre_lines_changed_at_block_{idx}")
    return reasons


def _line_and_length_penalty(text: str, max_chars_per_line: int, max_lines_per_block: int) -> float:
    lines = text.splitlines() or [text]
    over_chars = sum(max(0, len(line) - max_chars_per_line) for line in lines)
    over_lines = max(0, len(lines) - max_lines_per_block)
    return min(1.0, (over_chars / 200.0) + (over_lines * 0.2))


def evaluate_candidate(
    source_text: str,
    translated_text: str,
    backend_name: str,
    max_chars_per_line: int,
    max_lines_per_block: int,
) -> QualityDecision:
    reasons: List[str] = []
    suspicious = False
    accepted = True

    source_trim = source_text.strip()
    translated_trim = translated_text.strip()

    if source_trim and not translated_trim:
        accepted = False
        suspicious = True
        reasons.append("empty_translation")

    if CONTROL_CHAR_RE.search(translated_text):
        accepted = False
        suspicious = True
        reasons.append("unexpected_control_chars")

    source_len = max(1, len(source_trim))
    translated_len = len(translated_trim)
    ratio = translated_len / source_len

    if source_trim and ratio < 0.2:
        suspicious = True
        reasons.append("output_too_short")
    if source_trim and ratio > 4.0:
        suspicious = True
        reasons.append("output_too_long")

    penalty = _line_and_length_penalty(
        translated_text,
        max_chars_per_line=max_chars_per_line,
        max_lines_per_block=max_lines_per_block,
    )
    if penalty > 0.3:
        suspicious = True
        reasons.append("subtitle_readability_violation")

    score = 1.0
    score -= min(0.6, abs(1.0 - min(ratio, 1.0 / max(ratio, 1e-6))) * 0.5)
    score -= penalty * 0.4
    if suspicious:
        score -= 0.15
    if not accepted:
        score = min(score, 0.2)
    score = max(0.0, min(1.0, score))

    return QualityDecision(
        accepted=accepted,
        suspicious=suspicious,
        score=score,
        reasons=reasons,
        selected_backend=backend_name,
    )


def choose_best_candidate(candidates: List[Dict[str, object]]) -> Dict[str, object]:
    if not candidates:
        raise ValueError("No candidates provided")
    ranked = sorted(
        candidates,
        key=lambda c: (
            float(c["decision"].score),
            c["backend"] == "deep_translator",
            c["backend"] == "ollama_local",
        ),
        reverse=True,
    )
    return ranked[0]
