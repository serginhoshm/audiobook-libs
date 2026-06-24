# Ordem do Fluxo do Projeto

## Execucao recomendada (arquivo unico)
- Utilize apenas `workflows/exec.sh`.
- O script lista os videos disponiveis em `data/` para selecao na tela.
- Voce pode selecionar um unico video pelo numero ou digitar `T` para processar todos os videos listados.
- Depois da selecao, o `exec.sh` executa automaticamente todas as etapas do fluxo.

## Regras gerais
- Todo o trabalho com arquivos será executado dentro da pasta /data.
- O nome do arquivo do vídeo utilizado inicialmente vai ditar o nome de todos os arquivos que serão gerados, e todos residem na mesma pasta.
- Exemplo com vídeo de entrada "Los três cerditos.mp4":
- Los três cerditos.wav (criado pela ferramenta de extração de áudio a partir do vídeo)
- Los três cerditos.json (criado pela ferramenta de transcrição whisper)
- Los três cerditos.srt (criado pela ferramenta de transcrição whisper)
- Los três cerditos.tsv (criado pela ferramenta de transcrição whisper)
- Los três cerditos.txt (criado pela ferramenta de transcrição whisper)
- Los três cerditos.vtt (criado pela ferramenta de transcrição whisper)
- Los três cerditos.pt.srt (criado pela ferramenta de tradução)
- Los três cerditos.pt.wav (novo áudio criado pela ferramenta de criação de audiobook - piper)

## Etapa 0 — Extração do arquivo de áudio a partir do arquivo de vídeo
- Dado um vídeo em formato mkv ou mp4, deve-se extrair o áudio para um arquivo wav, na mesma pasta dentro de /data.
- No fluxo unico, esta etapa e executada pelo `workflows/exec.sh`.

## Etapa 1 - Indexação de entradas
- No fluxo unico, esta etapa e substituida pela selecao direta do video no `workflows/exec.sh`.

## Etapa 2 - Transcrição
- Gera artefatos de transcrição no mesmo diretório do arquivo de entrada (`.json`, `.srt`, `.tsv`, `.txt`, `.vtt`).
- O idioma pode ser inferido pelo nome do arquivo (spanish/chinese) ou automático.
- No fluxo unico, esta etapa e executada pelo `workflows/exec.sh` apos a extracao.

## Etapa 3 - Tradução
- Usa o SRT da etapa de transcrição para gerar `.pt.srt` no mesmo diretório.
- No fluxo unico, esta etapa e executada pelo `workflows/exec.sh`.

## Etapa 4 - Geração de audiobook
- Usa o `.pt.srt` traduzido para gerar o `.pt.wav` final no mesmo diretório.
- A voz usada no fluxo principal é Faber (`pt_BR-faber-medium.onnx`).
- No fluxo unico, esta etapa e executada pelo `workflows/exec.sh`.

## Ferramenta auxiliar 5 - Limpeza por arquivamento
- Não exclui arquivos: apenas move artefatos antigos para `data/outputs/archive/`.
- Move artefatos correspondentes (`.json`, `.pt.srt`, `.srt`, `.tsv`, `.txt`, `.vtt`, `.pt.wav`) quando já houver entrada `.wav`/`.mp3` relacionada em `data/`.
- No fluxo unico, esta etapa e executada internamente pelo `workflows/exec.sh`.

## Observações
- Os scripts por etapa `0` a `5` foram removidos.
- Para uso diario, prefira o fluxo unico via `workflows/exec.sh`.

## E2E
- Script: `workflows/test-e2e.sh`.
- Fixtures em `data/e2e/`.
- Entradas E2E principais: `data/e2e/e2e-test_spanish.wav` e `data/e2e/e2e-test_chinese.mp3`.
- O E2E não usa `data/input/` nem `data/outputs/` para os artefatos do teste.

## Observações de versionamento
- `data/outputs/archive/` existe no repositório para manter estrutura.
- O conteúdo arquivado é ignorado no git; apenas arquivos de controle (`.gitkeep` e `.gitignore`) são versionados.
