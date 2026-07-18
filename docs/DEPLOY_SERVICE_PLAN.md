# Plano Profundo de Operação do Website como Serviço

> Perfil alvo deste documento: **projeto pessoal em rede local**, com foco em simplicidade operacional.

## 1. Objetivo

Este documento define um plano completo para operar o website Django deste repositório como serviço no Linux, substituindo o start manual por um processo padronizado com:

- inicialização automática no boot
- reinício automático em falhas
- logs centralizados
- rotina previsível de deploy e rollback
- base de segurança e observabilidade adequada para ambiente local

Escopo deste plano:

- serviço web do Django
- integração com scripts atuais do projeto
- processo operacional de atualização
- estratégia de rollback e resposta a incidentes

Fora de escopo (neste momento):

- alta disponibilidade multi-nó
- orquestração com Kubernetes
- CI/CD totalmente automatizado
- deploy sem downtime

---

## 1.1 Decisão Arquitetural para Este Projeto

Para o contexto atual (uso pessoal e somente LAN), a recomendação é:

- **systemd + Gunicorn**, sem Nginx inicialmente
- deploy manual padronizado
- rollback simples por commit anterior

Justificativa:

- remove necessidade de start manual
- reduz pontos de falha e complexidade
- suficiente para disponibilidade local estável

Quando evoluir para Nginx/TLS:

- se houver necessidade de acesso externo
- se precisar HTTPS com certificado público
- se desejar políticas adicionais de proxy/caching

---

## 2. Estado Atual do Repositório

Estruturas e arquivos relevantes já existentes:

- App Django em [django_app/manage.py](../django_app/manage.py)
- Configurações do projeto em [django_app/webapp_project/settings.py](../django_app/webapp_project/settings.py)
- Scripts de operação atuais:
  - [scripts/webapp/start_webapp.sh](../scripts/webapp/start_webapp.sh)
  - [scripts/webapp/stop_webapp.sh](../scripts/webapp/stop_webapp.sh)
  - [scripts/webapp/status_webapp.sh](../scripts/webapp/status_webapp.sh)
- Dependências para webapp em [requirements-webapp.txt](../requirements-webapp.txt)
- Diretórios de logs já presentes:
  - [logs](../logs)
  - [logs/webapp](../logs/webapp)

Observação importante:

- O plano abaixo mantém compatibilidade com os scripts atuais, mas move a responsabilidade de ciclo de vida para o systemd.

---

## 3. Arquitetura Alvo Recomendada

### 3.1 Camadas (perfil simplificado)

Camada 1 (process manager):

- systemd gerencia o serviço principal do website

Camada 2 (aplicação):

- Gunicorn executa o projeto Django

Camada 3 (opcional, somente se necessário):

- Nginx como reverse proxy
- TLS, compressão, cache de estáticos e limites de request

### 3.2 Processo mínimo e processo ideal

Mínimo viável (recomendado para você agora):

- 1 serviço systemd para o webapp
- Gunicorn em porta local
- acesso apenas em rede local

Ideal para produção (futuro, opcional):

- 1 serviço systemd do webapp
- 1 serviço systemd de worker (se houver processamento assíncrono contínuo)
- Nginx na frente
- políticas de segurança do systemd
- backup de banco e rotinas de restore testadas

---

## 4. Princípios Operacionais

- Reprodutibilidade: todo deploy segue sempre os mesmos passos
- Imutabilidade relativa: configuração separada do código
- Menor privilégio: serviço roda com usuário dedicado sem shell privilegiado
- Observabilidade: logs, status e health checks com procedimento definido
- Recuperabilidade: rollback simples e rápido

---

## 5. Estrutura de Configuração

### 5.1 Diretórios sugeridos

- Código: repositório atual em [README.md](../README.md)
- Ambiente virtual Python: pasta fixa no projeto (ex. .venv)
- Arquivo de ambiente para serviço (duas opções):
  - Opção A (mais isolada): /etc/audiobook-libs/webapp.env
  - Opção B (mais simples para projeto pessoal): arquivo local protegido no diretório do projeto
