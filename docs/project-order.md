# Ordem do fluxo do projeto

## Etapa 1 — Recebimento do áudio de entrada
- O arquivo de entrada esperado é `data/inputs/audio_entrada.mp3`.
- Este arquivo deve ser fornecido manualmente na pasta de entradas.
- O fluxo deve considerar esse nome fixo como a única entrada inicial do processo.
- A partir desta mudança, o áudio será tratado como um único arquivo, e não mais como quatro partes separadas.

## Etapa 2 — Transcrição com Whisper
- O áudio deve ser processado com Whisper para identificar o idioma e gerar a transcrição.
- Como o projeto está sendo preparado para trabalhar com áudio em espanhol, o idioma deve ser configurado como `es`.
- O mecanismo existente usa o script [workflows/1-transcrever.sh](workflows/1-transcrever.sh) e o modelo `medium`.
- A saída deve ser gerada na pasta `data/outputs/`.
- Como agora existe apenas um arquivo de áudio, a lógica deve processar uma única entrada e gerar os formatos abaixo, quando suportados pelo Whisper:
  - `.srt`
  - `.json`
  - `.vtt`
  - `.tsv`
  - `.txt`

## Etapa 3 — Preparação para os próximos passos
- O arquivo transcrito em texto será usado nas próximas etapas para tradução e síntese de voz.
- A partir deste ponto, o pipeline deve considerar apenas um resultado principal de transcrição, em vez de múltiplas partes.
- A próxima interação deve definir como o conteúdo será refinado, traduzido e convertido em áudio.

## Observações de implementação
- O script atual já usa a lógica de criação dos arquivos em múltiplos formatos, com base no modelo `faster-whisper`.
- A mudança principal é que o fluxo não deve mais depender de processar `parte1.mp3` a `parte4.mp3` como entradas separadas.
- O fluxo deve manter a saída em `data/outputs/` para evitar mistura entre entradas e artefatos processados.
- O nome fixo `audio_entrada.mp3` deve ser respeitado para manter consistência no pipeline.
- Em termos de lógica de processamento, a transcrição deve ser executada uma vez para o arquivo único, e os artefatos gerados devem representar esse mesmo áudio.
