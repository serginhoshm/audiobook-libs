# Project Order

## 0 - Index Input Files
- Place source files under `data/input/`.
- Execute `workflows/0-indexar-inputs.sh`.
- This step updates `workflows/jobs.md` with a numeric job id and file mapping.

## 1 - Transcrever
- Execute `workflows/1-transcrever.sh <job_id> [lingua] [model_size] [output_dir]`.
- This step reads the source file from `workflows/jobs.md` and generates transcription artifacts.
- Example: `bash workflows/1-transcrever.sh 0001 es medium data/outputs`

## 2 - Traduzir
- Execute `workflows/2-traduzir.sh <job_id> [artifacts_dir]`.
- This step translates the generated SRT for that job.
- Example: `bash workflows/2-traduzir.sh 0001`

## 3 - Gerar Audiobook
- Execute `workflows/3-gerar-audiobook.sh <job_id> [arquivo_wav_saida] [artifacts_dir]`.
- This step generates the final audiobook audio from the translated SRT for that job.
- Example: `bash workflows/3-gerar-audiobook.sh 0001`

## E2E test assets
- E2E fixtures are stored under `data/e2e/`.
- The dedicated E2E path is used by `workflows/test-e2e.sh`.
- Internal workspace files should not be processed except for the E2E fixtures in `data/e2e/`.

## Notes
- `data/input/` and `data/outputs/` are reserved for normal pipeline input and output.
- `data/e2e/` is a dedicated folder for test assets and should be saved to git.
- Logs include job id and source file base in log filenames.
- Voice synthesis is Faber-only (`pt_BR-faber-medium.onnx`).
