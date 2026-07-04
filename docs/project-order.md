# Ordem do Fluxo do Projeto

## Execucao recomendada (arquivo unico)
- Utilize apenas `workflows/exec.sh`.
- O script lista os videos disponiveis em `data/` para selecao na tela.
- Voce pode selecionar um unico video pelo numero ou digitar `T` para processar todos os videos listados.
- Depois da selecao, o `exec.sh` executa automaticamente todas as etapas do fluxo.
- O `exec.sh` preserva o nome original do vídeo (parte antes da extensão) durante todo o fluxo.

## Regras gerais
- Todo o trabalho com arquivos será executado dentro da pasta /data.
- O escopo de trabalho e configurado em `config/pipeline.ini` pela chave `data_root_relative`.
- `data_root_relative` aceita caminho absoluto (ex.: `/mnt/DOCS/ab-work`) ou relativo à raiz do projeto (ex.: `data`, `data/projeto-x`).
- O diretório configurado deve existir e permitir leitura/escrita para o usuário da execução.
- Logs, archive e `.pipeline-state/` são criados dentro do escopo configurado.
- O script `workflows/test-e2e.sh` também grava logs no mesmo escopo configurado.
- O nome do arquivo do vídeo utilizado inicialmente vai ditar o nome de todos os arquivos que serão gerados, e todos residem na mesma pasta.
- Exemplo com vídeo de entrada "Los três cerditos.mp4":
- Los três cerditos.wav (criado pela ferramenta de extração de áudio a partir do vídeo)
- Los três cerditos.mp3 (opcional: áudio restaurado manualmente para retomada)
- Los três cerditos.srt (criado pela ferramenta de transcrição whisper)
- Los três cerditos.srtpt (criado pela ferramenta de tradução)
- Los três cerditos.pt.wav (novo áudio criado pela ferramenta de criação de audiobook - piper)

## Etapa 0 — Extração do arquivo de áudio a partir do arquivo de vídeo
- Dado um vídeo em formato mkv ou mp4, deve-se extrair o áudio para um arquivo wav, na mesma pasta dentro de /data.
- Quando houver retomada (`resume_mode=1`), o fluxo pode reutilizar um arquivo `.mp3` válido com o mesmo nome-base em vez de reextrair `.wav`.
- No fluxo unico, esta etapa e executada pelo `workflows/exec.sh`.

## Etapa 1 - Indexação de entradas
- No fluxo unico, esta etapa e substituida pela selecao direta do video no `workflows/exec.sh`.

## Etapa 2 - Transcrição
- Gera apenas o artefato de transcrição `.srt` no mesmo diretório do arquivo de entrada.
- O idioma pode ser inferido pelo nome do arquivo (spanish/chinese) ou automático.
- No fluxo unico, esta etapa e executada pelo `workflows/exec.sh` apos a extracao.
- O fluxo valida se a transcricao existente cobre a duracao do audio antes de decidir reprocessar.

## Etapa 3 - Tradução
- Usa o SRT da etapa de transcrição para gerar `.srtpt` no mesmo diretório.
- No fluxo unico, esta etapa e executada pelo `workflows/exec.sh`.

## Etapa 4 - Geração de audiobook
- Usa o `.srtpt` traduzido para gerar o `.pt.wav` final no mesmo diretório.
- A voz usada no fluxo principal é Faber (`pt_BR-faber-medium.onnx`).
- No fluxo unico, esta etapa e executada pelo `workflows/exec.sh`.
- O fluxo valida se o `.pt.wav` atual cobre a timeline do SRT antes de decidir reprocessar.

## Ferramenta auxiliar 5 - Limpeza por arquivamento
- Não exclui arquivos: apenas move artefatos antigos para `archive/` na raiz do projeto.
- Move artefatos correspondentes (`.srt`, `.srtpt`, `.pt.wav`) quando já houver entrada `.wav`/`.mp3` relacionada em `data/`.
- No fluxo unico, esta etapa e opcional e controlada por `archive_on_start`.

## Controle de execução
- O fluxo grava estado por vídeo em `.pipeline-state/`.
- Cada etapa (`extract`, `transcribe`, `translate`, `audiobook`) registra status e detalhe.
- Em falha, a retomada começa na primeira etapa inválida no próximo run com `resume_mode=1`.

## Observações
- Os scripts por etapa `0` a `5` foram removidos.
- Para uso diario, prefira o fluxo unico via `workflows/exec.sh`.

## E2E
- Script: `workflows/test-e2e.sh`.
- Fixtures em `e2e/`.
- Entradas E2E principais: `e2e/e2e-test_spanish.wav` e `e2e/e2e-test_chinese.mp3`.
- O E2E escreve os artefatos de teste em `e2e/`.

## Observações de versionamento
- Todo o conteúdo de `data/` é ignorado no git.
- O diretório `models/` permanece fora de `data/` e concentra os modelos locais necessários.