- Arquivos de unit systemd: /etc/systemd/system/

### 5.2 Variáveis de ambiente

Manter segredos e parâmetros fora do código:

- DJANGO_SETTINGS_MODULE
- DJANGO_SECRET_KEY
- ALLOWED_HOSTS
- DEBUG (false em produção)
- DATABASE_URL ou parâmetros de banco
- chaves de integrações externas

Para ambiente local pessoal:

- ALLOWED_HOSTS deve incluir IP/hostname da sua LAN
- DEBUG preferencialmente false mesmo em LAN (true apenas para troubleshooting)

Referências já existentes de configuração no projeto:

- [config](../config)
- [config/translation/deepl.env](../config/translation/deepl.env)
- [config/translation/gemini.env.template](../config/translation/gemini.env.template)

Recomendação:

- criar arquivo de ambiente exclusivo para o serviço web
- restringir permissões do arquivo para leitura apenas pelo usuário do serviço

---

## 6. Serviço systemd do Website

### 6.1 Unidade sugerida: webapp.service (perfil local)

Exemplo de unit file (modelo de referência):

~~~ini
[Unit]
Description=Audiobook Libs Django Webapp
After=network.target

[Service]
Type=simple
User=webapp
Group=webapp
WorkingDirectory=/home/sergio85/audiobook-libs/django_app
EnvironmentFile=/etc/audiobook-libs/webapp.env
ExecStart=/home/sergio85/audiobook-libs/.venv/bin/gunicorn webapp_project.wsgi:application --bind 127.0.0.1:8000 --workers 3 --timeout 120 --access-logfile - --error-logfile -
Restart=always
RestartSec=3
TimeoutStartSec=60
TimeoutStopSec=60
KillSignal=SIGTERM
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=false
ReadWritePaths=/home/sergio85/audiobook-libs/logs

[Install]
WantedBy=multi-user.target
~~~

Versão simplificada (ainda mais fácil de manter em ambiente local):

~~~ini
[Unit]
Description=Audiobook Libs Django Webapp (Local)
After=network.target

[Service]
Type=simple
User=sergio85
Group=sergio85
WorkingDirectory=/home/sergio85/audiobook-libs/django_app
EnvironmentFile=/home/sergio85/audiobook-libs/config/webapp.env
ExecStart=/home/sergio85/audiobook-libs/.venv/bin/gunicorn webapp_project.wsgi:application --bind 0.0.0.0:8000 --workers 2 --timeout 120
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
~~~

Notas da versão simplificada:

- usa seu próprio usuário de sistema (mais simples para projeto pessoal)
- expõe na LAN via 0.0.0.0:8000
- reduz parâmetros de hardening para facilitar operação inicial
- pode ser endurecida depois sem alterar o fluxo de deploy

### 6.2 Explicação dos parâmetros críticos

- WorkingDirectory aponta para a pasta onde está o manage e o pacote Django
- EnvironmentFile separa segredos e configs do código
- Restart garante autorrecuperação
- ProtectSystem e NoNewPrivileges endurecem o processo
- ReadWritePaths libera escrita apenas onde necessário

No perfil local simplificado, os três itens realmente obrigatórios são:

- WorkingDirectory correto
- ExecStart correto com o venv
- Restart=always

### 6.3 Integração com scripts atuais

Scripts existentes podem continuar como utilitários operacionais:

- [scripts/webapp/start_webapp.sh](../scripts/webapp/start_webapp.sh)
- [scripts/webapp/stop_webapp.sh](../scripts/webapp/stop_webapp.sh)
- [scripts/webapp/status_webapp.sh](../scripts/webapp/status_webapp.sh)

Evolução recomendada:

- ajustar esses scripts para chamar systemctl start/stop/status webapp
- evitar dupla responsabilidade de subir processo por script e por systemd ao mesmo tempo

