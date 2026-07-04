# Django Local Webapp - Plano de Implementacao Detalhado

## 1. Visao Geral

Este documento detalha a implementacao de uma interface web local em Django para operar o pipeline atual de transcricao, traducao e geracao de audio.

Objetivo principal:

- permitir scan, execucao, parada e monitoramento de processamento por arquivo via web.
- configurar todas as opcoes atuais do exec por arquivo, via UI, sem prompts interativos.
- oferecer bootstrap completo por bash para setup e subida local do sistema.

## 2. Estrutura Sugerida de Projeto

Opcao A (recomendada): manter no mesmo repositorio.

- django_app/
  - manage.py
  - core/
  - pipeline_ui/

Opcao B: subprojeto na pasta docs nao e recomendada para codigo executavel.

Decisao recomendada:

- criar codigo Django na raiz do repositorio em pasta dedicada.
- manter documentacao em docs/django-local-webapp.

## 3. Modelagem de Dados

## 3.1 VideoAsset

Campos:

- id
- file_path (unico)
- file_name
- extension
- size_bytes
- duration_seconds
- original_language
- discovered_at
- last_seen_at
- is_present

## 3.2 PipelineRun

Campos:

- id
- video_asset (FK)
- requested_by (opcional)
- status (discovered, queued, running, stopping, stopped, success, failed, skipped)
- started_at
- finished_at
- exit_code
- error_message
- log_file_path
- pid
- process_group_id

## 3.3 PipelineStepStatus

Campos:

- id
- pipeline_run (FK)
- step_name (extract, transcribe, translate, audiobook)
- status (pending, running, success, failed, skipped)
- detail
- updated_at

## 3.4 SystemSetting

Campos:

- key
- value

Uso:

- armazenar configuracoes operacionais sem hardcode.

## 3.5 ExecutionProfile

Campos (config por arquivo na UI):

- id
- video_asset (FK)
- backend
- nllb_profile
- nllb_max_input_length
- nllb_max_new_tokens
- nllb_gpu
- nllb_legacy
- deepl_endpoint
- reset_deepl_keys_state
- normalize_dry_run
- cuda_enabled (unico para whisper e piper)
- updated_at

Observacao:

- cada VideoAsset deve manter sua configuracao atual de execucao na tela.

## 4. Servicos de Dominio

## 4.1 ScanService

Responsabilidades:

- ler caminho configurado em config/pipeline.ini.
- listar videos no diretorio alvo.
- extrair metadados com ffprobe.
- inferir idioma original.
- upsert em VideoAsset.
- marcar ausentes com is_present=false sem excluir historico.

## 4.2 QueueService

Responsabilidades:

- enfileirar runs para ids selecionados.
- impedir duplicidade de run ativa por arquivo.
- registrar transicao de estado queued -> running -> final.

## 4.3 RunnerService

Responsabilidades:

- iniciar subprocesso de pipeline por arquivo.
- salvar pid e process_group_id.
- stream de log para arquivo dedicado.
- atualizar estados por etapa com parser de log.
- montar comando nao interativo com base no ExecutionProfile da linha.
- mapear CUDA unico da UI para whisper e piper simultaneamente.

## 4.4 StopService

Responsabilidades:

- receber solicitacao de stop por runs selecionadas.
- enviar SIGTERM para grupo de processos.
- aguardar timeout.
- enviar SIGKILL se necessario.
- concluir estado em stopped.

## 4.5 ReconciliationService

Responsabilidades:

- ao subir sistema, reconciliar runs em running sem processo vivo.
- checar arquivos .state e logs para corrigir status.

## 5. Worker em Background

MVP sem dependencias externas:

- criar management command run_worker.
- loop simples com sleep curto.
- lock de concorrencia para evitar dois workers simultaneos.

Evolucao:

- migrar para Celery + Redis quando necessario.

## 6. API Endpoints

## 6.1 GET /api/videos

Retorna lista de videos e ultimo status conhecido.

Parametros:

- present_only=true|false
- status
- search

## 6.2 POST /api/scan

Executa scan manual e retorna resumo:

- discovered
- updated
- missing

## 6.3 POST /api/runs/start

Body:

- video_ids: [int]

Acao:

- cria runs queued para os ids selecionados.
- executa com parametros persistidos do ExecutionProfile de cada id.

## 6.4 POST /api/runs/stop

Body:

- run_ids ou video_ids

Acao:

- marca runs em stopping e aciona StopService.

## 6.5 GET /api/status

Retorna snapshot para polling:

- videos
- runs ativas
- progresso por etapa
- ultimos eventos

## 6.6 PATCH /api/videos/{id}/options

Body (parcial):

- backend
- nllb_profile
- nllb_max_input_length
- nllb_max_new_tokens
- nllb_gpu
- nllb_legacy
- deepl_endpoint
- reset_deepl_keys_state
- normalize_dry_run
- cuda_enabled

Acao:

- atualiza configuracao da linha na lista.

## 7. Interface Web

Pagina principal unica com:

- toolbar: Scan, Run, Stop
- tabela de videos com checkbox por linha
- colunas:
  - selecao
  - nome
  - duracao
  - idioma
  - opcoes (dropdowns da linha)
  - status geral
  - etapas
  - ultima atualizacao

Comportamentos:

