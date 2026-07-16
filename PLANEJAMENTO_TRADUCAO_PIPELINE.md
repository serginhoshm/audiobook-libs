# Planejamento de Implementacao - Pipeline de Traducao de Legendas

Data: 2026-07-15
Status: pronto para implementacao

## Objetivo
Substituir o uso principal de traducao local por um pipeline robusto com tres mecanismos, mantendo continuidade operacional, qualidade e auditabilidade para arquivos de legenda transcrita (SRT/VTT).

Motores definidos:
1. Deep Translator (padrao, robusto)
2. Google Translator simples (tentativa secundaria online)
3. Ollama local (fallback final e modo offline)

Restricao assumida:
- Nao adicionar novos frameworks pesados que exijam downloads de modelos externos alem do que ja existe no ambiente.

---

## Escopo funcional

Entrada:
- .srt
- .vtt

Saida:
- arquivo traduzido preservando estrutura original
- relatorio de execucao/qualidade por arquivo
- checkpoint para retomada segura

Requisitos nao funcionais:
- resiliencia a falhas de rede/provedor
- fallback automatico por bloco/janela
- baixo risco de corromper timestamps/indices
- rastreabilidade completa das decisoes de traducao

---

## Arquitetura proposta

## Camadas
1. Parser de legenda
- leitura e serializacao de SRT/VTT
- preservacao de indices e timestamps
- isolamento apenas do texto traduzivel

2. Segmentacao e janelas
- agrupamento de blocos para contexto semantico
- tamanho dinamico por limite de caracteres/tokens
- reencaixe deterministico do texto traduzido

3. Orquestrador de traducao
- tentativa em cadeia:
  - Deep robusto
  - Google simples
  - Ollama local
- retries com backoff por motor
- timeout por tentativa

4. Motor de qualidade (double-check/triple-check)
- validacoes estruturais obrigatorias
- heuristicas de suspeita
- execucao comparativa com 3 motores em casos duvidosos
- escolha por score

5. Persistencia operacional
- checkpoint por arquivo e por janela
- cache de trechos repetidos
- logs estruturados

6. Relatorios
- metricas de qualidade e confiabilidade
- estatisticas de fallback e retrabalho

---

## Fluxo de execucao (alto nivel)

1. Carregar legenda e validar formato.
2. Quebrar em janelas (ex.: 30-60 blocos, configuravel).
3. Traduzir janela via Deep robusto.
4. Se falhar ou sinalizar baixa confianca, tentar Google simples.
5. Se falhar novamente, usar Ollama local.
6. Se heuristica de duvida disparar, rodar triple-compare (os 3) e escolher por score.
7. Aplicar validacoes estruturais e de texto.
8. Persistir checkpoint.
9. Ao final, gerar arquivo final + relatorio.

---

## Regras de resiliencia

## Retry e backoff
- Tentativas por motor: configuravel (padrao: 3)
- Backoff exponencial com jitter
- Timeouts por chamada de traducao

## Circuit breaker leve
- Se motor online acumular falhas consecutivas acima do limite, pular temporariamente para proximo motor por uma janela de respiro

## Degradacao controlada
- prioridade de qualidade: Deep > Google simples > Ollama
- prioridade de disponibilidade: Ollama garante continuidade sem internet

---

## Double-checks obrigatorios de qualidade

## Estrutura
- contagem de blocos inalterada
- indices inalterados
- timestamps inalterados

## Conteudo
- nao aceitar traducao vazia quando a entrada contem texto
- detectar compressao extrema de texto (ex.: tamanho de saida muito baixo)
- detectar repeticao anomala de tokens/pontuacao
- detectar caracteres de controle inesperados

## Legibilidade de legenda
- limite de linhas por bloco (configuravel)
- limite de caracteres por linha (configuravel)
- normalizacao de espacos e quebras

---

## Modo de duvida (triple-compare)

Acionadores de duvida (qualquer um):
- divergencia grande de tamanho entre entrada e saida
- score de confianca abaixo do limiar
- falhas/retries acima do limiar
- sinais de texto truncado ou semanticamente estranho

Procedimento:
1. Traduzir o mesmo trecho com os 3 motores.
2. Calcular score de cada candidato.
3. Selecionar melhor resultado.

Score sugerido (ponderado):
- preservacao semantica aproximada
- fluidez linguistica
- conformidade de legenda (linhas/caracteres)
- estabilidade de nomes proprios e numeros

