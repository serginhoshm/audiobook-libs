# Project Order

## Main Entry
- Legacy workflow wrappers were removed.
- Use `bash workflows/webapp.sh` for webapp lifecycle operations.
- `workdir` accepts absolute paths (for external disks) or project-relative paths.
- `data_root_relative` remains as legacy alias during transition.
- Logs and `.pipeline-state/` are created under the configured scope.
- Execution state and evidence are written under the configured scope.

## E2E test assets
- E2E fixtures are stored under `e2e/`.
- Internal workspace files should not be processed except for the E2E fixtures in `e2e/`.

## Notes
- Legacy shell orchestration scripts were intentionally removed from `workflows/`.
- `e2e/` is a dedicated folder for test assets and should be saved to git.
- Logs include timestamp and selected video context in log filenames.
- Voice synthesis is Faber-only (`pt_BR-faber-medium.onnx`).
