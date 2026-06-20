# audiobook-libs

Este repositório reúne os scripts e os dados usados para transformar legendas em audiobook com tradução e síntese de voz.

## Estrutura

- `scripts/` — scripts Python do pipeline
- `workflows/` — scripts shell que executam cada etapa do processo
- `setup/` — instaladores e configuração do ambiente
- `data/inputs/` — arquivos de entrada, textos intermediários e referências
- `data/outputs/` — arquivos gerados ao longo do processo
- `data/models/` — modelos de voz e arquivos de configuração
- `bin/` — executáveis locais, como o Piper

## Fluxo recomendado

1. Configure o ambiente com:
   - `setup/setup-traducao.sh`
   - `setup/setup-whisper.sh`
   - `setup/setup-piper.sh`
2. Coloque o arquivo de legenda em `data/inputs/input.srt`.
3. Execute `workflows/traduzir.sh` para gerar `data/outputs/output.srt`.
4. Execute `python3 scripts/extrair-texto.py` para criar `data/inputs/livro.txt` e `data/inputs/livro_capitulos.txt`.
5. Execute `workflows/gerar-audiobook.sh` para gerar o áudio final.

## Saídas esperadas

- `data/outputs/output.srt` — legenda traduzida
- `data/inputs/livro.txt` — texto limpo em linha única por frase
- `data/inputs/livro_capitulos.txt` — texto com pausas visuais para leitura
- `data/outputs/<data>_<voz>_output.wav` — áudio final gerado pelo Piper

## Observações

- Os scripts Python usam caminhos relativos à raiz do projeto, então podem ser executados de qualquer diretório.
- O arquivo principal de configuração do ambiente está em `setup/`.
- É recomendável manter os arquivos grandes em `data/` e não misturá-los com os scripts.