Sugestão prática para simplicidade:

- manter scripts como wrappers de systemctl
- manter apenas um nome de serviço (webapp)

---

## 7. Serviço de Worker (Opcional, mas recomendado)

Para seu contexto atual, considere este item **opcional de segunda fase**.
Implemente apenas se perceber necessidade real de processo contínuo em background.

Se o projeto usa tarefas longas em background, criar serviço separado para worker.

Exemplo de unit file para comando Django customizado:

~~~ini
[Unit]
Description=Audiobook Libs Worker
After=network.target

[Service]
Type=simple
User=webapp
Group=webapp
WorkingDirectory=/home/sergio85/audiobook-libs/django_app
EnvironmentFile=/etc/audiobook-libs/webapp.env
ExecStart=/home/sergio85/audiobook-libs/.venv/bin/python manage.py run_worker
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=false
ReadWritePaths=/home/sergio85/audiobook-libs/logs

[Install]
WantedBy=multi-user.target
~~~

Relacionamento com comando existente:

- [django_app/pipeline_ui/management/commands/run_worker.py](../django_app/pipeline_ui/management/commands/run_worker.py)

---

## 8. Reverse Proxy com Nginx (Recomendado)

Para este projeto pessoal em LAN, este item passa a ser **opcional**.
Não é pré-requisito para obter benefício imediato do systemd.

Benefícios:

- exposição do site em 80/443 com TLS
- isolamento do Gunicorn em loopback
- controle de upload size e timeout
- cache de estáticos

Configuração típica:

- Nginx encaminha requests para 127.0.0.1:8000
- Gunicorn não fica exposto diretamente à rede externa
- certificados gerenciados (por exemplo, via automação de ACME)

---

## 9. Fluxo de Deploy Manual Padronizado

Objetivo: transformar deploy em checklist repetível e auditável.

### 9.1 Pré-deploy

- confirmar branch/tag alvo
- validar arquivo de ambiente no servidor
- backup rápido do banco antes de migração
- janela de manutenção quando necessário

Adaptação para rotina local simples:

- preferir deploy em horários de baixo uso
- registrar em poucas linhas o que mudou (commit + data)

### 9.2 Sequência de deploy

1. Atualizar código para versão alvo
2. Atualizar dependências Python
3. Rodar migrações de banco
4. Rodar collectstatic (se aplicável)
5. Reiniciar serviço web
6. Reiniciar worker (se existir)
7. Validar health check e logs

Versão mínima (quando não há mudança de dependência/migração):

1. Atualizar código
2. Reiniciar serviço web
3. Validar acesso pela LAN

### 9.3 Pós-deploy

- validar funcionalidades críticas
- acompanhar logs por período inicial
- registrar versão implantada e horário

---

## 10. Modelo de Script de Deploy (Plano)

Criar um script único e idempotente para reduzir erro humano.

Comportamento esperado do script:

- falha rápida em qualquer etapa crítica
- logs claros em cada fase
- ordem fixa de operações
- saída com código de erro apropriado

Pseudo-fluxo:

~~~text
set -euo pipefail
validar diretórios e venv
atualizar código
instalar dependências
rodar migrate
rodar collectstatic
reiniciar webapp
reiniciar worker
verificar status e endpoint
~~~

Modo simplificado para uso frequente:

~~~text
set -euo pipefail
atualizar código
rodar migrate (se houver)
reiniciar webapp
testar URL local
~~~

---

## 11. Estratégia de Rollback

### 11.1 Quando acionar rollback

- erro funcional crítico após deploy
- degradação severa de performance
- falha de inicialização persistente

### 11.2 Procedimento padrão

1. Voltar para tag/commit anterior estável
2. Reinstalar dependências da versão anterior
3. Reiniciar serviços
4. Validar endpoint e fluxos críticos

No cenário local simples, manter ao menos:

- última tag estável conhecida
- backup recente do banco antes de deploy com migração

