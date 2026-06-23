# Project Order

## 1 - Transcrever
- Execute `workflows/1-transcrever.sh <arquivo_de_áudio> [output_base] [lingua] [model_size] [output_dir]`
- This step generates transcription artifacts in the output directory.
- Example: `bash workflows/1-transcrever.sh data/inputs/audio_entrada.mp3 audio_entrada es medium data/outputs`

## 2 - Traduzir
- Execute `workflows/2-traduzir.sh <arquivo_srt> [arquivo_srt_saida]`
- This step translates a Spanish SRT file to Portuguese.
- Example: `bash workflows/2-traduzir.sh data/outputs/audio_entrada.srt data/outputs/audio_entrada.pt.srt`

## 3 - Gerar Audiobook
- Execute `workflows/3-gerar-audiobook.sh <arquivo_srt> [arquivo_wav_saida]`
- This step generates the final audiobook audio from a translated SRT.
- Example: `bash workflows/3-gerar-audiobook.sh data/outputs/audio_entrada.pt.srt`

## E2E test assets
- E2E fixtures are stored under `data/e2e/`.
- The dedicated E2E path is used by `workflows/test-e2e.sh`.
- Internal workspace files should not be processed except for the E2E fixtures in `data/e2e/`.

## Notes
- `data/inputs/` and `data/outputs/` are reserved for normal pipeline input and output.
- `data/e2e/` is a dedicated folder for test assets and should be saved to git.
