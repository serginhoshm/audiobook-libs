# audiobook-libs

Este repositório reúne os scripts e os dados usados para transformar áudio em audiobook, com transcrição, tradução e síntese de voz.

## Estrutura

- `scripts/` — scripts Python do pipeline
- `workflows/` — scripts shell que executam cada etapa do processo
- `setup/` — instaladores e configuração do ambiente
- `data/input/` — arquivos de entrada para indexação de jobs
- `data/outputs/` — arquivos gerados ao longo do processo
- `data/models/` — modelos de voz e arquivos de configuração
- `bin/` — executáveis locais, como o Piper

## Fluxo recomendado

1. Configure o ambiente com:
   - `setup/setup-whisper.sh`
   - `setup/setup-traducao.sh`
   - `setup/setup-piper.sh`
2. Coloque os arquivos de entrada em `data/input/`.
3. Execute `workflows/0-indexar-inputs.sh` para registrar os arquivos em `workflows/jobs.md`.
4. Execute `workflows/1-transcrever.sh <job_id>` para gerar a transcrição em `data/outputs/`.
5. Execute `workflows/2-traduzir.sh <job_id>` para gerar a tradução em `data/outputs/`.
6. Execute `workflows/3-gerar-audiobook.sh <job_id>` para gerar o áudio final.

## Saídas esperadas

- `data/outputs/audio_entrada.srt` — legenda original em espanhol
- `data/outputs/audio_entrada.pt.srt` — legenda traduzida para português
- `data/outputs/<data>_<voz>_output.wav` — áudio final gerado pelo Piper

## Observações

- O fluxo agora considera um único arquivo de áudio de entrada (`audio_entrada.mp3`), em vez de múltiplas partes.
- Os scripts Python usam caminhos relativos à raiz do projeto, então podem ser executados de qualquer diretório.
- O arquivo principal de configuração do ambiente está em `setup/`.
- É recomendável manter os arquivos grandes em `data/` e não misturá-los com os scripts.

## E2E de referência

- Os ativos de teste ponta a ponta ficam em `data/e2e/`.
- O teste escreve todos os artefatos para `data/e2e/`, sem usar `data/input/` ou `data/outputs/`.
- Execute `bash workflows/test-e2e.sh` para rodar a validação com `data/e2e/mini_test.wav`.

## Registro central de jobs

- O arquivo `workflows/jobs.md` funciona como base central de entrada do pipeline.
- Cada registro possui `Job ID` numérico, `Job Code` e arquivo correspondente.
- Os logs e nomes de saída dos workflows passam a incluir `job_id` e nome-base do arquivo.
- A síntese de voz utiliza somente a voz Faber (`pt_BR-faber-medium.onnx`).

## Mudanças recentes

- Adicionados wrappers em `workflows/` com logging estruturado e nomes de log com timestamp.
- Removido `scripts/extrair-texto.py` (obsoleto) e documentação atualizada para refletir essa remoção.
- Criado `workflows/test-e2e.sh` para validação ponta a ponta usando `data/e2e/mini_test.wav` como ativo de teste e escrevendo todos os resultados em `data/e2e/`.
- Ajustes e correções em `workflows/3-gerar-audiobook.sh` (tratamento de pipes, `set -o pipefail`, definição de `MODELO_CAMINHO`/`CONFIG_CAMINHO`).
- Para síntese, mantenha os modelos da voz Faber em `data/models/` (arquivos `.onnx` e `.json`).
- Para executar o fluxo de verificação completa: rode `workflows/test-e2e.sh`.
- Adicionado `workflows/0-indexar-inputs.sh` para indexar arquivos de `data/input/` em `workflows/jobs.md`.

Se desejar, posso também incluir um changelog separado em `CHANGES.md` ou detalhar exemplos de execução no final deste README.
