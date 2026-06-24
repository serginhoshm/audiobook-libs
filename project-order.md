# Project Order

## Main Entry
- Use `bash workflows/exec.sh`.
- The script lists available videos in `data/` and lets you choose one by number or all by typing `T`.
- After selection, it runs the full pipeline automatically: archive old artifacts, extract WAV, transcribe, translate, and generate `.pt.wav`.

## E2E test assets
- E2E fixtures are stored under `e2e/`.
- The dedicated E2E path is used by `workflows/test-e2e.sh`.
- Internal workspace files should not be processed except for the E2E fixtures in `e2e/`.

## Notes
- All normal pipeline execution is now orchestrated by `workflows/exec.sh`.
- `e2e/` is a dedicated folder for test assets and should be saved to git.
- Logs include timestamp and selected video context in log filenames.
- Voice synthesis is Faber-only (`pt_BR-faber-medium.onnx`).
