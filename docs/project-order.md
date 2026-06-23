# Ordem do fluxo do projeto

## Etapa 0 — Indexação dos arquivos de entrada
- Os arquivos devem ser colocados em `data/input/`.
- O script `workflows/0-indexar-inputs.sh` faz a leitura da pasta e registra cada arquivo em `workflows/jobs.md`.
- Cada registro recebe um `Job ID` numérico e um `Job Code`.

## Etapa 1 — Transcrição com Whisper
- A transcrição passa a executar por `job_id`, e não por caminho de arquivo direto.
- O script [workflows/1-transcrever.sh](workflows/1-transcrever.sh) resolve o arquivo no registro central (`workflows/jobs.md`).
- O idioma padrão continua `es` e o modelo padrão continua `medium`.
- A saída segue em `data/outputs/`, com base de nome contendo `job_id` e nome do arquivo.
- Os formatos gerados permanecem:
  - `.srt`
  - `.json`
  - `.vtt`
  - `.tsv`
  - `.txt`

## Etapa 2 — Tradução
- O script [workflows/2-traduzir.sh](workflows/2-traduzir.sh) também recebe `job_id`.
- A entrada é o `.srt` gerado para o job e a saída padrão é o `.pt.srt` do mesmo job.

## Etapa 3 — Geração do Audiobook
- O script [workflows/3-gerar-audiobook.sh](workflows/3-gerar-audiobook.sh) recebe `job_id`.
- A entrada é o `.pt.srt` do job e a saída padrão é um `.wav` com `job_id` no nome.

## Observações de implementação
- O registro central (`workflows/jobs.md`) é a base de referência para os workflows.
- O logging passa a incluir `job_id` e nome-base do arquivo nos nomes dos logs.
- Exceção: o fluxo E2E (`workflows/test-e2e.sh`) continua operando por caminho de arquivo explícito, em `data/e2e/`.
- A síntese de voz do fluxo principal usa somente o modelo Faber (`pt_BR-faber-medium.onnx`).