### 11.3 Banco de dados e migrações

Ponto de atenção:

- nem toda migração é reversível sem risco
- preferir migrações compatíveis com rollback quando possível
- manter backup pré-deploy para recuperação segura

---

## 12. Observabilidade e Logs

### 12.1 Fontes principais

- journalctl do systemd para web e worker
- logs da aplicação em [logs/webapp](../logs/webapp)

### 12.2 Sinais de saúde

- serviço ativo e estável por tempo contínuo
- ausência de reinícios frequentes
- latência de endpoint dentro do esperado
- fila de processamento sem crescimento anômalo

### 12.3 Alertas mínimos recomendados

- serviço parado
- reinício excessivo em curto período
- falhas de conexão com banco
- erros 5xx acima de limiar

---

## 13. Segurança Operacional

- usar usuário dedicado sem privilégios administrativos
- bloquear DEBUG em produção
- restringir ALLOWED_HOSTS
- manter segredo fora do repositório
- permissões mínimas em arquivos sensíveis
- limitar escrita do serviço aos diretórios estritamente necessários
- manter sistema e dependências atualizados

Adaptação para LAN pessoal (mínimo recomendado):

- firewall permitindo apenas sua rede local na porta do webapp
- não expor porta diretamente para internet
- manter credenciais fora do git

---

## 14. Backup e Recuperação

### 14.1 O que deve ter backup

- banco de dados
- arquivo de ambiente do serviço
- artefatos necessários de configuração

### 14.2 Rotina

- backup diário com retenção definida
- restore de teste periódico para validar integridade

---

## 15. Runbook de Incidentes

### 15.1 Site fora do ar

1. verificar status do serviço
2. verificar logs recentes
3. validar conectividade com banco
4. reiniciar serviço
5. acionar rollback se persistir

### 15.2 Worker travado ou fila acumulando

1. verificar status do worker
2. inspecionar logs de exceção
3. reiniciar worker
4. avaliar backlog e capacidade

### 15.3 Erro pós-deploy

1. identificar etapa da falha
2. decidir rollback ou hotfix rápido
3. registrar causa raiz
4. atualizar procedimento para prevenção

---

## 16. Checklist de Go-Live

- serviço web configurado no systemd
- serviço habilitado para subir no boot
- endpoint de saúde definido
- backups ativos e restore testado
- documentação de deploy e rollback validada
- responsáveis operacionais definidos

Checklist mínimo para seu perfil:

- webapp sobe com reboot sem intervenção manual
- acesso LAN funcionando no endereço planejado
- deploy básico (update + restart) documentado
- rollback para última versão estável testado

---

## 17. Plano de Evolução por Fases

Fase 1 (estabilização):

- migrar start manual para systemd
- padronizar deploy manual com checklist

Fase 2 (endurecimento):

- adicionar Nginx, TLS e limites
- melhorar observabilidade e alertas

Fase 3 (automação):

- automatizar pipeline de deploy com validações
- reduzir intervenção manual e tempo de recuperação

Sequência recomendada para você:

1. concluir fase 1 e operar por algumas semanas
2. só então decidir se fase 2 realmente agrega valor
3. considerar fase 3 apenas se a frequência de mudanças crescer

---

## 18. Critérios de Sucesso

- website sobe automaticamente após reboot
- deploy executado sem passos ad-hoc
- rollback possível em poucos minutos
- incidentes operacionais com procedimento claro
- redução de tempo gasto com start manual

---

## 19. Próximos Artefatos Recomendados

Para completar a operacionalização, criar posteriormente:

- template final de unit file do webapp
- template final de unit file do worker
- script de deploy oficial do projeto
- script de rollback oficial do projeto
- check de health endpoint documentado

Prioridade sugerida (perfil local):

1. template final de unit file do webapp
2. script de deploy simples
3. script de rollback simples
4. health check
5. worker (somente se necessário)

Este documento permanece como plano mestre para orientar a implementação.
