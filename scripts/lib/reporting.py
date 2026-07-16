from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
import json
from pathlib import Path
from typing import Dict, List


@dataclass
class ExecutionReport:
    input_file: str
    output_file: str
    src_lang: str
    tgt_lang: str
    started_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    finished_at: str = ""
    total_blocks: int = 0
    total_windows: int = 0
    usage_by_backend: Dict[str, int] = field(default_factory=dict)
    fallback_count: int = 0
    suspicious_blocks: int = 0
    reprocessed_blocks: int = 0
    total_latency_ms: int = 0
    errors: List[str] = field(default_factory=list)

    def finalize(self) -> None:
        self.finished_at = datetime.now(timezone.utc).isoformat()


def write_report(report: ExecutionReport, report_path: Path) -> None:
    report_path.parent.mkdir(parents=True, exist_ok=True)
    with report_path.open("w", encoding="utf-8") as fh:
        json.dump(report.__dict__, fh, ensure_ascii=False, indent=2)
