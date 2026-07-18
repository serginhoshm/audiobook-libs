# Django Local Webapp - Detailed Implementation Plan

## 1. Overview

This document defines the implementation plan for a local Django web UI that manages media processing runs.

Primary goals:

- scan assets and manage run lifecycle from the browser
- configure per-file execution options in the UI
- run all operations without interactive terminal prompts
- provide shell bootstrap scripts for setup and operations

## 2. Recommended Project Layout

- keep executable Django code in `django_app/`
- keep planning docs in `docs/django-local-webapp/`

## 3. Data Model

### 3.1 `VideoAsset`

- `id`
- `file_path` (unique)
- `file_name`
- `extension`
- `size_bytes`
- `duration_seconds`
- `original_language`
- `discovered_at`
- `last_seen_at`
- `is_present`

### 3.2 `PipelineRun`

- `id`
- `video_asset` (FK)
- `status` (`discovered`, `queued`, `running`, `stopping`, `stopped`, `success`, `failed`, `skipped`)
- `started_at`
- `finished_at`
- `exit_code`
- `error_message`
- `log_file_path`
- `pid`
- `process_group_id`

### 3.3 `PipelineStepStatus`

- `id`
- `pipeline_run` (FK)
- `step_name` (`extract`, `transcribe`, `translate`, `audiobook`, `remux`)
- `status` (`pending`, `running`, `success`, `failed`, `skipped`)
- `detail`
- `updated_at`

### 3.4 `ExecutionProfile`

Per-file execution profile relation. Legacy translation backend options were removed because translation now uses the fixed robust chain in `scripts/translate_pipeline.py`.

## 4. Domain Services

### 4.1 Scan Service

- read configured data scope from `config/pipeline.ini`
- list candidate videos
- extract metadata (`ffprobe`)
- upsert `VideoAsset`
- mark missing files as `is_present=false` without deleting history

### 4.2 Queue Service

- enqueue selected runs
- prevent duplicate active runs per file

### 4.3 Runner Service

- launch subprocesses per file
- track pid/process group
- stream logs
- update step states
- map row options into execution arguments

### 4.4 Stop Service

- request graceful stop (`SIGTERM`)
- enforce timeout and fallback kill (`SIGKILL`) when needed

### 4.5 Reconciliation Service

- reconcile stale in-flight states when worker restarts
- refresh run state from evidence/log files

## 5. Worker

MVP strategy:

- local Django management command (`run_worker`)
- polling loop with short sleep
- single worker process semantics

## 6. API Endpoints

- `GET /api/videos`
- `POST /api/scan`
- `POST /api/runs/start`
- `POST /api/runs/stop`
- `GET /api/status`
- `PATCH /api/videos/{id}/options`

## 7. UI Requirements

Single main page with:

- toolbar (`Refresh`, `Start`, `Stop`)
- table with selectable rows
- per-row metadata, status chips, and option dropdowns

Behavior:

- start/stop acts only on selected rows
- buttons respect selection state
- status updates through polling
- option changes persist immediately

## 8. Log Parsing and Step Mapping

- parse log lines and map to step state transitions
- preserve compatibility with existing evidence/state files

## 9. Security and Reliability

- local-only bind by default
- validate file paths before execution
- sanitize API inputs
- persist command audit details in run logs

## 10. Testing Strategy

### Unit Tests

- scan service
- queue/stop behavior
- log parser

### Integration Tests

- `scan -> start -> status -> stop`
- worker restart reconciliation

## 11. Delivery Roadmap

### Sprint 1

- models + scan + basic list view

### Sprint 2

- queue/worker + start/stop

### Sprint 3

- step-level status + reconciliation

### Sprint 4

- UX refinements + filters/search + log export

## 12. Operational Bootstrap Scripts

Expected scripts:

- `scripts/webapp/setup_webapp.sh`
- `scripts/webapp/start_webapp.sh`
- `scripts/webapp/stop_webapp.sh`
- `scripts/webapp/status_webapp.sh`

Recommended conventions:

- pid files in `.run/webapp/`
- logs in `logs/webapp/`

## 13. Next Actions

1. Keep model and API contracts stable.
2. Finish worker robustness and reconciliation.
3. Improve list UX and option persistence feedback.
4. Expand test coverage for failure/restart scenarios.
