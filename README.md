# audiobook-libs

Este repositório agora está organizado em pastas para scripts, configurações e dados.

## Estrutura

- `scripts/` — códigos Python usados no pipeline
- `workflows/` — scripts shell para executar cada etapa
- `setup/` — scripts de configuração do ambiente
- `data/inputs/` — arquivos de entrada e textos intermediários
- `data/outputs/` — arquivos gerados pelo processamento
- `data/models/` — modelos de voz e configurações
- `bin/` — executáveis locais, como o Piper

## Fluxo recomendado

1. Configure o ambiente com `setup/setup-traducao.sh`, `setup/setup-whisper.sh` e `setup/setup-piper.sh`
2. Coloque o arquivo de legenda em `data/inputs/input.srt`
3. Execute `workflows/traduzir.sh`
4. Execute `scripts/extrair-texto.py`
5. Gere o audiobook com `workflows/gerar-audiobook.sh`

## Observações

- Os scripts Python agora usam caminhos relativos à raiz do projeto, então podem ser executados a partir de qualquer diretório.
- Os artefatos gerados ficam em `data/outputs/` e os modelos em `data/models/`.
