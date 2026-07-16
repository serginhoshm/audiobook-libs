from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import List


@dataclass
class SubtitleBlock:
    block_id: int
    pre_lines: List[str]
    timestamp_line: str | None
    text_lines: List[str]

    @property
    def is_translatable(self) -> bool:
        if self.timestamp_line is None:
            return False
        return any(line.strip() for line in self.text_lines)


@dataclass
class SubtitleDocument:
    subtitle_format: str
    blocks: List[SubtitleBlock]


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def _split_blocks(raw_text: str) -> List[List[str]]:
    lines = raw_text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    groups: List[List[str]] = []
    current: List[str] = []
    for line in lines:
        if line.strip() == "":
            if current:
                groups.append(current)
                current = []
            continue
        current.append(line)
    if current:
        groups.append(current)
    return groups


def _parse_group(block_id: int, group: List[str]) -> SubtitleBlock:
    timestamp_idx = -1
    for i, line in enumerate(group):
        if "-->" in line:
            timestamp_idx = i
            break

    if timestamp_idx == -1:
        return SubtitleBlock(
            block_id=block_id,
            pre_lines=group,
            timestamp_line=None,
            text_lines=[],
        )

    return SubtitleBlock(
        block_id=block_id,
        pre_lines=group[:timestamp_idx],
        timestamp_line=group[timestamp_idx],
        text_lines=group[timestamp_idx + 1 :],
    )


def load_subtitle(path: Path) -> SubtitleDocument:
    suffix = path.suffix.lower()
    if suffix not in {".srt", ".vtt"}:
        raise ValueError(f"Unsupported subtitle format: {suffix}")

    raw = _read_text(path)
    groups = _split_blocks(raw)
    blocks = [_parse_group(idx, group) for idx, group in enumerate(groups)]
    subtitle_format = "vtt" if suffix == ".vtt" else "srt"
    return SubtitleDocument(subtitle_format=subtitle_format, blocks=blocks)


def dump_subtitle(document: SubtitleDocument, output_path: Path) -> None:
    serialized_blocks: List[str] = []
    for block in document.blocks:
        lines: List[str] = []
        lines.extend(block.pre_lines)
        if block.timestamp_line is not None:
            lines.append(block.timestamp_line)
            lines.extend(block.text_lines)
        serialized_blocks.append("\n".join(lines).rstrip())

    content = "\n\n".join(serialized_blocks).rstrip() + "\n"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(content, encoding="utf-8")
