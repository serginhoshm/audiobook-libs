# audiobook-libs

Este repositório reúne os scripts e os dados usados para transformar áudio em audiobook, com transcrição, tradução e síntese de voz.

## Estrutura

- `scripts/` — scripts Python do pipeline
- `workflows/` — scripts shell que executam cada etapa do processo
- `setup/` — instaladores e configuração do ambiente
- `data/inputs/` — arquivos de entrada, como o áudio principal e textos intermediários
- `data/outputs/` — arquivos gerados ao longo do processo
- `data/models/` — modelos de voz e arquivos de configuração
- `bin/` — executáveis locais, como o Piper

## Fluxo recomendado

1. Configure o ambiente com:
   - `setup/setup-whisper.sh`
   - `setup/setup-traducao.sh`
   - `setup/setup-piper.sh`
2. Coloque o áudio de entrada em `data/inputs/audio_entrada.mp3`.
3. Execute `workflows/1-transcrever.sh <arquivo_de_áudio>` para gerar a transcrição em `data/outputs/`.
4. Execute `workflows/2-traduzir.sh <arquivo_srt>` para gerar a tradução em `data/outputs/`.
5. Execute `workflows/3-gerar-audiobook.sh <arquivo_srt>` para gerar o áudio final.

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
- O teste escreve todos os artefatos para `data/e2e/`, sem usar `data/inputs/` ou `data/outputs/`.
- Execute `bash workflows/test-e2e.sh` para rodar a validação com `data/e2e/mini_test.wav`.

## Mudanças recentes

- Adicionados wrappers em `workflows/` com logging estruturado e nomes de log com timestamp.
- Removido `scripts/extrair-texto.py` (obsoleto) e documentação atualizada para refletir essa remoção.
- Criado `workflows/test-e2e.sh` para validação ponta a ponta usando `data/e2e/mini_test.wav` como ativo de teste e escrevendo todos os resultados em `data/e2e/`.
- Ajustes e correções em `workflows/gerar-audiobook.sh` (tratamento de pipes, `set -o pipefail`, definição de `MODELO_CAMINHO`/`CONFIG_CAMINHO`).
- Para síntese, mantenha os modelos em `data/models/` (ex.: `pt_BR-faber-medium.onnx` e `.json`).
- Para executar o fluxo de verificação completa: rode `workflows/test-e2e.sh`.

Se desejar, posso também incluir um changelog separado em `CHANGES.md` ou detalhar exemplos de execução no final deste README.