- Run/Stop agem somente nos itens selecionados.
- botoes desabilitados quando nada selecionado.
- polling automatico atualiza linhas afetadas.
- mudanca de dropdown persiste automaticamente no ExecutionProfile.
- execucao via Run nunca depende de prompt no terminal.

## 7.1 Catalogo de Opcoes na Linha

Todas as opcoes atualmente disponiveis no exec devem estar presentes na UI.

- backend: google | nllb_local | deepl_doc | gemini
- nllb_profile: fast | legacy | custom
- nllb_max_input_length: presets em dropdown + opcao custom
- nllb_max_new_tokens: presets em dropdown + opcao custom
- nllb_gpu: on | off
- nllb_legacy: on | off
- deepl_endpoint: free | pro
- reset_deepl_keys_state: yes | no
- normalize_dry_run: yes | no
- cuda_enabled: yes | no (unico)

Mapeamento de cuda_enabled para flags atuais:

- yes -> --whisper-cuda on + --piper-cuda on
- no -> --whisper-cuda off + --piper-cuda off

## 8. Parsing de Logs e Etapas

Fonte primaria:

- logs por execucao no data root.

Estrategia:

- parser por padroes de texto ja existentes:
  - Etapa 0 - Extracao de Audio
  - Etapa 1 - Transcricao
  - Etapa 2 - Traducao
  - Etapa 3 - Sintese
- atualizar PipelineStepStatus conforme eventos.

## 9. Execucao do Pipeline por Arquivo

Opcoes:

- usar exec.sh com argumentos nao interativos para item unico.
- ou invocar scripts por etapa em sequencia no RunnerService.

Recomendacao inicial:

- encapsular invocacao existente para minimizar risco.

Comando alvo por arquivo (exemplo):

```bash
bash workflows/exec.sh \
  --backend deepl_doc \
  --nllb-profile fast \
  --nllb-max-input-length 768 \
  --nllb-max-new-tokens 192 \
  --nllb-gpu on \
  --no-nllb-legacy \
  --deepl-endpoint free \
  --reset-deepl-keys-state \
  --whisper-cuda on \
  --piper-cuda on
```

Nota:

- os scripts bash permanecem inalterados.
- a camada Django apenas decide e injeta flags.

## 10. Seguranca e Confiabilidade

- bind apenas em localhost.
- validar caminhos antes de executar subprocessos.
- sanitizar entradas de API.
- registrar auditoria de comandos disparados.

## 11. Testes

## 11.1 Unitarios

- ScanService
- QueueService
- StopService
- parser de logs

## 11.2 Integracao

- fluxo scan -> run -> status -> stop
- reconciliacao apos restart

## 11.3 E2E local

- com conjunto reduzido de videos de teste.

## 12. Roadmap de Entrega

## Sprint 1

- estrutura Django
- modelos
- scan
- listagem basica

## Sprint 2

- fila e worker
- run/stop
- status geral

## Sprint 3

- status por etapa
- parser de logs
- reconciliacao

## Sprint 4

- melhorias de UX
- filtros e busca
- export de logs por run

## 13. Definicoes de Pronto

- scan manual funcional
- run/stop funcional por selecao
- atualizacao de status via polling
- sem travar interface durante processamento
- persistencia de historico no SQLite
- opcoes por arquivo persistidas na lista e respeitadas no run.
- fluxo de execucao web sem qualquer prompt interativo.

## 14. Dependencias Tecnicas

- Python 3.12
- Django 5.x
- ffmpeg/ffprobe instalados
- acesso aos scripts e diretorios do pipeline atual

## 14.1 Requisito de Bootstrap Operacional (Bash)

Para reduzir friccao de operacao, o projeto deve incluir scripts bash dedicados.

Scripts minimos:

- scripts/webapp/setup_webapp.sh
- scripts/webapp/start_webapp.sh
- scripts/webapp/stop_webapp.sh
- scripts/webapp/status_webapp.sh

Responsabilidades por script:

- setup_webapp.sh
  - criar/ativar venv
  - instalar dependencias
  - executar migrate
  - validar pre-requisitos basicos
- start_webapp.sh
  - iniciar Django server em localhost
  - iniciar worker em segundo plano
  - registrar PID files e logs de inicializacao
  - imprimir URL final para acesso via navegador
- stop_webapp.sh
  - encerrar processos web/worker por PID file
  - fallback de encerramento seguro se PID file estiver inconsistente
- status_webapp.sh
  - informar se web/worker estao ativos
  - mostrar caminhos de log e PID

Convencoes recomendadas:

- PID files em .run/webapp/
- logs em logs/webapp/
- sem dependencias externas de supervisor no MVP

Fluxo esperado para operador:

1. bash scripts/webapp/setup_webapp.sh
2. bash scripts/webapp/start_webapp.sh
3. abrir URL localhost impressa pelo script
4. bash scripts/webapp/status_webapp.sh (quando necessario)
5. bash scripts/webapp/stop_webapp.sh

## 15. Proximos Passos Recomendados

1. Criar esqueleto Django e modelos.
2. Implementar ExecutionProfile e endpoint de persistencia das opcoes da linha.
3. Implementar endpoint de scan e tela de listagem com dropdowns por arquivo.
4. Implementar worker e start/stop para um unico arquivo sem prompts.
5. Expandir para selecao multipla e monitoramento por etapa.
6. Implementar e validar scripts de bootstrap operacional em bash.
