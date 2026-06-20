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
3. Execute `workflows/transcrever.sh` para gerar `data/outputs/audio_entrada.srt`, `.json`, `.vtt`, `.tsv` e `.txt`.
4. Execute `workflows/traduzir.sh` para gerar `data/outputs/audio_entrada.pt.srt`.
5. Execute `python3 scripts/extrair-texto.py` para criar `data/inputs/livro.txt` e `data/inputs/livro_capitulos.txt`.
6. Execute `workflows/gerar-audiobook.sh` para gerar o áudio final.

## Saídas esperadas

- `data/outputs/audio_entrada.srt` — legenda original em espanhol
- `data/outputs/audio_entrada.pt.srt` — legenda traduzida para português
- `data/inputs/livro.txt` — texto limpo em linha única por frase
- `data/inputs/livro_capitulos.txt` — texto com pausas visuais para leitura
- `data/outputs/<data>_<voz>_output.wav` — áudio final gerado pelo Piper

## Observações

- O fluxo agora considera um único arquivo de áudio de entrada (`audio_entrada.mp3`), em vez de múltiplas partes.
- Os scripts Python usam caminhos relativos à raiz do projeto, então podem ser executados de qualquer diretório.
- O arquivo principal de configuração do ambiente está em `setup/`.
- É recomendável manter os arquivos grandes em `data/` e não misturá-los com os scripts.
