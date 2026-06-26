#!/usr/bin/env python3

import argparse
import hashlib
import re
import shutil
import sys
import unicodedata
from pathlib import Path

from deep_translator import GoogleTranslator


MAX_STEM_LENGTH = 120

ARTIFACT_SUFFIXES = [
    ".wav",
    ".json",
    ".srt",
    ".tsv",
    ".txt",
    ".vtt",
    ".pt.srt",
    ".pt.wav",
]


def infer_source_lang(stem: str) -> str:
    lowered = stem.lower()
    if "spanish" in lowered:
        return "es"
    if "chinese" in lowered:
        return "zh-CN"
    return "auto"


def sanitize_name(text: str) -> str:
    text = unicodedata.normalize("NFKC", text)
    text = text.replace("_", " ").replace("-", " ")
    text = re.sub(r"[^0-9A-Za-zÀ-ÖØ-öø-ÿ() ]+", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def shorten_stem(stem: str, source_id: str) -> str:
    stem = sanitize_name(stem)
    if not stem:
        stem = "video"

    if len(stem) <= MAX_STEM_LENGTH:
        return stem

    digest = hashlib.sha1(source_id.encode("utf-8")).hexdigest()[:8]
    head_length = max(1, MAX_STEM_LENGTH - 9)
    head = stem[:head_length].rstrip()
    if not head:
        head = "video"
    return f"{head}-{digest}"


def translate_stem(stem: str) -> str:
    translator = GoogleTranslator(source=infer_source_lang(stem), target="pt")
    try:
        translated = translator.translate(stem)
    except Exception:
        translated = stem

    normalized = sanitize_name(translated)
    if not normalized:
        normalized = sanitize_name(stem)
    return normalized or "video"


def rel_dir_for(source_dir: Path, data_root: Path) -> Path:
    if source_dir == data_root:
        return Path("root")
    try:
        return source_dir.relative_to(data_root)
    except ValueError:
        sanitized = re.sub(r"[^A-Za-z0-9._/-]", "_", str(source_dir).lstrip("/"))
        return Path(f"external/{sanitized}")


def state_file_for(scope_rel: str, state_root: Path, video_path: Path) -> Path:
    state_id = hashlib.sha1(f"{scope_rel}|{video_path}".encode("utf-8")).hexdigest()
    return state_root / f"{state_id}.state"


def read_state_file(state_path: Path) -> dict[str, str]:
    state = {}
    if not state_path.exists():
        return state

    for line in state_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "\t" not in line:
            continue
        key, value = line.split("\t", 1)
        state[key] = value
    return state


def write_state_file(state_path: Path, state: dict[str, str]) -> None:
    state_path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"{key}\t{value}" for key, value in state.items()]
    state_path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")


def rename_if_exists(source: Path, target: Path) -> bool:
    if not source.exists() or source == target:
        return False
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(source), str(target))
    return True


def rename_related_files(base_dir: Path, old_stem: str, new_stem: str, video_suffix: str) -> None:
    for suffix in [video_suffix, *ARTIFACT_SUFFIXES]:
        rename_if_exists(base_dir / f"{old_stem}{suffix}", base_dir / f"{new_stem}{suffix}")


def rename_logs(logs_dir: Path, old_stem: str, new_stem: str) -> None:
    if not logs_dir.exists():
        return

    for entry in logs_dir.iterdir():
        if not entry.is_file():
            continue
        if old_stem not in entry.name:
            continue
        rename_if_exists(entry, entry.with_name(entry.name.replace(old_stem, new_stem, 1)))


def apply_state_updates(state: dict[str, str], old_video: Path, new_video: Path) -> dict[str, str]:
    updated = dict(state)
    updated["input_video"] = str(new_video)
    updated["audio_wav"] = str(new_video.with_suffix(".wav"))
    updated["output_srt"] = str(new_video.with_suffix(".srt"))
    updated["output_pt_srt"] = f"{new_video.with_suffix('').as_posix()}.pt.srt"
    updated["output_pt_wav"] = f"{new_video.with_suffix('').as_posix()}.pt.wav"
    if old_video != new_video:
        updated["renamed_from"] = str(old_video)
    return updated


