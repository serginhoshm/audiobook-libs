from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
from typing import Dict, List


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", errors="replace")).hexdigest()


@dataclass
class CheckpointStore:
    checkpoint_path: Path

    def load(self) -> Dict[str, object]:
        if not self.checkpoint_path.exists():
            return {
                "version": 1,
                "source_hash": "",
                "translated_blocks": {},
                "completed_windows": [],
            }
        with self.checkpoint_path.open("r", encoding="utf-8") as fh:
            return json.load(fh)

    def save(self, payload: Dict[str, object]) -> None:
        self.checkpoint_path.parent.mkdir(parents=True, exist_ok=True)
        temp_path = self.checkpoint_path.with_suffix(self.checkpoint_path.suffix + ".tmp")
        with temp_path.open("w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=2)
        temp_path.replace(self.checkpoint_path)

    def init_or_resume(self, source_hash: str) -> Dict[str, object]:
        data = self.load()
        if data.get("source_hash") and data.get("source_hash") != source_hash:
            return {
                "version": 1,
                "source_hash": source_hash,
                "translated_blocks": {},
                "completed_windows": [],
            }
        data["version"] = 1
        data["source_hash"] = source_hash
        data.setdefault("translated_blocks", {})
        data.setdefault("completed_windows", [])
        return data

    @staticmethod
    def get_translated_block_ids(payload: Dict[str, object]) -> set[int]:
        block_map = payload.get("translated_blocks", {})
        return {int(k) for k in block_map.keys()}

    @staticmethod
    def set_block_translation(payload: Dict[str, object], block_id: int, lines: List[str]) -> None:
        block_map = payload.setdefault("translated_blocks", {})
        block_map[str(block_id)] = lines

    @staticmethod
    def mark_window_complete(payload: Dict[str, object], window_id: int) -> None:
        windows = payload.setdefault("completed_windows", [])
        if window_id not in windows:
            windows.append(window_id)
