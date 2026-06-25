# audiobook-libs

Este repositório reúne os scripts e os dados usados para transformar áudio em audiobook, com transcrição, tradução e síntese de voz.

## Estrutura

- `scripts/` — scripts Python do pipeline
- `workflows/` — scripts shell de orquestração (principal: `exec.sh`)
- `setup/` — instaladores e configuração do ambiente
- `config/` — configuração do pipeline (ex.: `pipeline.ini`)
- `models/` — modelos de voz e arquivos de configuração
- `e2e/` — ativos e saídas de teste ponta a ponta
- `bin/` — executáveis locais, como o Piper

## Fluxo recomendado

1. Configure o ambiente com:
   - `setup/setup-whisper.sh`
   - `setup/setup-traducao.sh`
   - `setup/setup-piper.sh`
2. Defina no `config/pipeline.ini` o diretório de trabalho em `data_root_relative`.
3. Coloque os vídeos dentro desse diretório configurado.
4. Execute `bash workflows/exec.sh`.
5. Na tela, selecione qual vídeo será processado pelo número, ou digite `T` para processar todos os vídeos listados.
6. O `exec.sh` executa automaticamente: extração `.wav`, transcrição, tradução e geração do audiobook `.pt.wav`.

## Configuração de escopo e retomada

- Arquivo: `config/pipeline.ini`.
- `data_root_relative` define o diretório de trabalho para vídeos e artefatos.
- O valor pode ser absoluto (ex.: `/mnt/DOCS/ab-work`) ou relativo à raiz do projeto.
- O diretório configurado precisa existir e ter permissão de leitura e escrita.
- Logs, `archive` e `.pipeline-state` são gravados dentro do mesmo diretório configurado.
- O `workflows/test-e2e.sh` também grava seus logs nesse mesmo diretório configurado.
- `resume_mode=1` reutiliza artefatos válidos e retoma apenas da primeira etapa inválida.
- `archive_on_start=0` evita mover artefatos no início e preserva a capacidade de retomada.

Exemplo:

```ini
[paths]
data_root_relative = /mnt/DOCS/ab-work

[pipeline]
resume_mode = 1
archive_on_start = 0
```

Também é possível sobrescrever por variável de ambiente:
- `PIPELINE_CONFIG` para apontar para outro arquivo INI.

## Saídas esperadas

- `<work_root>/<nome_base>.wav` — áudio extraído do vídeo
- `<work_root>/<nome_base>.json` — metadados de transcrição
- `<work_root>/<nome_base>.srt` — legenda original
- `<work_root>/<nome_base>.tsv` — tabela de segmentos
- `<work_root>/<nome_base>.txt` — transcrição em texto
- `<work_root>/<nome_base>.vtt` — legenda VTT
- `<work_root>/<nome_base>.pt.srt` — legenda traduzida para português
- `<work_root>/<nome_base>.pt.wav` — audiobook final gerado pelo Piper
- `<work_root>/logs/` — logs de execução (`exec.sh` e `test-e2e.sh`)
- `<work_root>/archive/` — artefatos antigos (quando `archive_on_start=1`)
- `<work_root>/.pipeline-state/` — estado por vídeo para retomada

## Observações

- Os scripts Python usam caminhos relativos à raiz do projeto, então podem ser executados de qualquer diretório.
- O arquivo principal de configuração do ambiente está em `setup/`.
- Os arquivos de mídia podem ficar em um disco externo, desde que o `data_root_relative` aponte para esse local.
- O fluxo é idempotente: quando os artefatos já estão válidos, as etapas são reaproveitadas sem reprocessar.
- A pasta `data/` não é mais necessária para operação do pipeline principal.

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
