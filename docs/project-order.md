# Project Processing Order

## Current Entry Point

- Legacy workflow wrapper scripts were removed.
- The currently maintained shell wrapper is `workflows/webapp.sh` for webapp lifecycle management.

## General Rules

- Runtime scope is configured in `config/pipeline.ini` via `data_root_relative`.
- `data_root_relative` accepts absolute paths (for external storage) or project-relative paths.
- The configured scope must exist and be writable by the running user.
- Logs, archive data, and `.pipeline-state/` are created under the configured scope.

## Processing Stages (Conceptual)

The repository still contains Python tools for the processing stages:

- Download from YouTube URL to MP4.
- Audio extraction from video.
- Transcription (`.srt`).
- Translation (`.srtpt`).
- Audiobook synthesis (`.pt.wav`).

These stages now rely on direct script execution and app integrations, not on legacy shell workflow wrappers.

## Runtime Control

- Per-video state is tracked in `.pipeline-state/`.
- Step status can be represented as `download`, `extract`, `transcribe`, `translate`, and `audiobook`.

## Versioning Notes

- Runtime outputs under `data/` are not intended for git tracking.
- `models/` stays outside runtime data folders and stores local model assets.
