# audiobook-libs

This repository contains local tooling and assets for audiobook-related processing (transcription, translation, and voice synthesis), plus a Django web interface.

## Repository Structure

- `scripts/`: Python tools used by processing tasks.
- `workflows/`: shell wrappers. Only `webapp.sh` is actively kept.
- `setup/`: environment and dependency setup scripts.
- `config/`: pipeline and translation configuration files.
- `models/`: local voice/model assets.
- `e2e/`: end-to-end reference assets.
- `bin/`: local executables (for example, Piper).

## Current Execution Model

- Legacy workflow wrappers (`workflows/exec.sh`, `workflows/remux.sh`, `workflows/test-e2e*.sh`, `workflows/translate_srt.sh`, `workflows/youtube.sh`) were removed.
- The remaining shell entrypoint is `workflows/webapp.sh` for webapp lifecycle operations.
- Existing Python scripts remain in `scripts/` and can be invoked directly when needed.

## yt-dlp Setup

Use the dedicated bootstrap when you need to prepare the YouTube download path used by the webapp.

Recommended command:

```bash
bash setup/setup-ytdlp.sh
```

This setup validates and installs, when needed:

- `yt-dlp`
- `ffmpeg`
- a JavaScript runtime for YouTube extraction (`nodejs` or `deno`)

On immutable Fedora-style hosts, the script uses a single `rpm-ostree` transaction and asks for a reboot when packages are staged.

## Webapp (Django)

Recommended commands:

```bash
bash workflows/webapp.sh setup
bash workflows/webapp.sh start
bash workflows/webapp.sh status
bash workflows/webapp.sh stop
```

Additional notes:

- If no command is provided, `start` is used.
- `start` and `restart` run in LAN mode (`0.0.0.0`) by default.
- `start-lan` and `restart-lan` are available as compatibility aliases.
- Default port is `8000` and can be changed with `WEBAPP_PORT`.
- You can control allowed hosts using `DJANGO_ALLOWED_HOSTS`.

Manual evidence sync:

```bash
cd django_app
../.venv/bin/python manage.py sync_evidence --housekeeping
```

## Pipeline Download Stage

The webapp pipeline now starts with a `Download` stage for YouTube URLs added through the `Add` button.

Notes:

- Downloaded videos are normalized to MP4 before the rest of the pipeline runs.
- The pipeline enforces a 480p to 720p quality window.
- Downloaded assets use a date-based filename pattern: `YYYY-MM-DD-NNN.mp4`.
- The webapp stores source URL and source duration in SQLite for restart validation.
- Existing locally discovered MP4 assets are marked as `skipped` in the `Download` stage.

## Configuration

Main file:

- `config/pipeline.ini`

Scope setting:

- `data_root_relative` accepts absolute or project-relative paths.

## Translation Configuration

Gemini local key file:

- Versioned template: `config/translation/gemini.env.template`
- Local runtime file (gitignored): `config/translation/gemini.env`

Ollama local backend:

- Bluefin setup script: `bash setup/setup-ollama-bluefin.sh`
- Versioned template: `config/translation/ollama.env.template`
- Local runtime file (gitignored): `config/translation/ollama.env`
- Default model: `qwen2.5:14b`
- Backend name in webapp/pipeline: `ollama`
- `bash workflows/webapp.sh setup` executa bootstrap do Ollama automaticamente quando `TRANSLATION_BACKEND=ollama` (ou quando `config/translation/ollama.env` existe).

DeepL key template and runtime key rotation:

- Versioned template: `config/translation/deepl_keys_template.ini`
- Local runtime keys (gitignored): `config/translation/deepl_keys.ini`
- Runtime blocked-key state (gitignored): `config/translation/deepl_keys_state.ini`

When `deepl_doc` is selected, the pipeline rotates DeepL keys and falls back to Google only if all keys are exhausted/blocked.

NLLB (Hugging Face) backend option:

- Backend name in webapp/pipeline: `nllb_hf`
- Setup script: `bash setup/setup-nllb-hf.sh`
- Optional model override: `export NLLB_HF_MODEL=facebook/nllb-200-distilled-600M`

## Notes

- `data/` runtime contents are not required to be committed.
- `models/` remains outside `data/` and stores local model artifacts.
- This README reflects the current state after workflow-wrapper cleanup.

## GitHub Auth Note

- For SSH multi-account setup and repo-scoped fix used in this project, see `docs/GITHUB_SSH_MULTI_ACCOUNT.md`.
