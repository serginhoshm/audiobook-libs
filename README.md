# audiobook-libs

Este repositório reúne os scripts e os dados usados para transformar áudio em audiobook, com transcrição, tradução e síntese de voz.

## Estrutura

- `scripts/` — scripts Python do pipeline
- `workflows/` — scripts shell de orquestração (principal: `exec.sh`)
- `setup/` — instaladores e configuração do ambiente
- `data/` — pasta base de entrada e saída do fluxo
- `models/` — modelos de voz e arquivos de configuração
- `e2e/` — ativos e saídas de teste ponta a ponta
- `bin/` — executáveis locais, como o Piper

## Fluxo recomendado

1. Configure o ambiente com:
   - `setup/setup-whisper.sh`
   - `setup/setup-traducao.sh`
   - `setup/setup-piper.sh`
2. Coloque os arquivos de vídeo em `data/` (subpastas também são aceitas, exceto áreas reservadas como `data/saved`).
3. Execute `bash workflows/exec.sh`.
4. Na tela, selecione qual vídeo será processado pelo número, ou digite `T` para processar todos os vídeos listados.
5. O `exec.sh` executa automaticamente: limpeza por arquivamento, extração `.wav`, transcrição, tradução e geração do audiobook `.pt.wav`.

## Saídas esperadas

- `<mesma_pasta_do_video>/<nome_base>.wav` — áudio extraído do vídeo
- `<mesma_pasta_do_video>/<nome_base>.json` — metadados de transcrição
- `<mesma_pasta_do_video>/<nome_base>.srt` — legenda original
- `<mesma_pasta_do_video>/<nome_base>.tsv` — tabela de segmentos
- `<mesma_pasta_do_video>/<nome_base>.txt` — transcrição em texto
- `<mesma_pasta_do_video>/<nome_base>.vtt` — legenda VTT
- `<mesma_pasta_do_video>/<nome_base>.pt.srt` — legenda traduzida para português
- `<mesma_pasta_do_video>/<nome_base>.pt.wav` — audiobook final gerado pelo Piper

## Observações

- Os scripts Python usam caminhos relativos à raiz do projeto, então podem ser executados de qualquer diretório.
- O arquivo principal de configuração do ambiente está em `setup/`.
- É recomendável manter os arquivos grandes em `data/` e não misturá-los com os scripts.
- Os artefatos antigos movidos pelo fluxo são arquivados em `archive/` na raiz do projeto.
- Todo o conteúdo de `data/` é ignorado no git.

## E2E de referência

- Os ativos de teste ponta a ponta ficam em `e2e/`.
- Os arquivos de entrada dedicados do E2E (`e2e-test_spanish.wav` e `e2e-test_chinese.mp3`) ficam em `e2e/`.
- O teste escreve todos os artefatos de validação em `e2e/`.
- Execute `bash workflows/test-e2e.sh` para rodar a validação com os ativos `e2e/e2e-test_spanish.wav` e `e2e/e2e-test_chinese.mp3`.

## Execução única

- O fluxo principal está centralizado em `workflows/exec.sh`.
- O `exec.sh` suporta execução de um único vídeo (por número) ou de todos os vídeos (`T`).
- Os scripts shell por etapa (`0` a `5`) foram removidos para simplificar operação e manutenção.
- A síntese de voz utiliza somente a voz Faber (`pt_BR-faber-medium.onnx`).

## Mudanças recentes

- Adicionado orquestrador único `workflows/exec.sh` com seleção interativa de vídeo.
- Removido `scripts/extrair-texto.py` (obsoleto) e documentação atualizada para refletir essa remoção.
- `workflows/test-e2e.sh` atualizado para executar diretamente os scripts Python (`transcrever.py`, `traduzir.py`, `gerar-sincronizado.py`).
- Para síntese, mantenha os modelos da voz Faber em `models/` (arquivos `.onnx` e `.json`).
- Para executar o fluxo de verificação completa: rode `workflows/test-e2e.sh`.

Se desejar, posso também incluir um changelog separado em `CHANGES.md` ou detalhar exemplos de execução no final deste README.
