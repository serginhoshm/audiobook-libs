# Project Order

## Main Entry
- Use `bash workflows/exec.sh`.
- The script lists available videos in the configured scope from `config/pipeline.ini` (`data_root_relative`) and lets you choose one by number or all by typing `T`.
- `data_root_relative` accepts absolute paths (for external disks) or project-relative paths.
- Logs, archive, and `.pipeline-state/` are created under the configured scope.
- `workflows/test-e2e.sh` logs also follow the configured scope.
- After selection, it runs the full pipeline automatically: extract WAV, transcribe, translate, and generate `.pt.wav`.
- Before any processing step, `exec.sh` normalizes the video name to Portuguese and propagates that rename to all existing artifacts for the same video.
- With `resume_mode=1`, valid artifacts are reused and failed runs can resume from the first invalid step.
- Execution state is written to `.pipeline-state/`.
- If the video name is normalized, the resume state and already generated artifacts are migrated to the new stem.

## E2E test assets
- E2E fixtures are stored under `e2e/`.
- The dedicated E2E path is used by `workflows/test-e2e.sh`.
- Internal workspace files should not be processed except for the E2E fixtures in `e2e/`.

## Notes
- All normal pipeline execution is now orchestrated by `workflows/exec.sh`.
- `e2e/` is a dedicated folder for test assets and should be saved to git.
- Logs include timestamp and selected video context in log filenames.
- Voice synthesis is Faber-only (`pt_BR-faber-medium.onnx`).