Desempate:
- preferir Deep quando ambos forem validos e similares
- preferir Ollama quando os online apresentarem sinais de instabilidade

---

## Configuracoes recomendadas (iniciais)

- tamanho_janela_blocos: 40
- max_chars_janela: 3500
- retries_por_motor: 3
- timeout_segundos_online: 20
- timeout_segundos_local: 45
- backoff_base_segundos: 1.0
- jitter: 0.2
- max_chars_por_linha: 42
- max_linhas_por_bloco: 2
- limiar_duvida: configuravel por score

Observacao:
- Esses valores devem ser ajustados com 20-50 arquivos reais para calibracao.

---

## Estrutura de implementacao sugerida (no projeto)

- scripts/translate_pipeline.py
  - CLI principal
- scripts/lib/subtitle_parser.py
  - parse/serialize SRT/VTT
- scripts/lib/translator_backends.py
  - Deep robusto, Google simples, Ollama
- scripts/lib/quality_checks.py
  - validacoes, heuristicas e score
- scripts/lib/checkpoint_store.py
  - retomada por arquivo/janela
- scripts/lib/reporting.py
  - relatorio final
- logs/translation/
  - logs por execucao

Obs: nomes podem ser adaptados ao padrao interno ja existente.

---

## Interfaces internas (contratos)

BackendTranslator:
- translate(text: str, src: str, tgt: str, context: dict) -> TranslationResult

TranslationResult:
- text: str
- backend: str
- latency_ms: int
- retries: int
- warnings: list[str]
- raw_meta: dict

QualityDecision:
- accepted: bool
- suspicious: bool
- score: float
- reasons: list[str]
- selected_backend: str

---

## Observabilidade

Log por janela:
- arquivo
- janela_id
- backend principal
- fallback acionado
- retries
- latencia
- flags de qualidade
- decisao final

Relatorio por arquivo:
- total_blocos
- total_janelas
- uso_por_backend
- taxa_fallback
- blocos_em_duvida
- blocos_reprocessados
- tempo_total
- status final

---

## Plano de entrega

Fase 1 - MVP robusto (prioridade)
- parser SRT/VTT
- deep robusto + google simples + fallback ollama
- retries/backoff
- checkpoint
- validacao estrutural

Fase 2 - Qualidade avancada
- heuristicas de suspeita
- triple-compare com score
- limites de legenda (linhas/caracteres)
- relatorio detalhado

Fase 3 - Endurecimento
- calibracao fina de limiares
- testes com base real
- tunning de performance/custo

---

## Estimativa de esforco (implementacao direta)

- Fase 1: 4 a 6 horas
- Fase 2: +4 a 8 horas
- Fase 3: +2 a 4 horas

Total estimado:
- 1 dia util para versao robusta inicial
- ate 2 dias com calibracao e refinamento

---

## Riscos e mitigacoes

1. Bloqueio temporario de online
- mitigacao: fallback automatico para Ollama

2. Perda de contexto em blocos curtos
- mitigacao: traducao por janelas e reencaixe

3. Quebra de formato de legenda
- mitigacao: validacao estrutural estrita antes de persistir

4. Variacao de qualidade entre motores
- mitigacao: modo duvida com triple-compare e score

---

## Criterios de aceite

1. Arquivos SRT/VTT traduzidos sem alterar timestamps e indices.
2. Pipeline conclui mesmo com indisponibilidade online (via Ollama).
3. Checkpoint permite retomar sem retraduzir tudo.
4. Relatorio final evidencia uso de fallback e blocos suspeitos.
5. Modo duvida compara os 3 motores e seleciona resultado justificavel.

---

## Comandos alvo (exemplo de uso futuro)

Traducao normal:
- python scripts/translate_pipeline.py --in arquivo.srt --out arquivo.pt.srt --src es --tgt pt

Modo offline forcado:
- python scripts/translate_pipeline.py --in arquivo.srt --out arquivo.pt.srt --src es --tgt pt --offline

Modo qualidade alta (triple-compare agressivo):
- python scripts/translate_pipeline.py --in arquivo.srt --out arquivo.pt.srt --src es --tgt pt --strict-quality

---

## Decisao final registrada
Implementar pipeline de traducao com Deep Translator como padrao, Google simples como segunda tentativa online e Ollama local como fallback final, com resiliencia operacional e validacoes de qualidade por bloco/janela, incluindo triple-compare em casos de duvida.
