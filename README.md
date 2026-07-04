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
6. O `exec.sh` mantém o nome original do arquivo de vídeo (stem antes da extensão) durante todo o processamento.
7. Depois disso, o `exec.sh` executa automaticamente: extração `.wav`, transcrição, tradução e geração do audiobook `.pt.wav`.
8. Com `resume_mode=1`, a etapa de transcrição também aceita reutilizar áudio já existente em `.mp3` (além de `.wav`) para casos de restauração manual.

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

- `<work_root>/<nome_base>.wav` — áudio extraído do vídeo (padrão automático)
- `<work_root>/<nome_base>.mp3` — áudio de entrada alternativo aceito na retomada (`resume_mode=1`), útil para restauração manual
- `<work_root>/<nome_base>.srt` — legenda original
- `<work_root>/<nome_base>.srtpt` — legenda traduzida para português
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

## Backends de Tradução

- `google` (online)
- `nllb_local` (offline)
- `deepl_doc` (DeepL via `workflows/translate_srt.sh`)
- `gemini` (Google Gemini API)

### DeepL local (rotacao de chaves por bloco)

- Template versionado: `config/translation/deepl_keys_template.ini`
- Arquivo local real (ignorado): `config/translation/deepl_keys.ini`
- Estado local de bloqueio por cota (ignorado e gerado automaticamente): `config/translation/deepl_keys_state.ini`
- O backend `deepl_doc` alterna automaticamente entre as chaves a cada bloco/parte enviado para traducao.
- Se o DeepL retornar `HTTP 456` para uma chave, o fluxo marca a chave como indisponivel no estado local e tenta a proxima automaticamente.
- Antes de iniciar a traducao, o fluxo consulta `GET /v2/usage` para cada chave e ja bloqueia no estado local as chaves sem cota.
- Se a consulta `/usage` falhar de forma inconclusiva para uma chave, ela continua candidata (o fallback por `HTTP 456` cobre esse caso durante a traducao).

Opcao util para limpar o estado de bloqueio quando a cota renovar:

```bash
bash workflows/translate_srt.sh --reset-keys-state --source-lang ES --target-lang PT-BR entrada.srt saida.srt
```

Atalho pelo orquestrador principal:

```bash
bash workflows/exec.sh --backend deepl_doc --reset-deepl-keys-state
```

Timeout da consulta de uso (opcional):

```bash
DEEPL_USAGE_TIMEOUT_SECONDS=12 bash workflows/exec.sh --backend deepl_doc
```

Exemplo do INI:

```ini
[deepl_keys]
key_1 = sua-chave-1:fx
key_2 = sua-chave-2:fx
```

Uso no pipeline:

```bash
bash workflows/exec.sh --backend deepl_doc
```

### Gemini local (chave fora do Git)

- Template versionado: `config/translation/gemini.env.template`
- Arquivo local real (ignorado): `config/translation/gemini.env`

Uso no pipeline:

```bash
bash workflows/exec.sh --backend gemini
```

Uso de prompt geral (fora da tradução):

```bash
./.venv/bin/python scripts/gemini_prompt.py "Seu prompt"
```

## E2E de referência

- Os ativos de teste ponta a ponta ficam em `e2e/`.
- Os arquivos de entrada dedicados do E2E (`e2e-test_spanish.wav` e `e2e-test_chinese.mp3`) ficam em `e2e/`.
- O teste escreve todos os artefatos de validação em `e2e/`.
- Execute `bash workflows/test-e2e.sh` para rodar a validação com os ativos `e2e/e2e-test_spanish.wav` e `e2e/e2e-test_chinese.mp3`.
- Para um teste curto (arquivo único), use `bash workflows/test-e2e-short.sh`.

## Execução única

- O fluxo principal está centralizado em `workflows/exec.sh`.
- O `exec.sh` suporta execução de um único vídeo (por número) ou de todos os vídeos (`T`).
- A cada etapa confirmada por evidência em disco, o fluxo dispara sincronização de estado no banco via `manage.py sync_evidence`.
- Os scripts shell por etapa (`0` a `5`) foram removidos para simplificar operação e manutenção.
- A síntese de voz utiliza somente a voz Faber (`pt_BR-faber-medium.onnx`).

## Remux

- O fluxo de remux está em `workflows/remux.sh`.
- O remux usa vídeos em `done/` e exige evidência de áudio traduzido (`.pt.wav`) para o mesmo nome-base.
- A execução do remux também dispara sincronização de evidências no banco ao concluir.

## Webapp local (Django)

- Wrapper recomendado: `workflows/webapp.sh`
- O comando `start` sobe o website e o worker em background e informa a URL para abrir no navegador.
- Os comandos `start` e `restart` aplicam `manage.py migrate` automaticamente antes de subir os processos.
- O comando `stop` interrompe runs ativos com `manage.py stop_active_runs` antes de encerrar web e worker, evitando processos órfãos.
- O botão `Refresh` executa scan + sincronização de evidências + housekeeping de itens removidos da pasta de trabalho.
- O botão `Create new video` cria um run no modo `pipeline`.
- O botão `Remux` cria um run no modo `remux` para itens elegíveis (com evidência de pipeline concluído e artefatos necessários).

Comandos:

```bash
bash workflows/webapp.sh setup
bash workflows/webapp.sh start
bash workflows/webapp.sh start-lan
bash workflows/webapp.sh status
bash workflows/webapp.sh stop
```

Atalho:

```bash
bash workflows/webapp.sh
```

- Sem argumento, o wrapper usa `start` por padrão.
- O `start`/`restart` agora sobe por padrão em modo LAN (`0.0.0.0`) e imprime a URL LAN detectada.
- Para manter compatibilidade, `start-lan` e `restart-lan` continuam disponíveis como alias.
- A porta padrão continua `8000` (pode ser alterada por `WEBAPP_PORT`).
- O modo `start-lan` usa `WEBAPP_HOST=0.0.0.0`, tenta abrir a porta no `ufw` (Debian/Ubuntu) ou `firewalld` (Fedora), e imprime a URL LAN detectada.
- O Django agora aceita `DJANGO_ALLOWED_HOSTS` (lista separada por virgulas). Exemplo: `DJANGO_ALLOWED_HOSTS=127.0.0.1,localhost,192.168.1.20`.

Sincronização manual de evidências:

```bash
cd django_app
../.venv/bin/python manage.py sync_evidence --housekeeping
```

## Mudanças recentes

- Adicionado orquestrador único `workflows/exec.sh` com seleção interativa de vídeo.
- Removido `scripts/extrair-texto.py` (obsoleto) e documentação atualizada para refletir essa remoção.
- `workflows/test-e2e.sh` atualizado para executar diretamente os scripts Python (`transcrever.py`, `traduzir.py`, `gerar-sincronizado.py`).
- Webapp atualizado com dois modos de execução (`pipeline` e `remux`) e rastreio por evidências para refletir etapas concluídas no Refresh.
- Para síntese, mantenha os modelos da voz Faber em `models/` (arquivos `.onnx` e `.json`).
- Para executar o fluxo de verificação completa: rode `workflows/test-e2e.sh`.

Se desejar, posso também incluir um changelog separado em `CHANGES.md` ou detalhar exemplos de execução no final deste README.