def migrate_state(scope_rel: str, state_root: Path, old_video: Path, new_video: Path) -> None:
    old_state = state_file_for(scope_rel, state_root, old_video)
    new_state = state_file_for(scope_rel, state_root, new_video)

    merged = {}
    if new_state.exists():
        merged.update(read_state_file(new_state))
    if old_state.exists():
        merged.update(read_state_file(old_state))

    if not merged:
        return

    merged = apply_state_updates(merged, old_video, new_video)
    write_state_file(new_state, merged)

    if old_state.exists() and old_state != new_state:
        old_state.unlink()


def resolve_unique_stem(video_path: Path, data_root: Path, archive_root: Path, candidate_stem: str) -> str:
    source_dir = video_path.parent
    archive_dir = archive_root / rel_dir_for(source_dir, data_root)

    def target_exists(base_dir: Path, stem: str) -> bool:
        for suffix in [video_path.suffix, *ARTIFACT_SUFFIXES]:
            target = base_dir / f"{stem}{suffix}"
            if target.exists() and target != base_dir / f"{video_path.stem}{suffix}":
                return True
        return False

    unique_stem = shorten_stem(candidate_stem, str(video_path))
    counter = 2
    while target_exists(source_dir, unique_stem) or target_exists(archive_dir, unique_stem):
        unique_stem = shorten_stem(f"{candidate_stem} ({counter})", f"{video_path}|{counter}")
        counter += 1
    return unique_stem


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Normaliza nomes de vídeo e artefatos para português")
    parser.add_argument("--root-dir", type=Path, required=True)
    parser.add_argument("--data-root", type=Path, required=True)
    parser.add_argument("--archive-root", type=Path, required=True)
    parser.add_argument("--state-root", type=Path, required=True)
    parser.add_argument("--logs-dir", type=Path, required=True)
    parser.add_argument("--scope-rel", required=True)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument(
        "--lang-suffix",
        choices=["spanish", "chinese"],
        default="",
        help="Sufixo opcional de idioma original para anexar ao nome final.",
    )
    parser.add_argument("--preview", action="store_true", help="Apenas calcula o nome final, sem renomear arquivos")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    video_path = args.video

    if not video_path.exists():
        print(f"ERRO: arquivo de vídeo não encontrado: {video_path}", file=sys.stderr)
        return 1

    old_stem = video_path.stem
    normalized_stem = sanitize_name(translate_stem(old_stem))
    if args.lang_suffix and not normalized_stem.lower().endswith(f"_{args.lang_suffix}"):
        normalized_stem = f"{normalized_stem}_{args.lang_suffix}"
    unique_stem = resolve_unique_stem(video_path, args.data_root, args.archive_root, normalized_stem)

    if args.preview:
        preview_path = video_path.with_name(f"{unique_stem}{video_path.suffix}")
        print(str(preview_path))
        return 0

    if unique_stem == old_stem:
        migrate_state(args.scope_rel, args.state_root, video_path, video_path)
        print(str(video_path))
        return 0

    new_video_path = video_path.with_name(f"{unique_stem}{video_path.suffix}")
    print(f"NORMALIZANDO: {video_path.name} -> {new_video_path.name}", file=sys.stderr)

    rename_if_exists(video_path, new_video_path)

    source_dir = video_path.parent
    archive_dir = args.archive_root / rel_dir_for(source_dir, args.data_root)

    rename_related_files(source_dir, old_stem, unique_stem, video_path.suffix)
    rename_related_files(archive_dir, old_stem, unique_stem, video_path.suffix)
    rename_logs(args.logs_dir, old_stem, unique_stem)
    migrate_state(args.scope_rel, args.state_root, video_path, new_video_path)

    print(str(new_video_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())