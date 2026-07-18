# SOP de Bolso - Webapp Local como Serviço

Este documento descreve a rotina curta de operação do webapp em ambiente pessoal (rede local), com foco em execução simples e previsível.

Relacionamento com o plano mestre:

- Plano detalhado: [DEPLOY_SERVICE_PLAN.md](DEPLOY_SERVICE_PLAN.md)

---

## 1. Perfil deste SOP

- Projeto pessoal
- Acesso somente em rede local (LAN)
- Serviço gerenciado por systemd
- Sem Nginx nesta fase inicial

---

## 2. Pré-requisitos (uma vez)

- Ambiente virtual Python pronto
- Dependências instaladas a partir de [requirements-webapp.txt](../requirements-webapp.txt)
- Serviço systemd configurado para o webapp
- Arquivo de ambiente configurado (segredos fora do git)
- Banco inicializado e migrações aplicadas

---

## 3. Operação diária

Observação de concorrência do pipeline:

- O coordenador mantém 1 worker por fase do pipeline por padrão (DL, EX, TR, TL, AB, RX).
- Para ajustar este limite, use a variável de ambiente `WEBAPP_WORKER_MAX_SLOTS_PER_SCOPE`.
- Em máquina local única, mantenha `1` como padrão e aumente para `2` somente após medir ganho real de throughput sem aumento de falhas ou lock/retry de SQLite.

Observação de observabilidade:

- Logs operacionais e de pipeline usam carimbo de timestamp no formato `[YYYY-MM-DD hh:mm:ss]`.
- Cada etapa do pipeline registra `started_at` e `finished_at` no SQLite, permitindo cálculo de duração por etapa.

### 3.1 Iniciar serviço

Comando:

~~~bash
sudo systemctl start webapp
~~~

### 3.2 Parar serviço

Comando:

~~~bash
sudo systemctl stop webapp
~~~

### 3.3 Reiniciar serviço

Comando:

~~~bash
sudo systemctl restart webapp
~~~

### 3.4 Ver status

Comando:

~~~bash
systemctl status webapp --no-pager
~~~

### 3.5 Ver logs recentes

Comando:

~~~bash
journalctl -u webapp -n 100 --no-pager
~~~

### 3.6 Seguir logs em tempo real

Comando:

~~~bash
journalctl -u webapp -f
~~~

---

## 4. Deploy rápido (mudança comum)

Usar quando houve alteração de código sem mudanças de dependência e sem migração de banco.

Passos:

1. Atualizar código para a versão desejada
2. Reiniciar o serviço
3. Testar acesso pela URL local
4. Verificar logs por alguns minutos

Checklist curto:

- página inicial abre na LAN
- sem erro 500 no teste básico
- serviço permanece ativo sem reinício contínuo

---

## 5. Deploy completo (quando necessário)

Usar quando houver mudanças de dependências, modelos ou estáticos.

Passos:

1. Atualizar código
2. Atualizar dependências Python
3. Rodar migrações de banco
4. Rodar collectstatic (se aplicável)
5. Reiniciar webapp
6. Validar acesso e logs

---

## 6. Rollback rápido

Usar se o deploy introduzir falha funcional.

Passos:

1. Voltar para commit/tag anterior estável
2. Reinstalar dependências da versão estável (se necessário)
3. Reiniciar serviço
4. Validar URL local e logs

Observação:

- se houve migração sensível, usar backup pré-deploy do banco

---

## 7. Incidentes comuns e ação imediata

### 7.1 Serviço não sobe

1. Checar status do serviço
2. Checar logs do journalctl
3. Verificar arquivo de ambiente (variáveis ausentes)
4. Verificar caminho do venv e WorkingDirectory

### 7.2 Site abre, mas com erro interno

1. Inspecionar traceback nos logs
2. Verificar conectividade com banco
3. Verificar migrações pendentes
4. Se necessário, rollback para versão estável

### 7.3 Após reboot o site não voltou

1. Verificar se serviço está habilitado no boot
2. Ver status e logs
3. Corrigir e testar novo reboot controlado

---

## 8. Segurança mínima para LAN

- Não expor a porta do webapp para internet
- Restringir firewall para sua rede local
- Manter segredos fora do repositório
- Manter DEBUG desativado no uso normal

---

## 9. Checklist semanal (5 minutos)

1. Confirmar serviço ativo e estável
2. Revisar erros recorrentes em logs
3. Verificar espaço em disco para logs e banco
4. Confirmar backup recente do banco

---

## 10. Comandos de referência

~~~bash
# ciclo de vida
sudo systemctl start webapp
sudo systemctl stop webapp
sudo systemctl restart webapp
systemctl status webapp --no-pager

# logs
journalctl -u webapp -n 100 --no-pager
journalctl -u webapp -f

# boot
sudo systemctl enable webapp
sudo systemctl disable webapp
~~~

---

## 11. Fontes do projeto

- Scripts atuais: [scripts/webapp/start_webapp.sh](../scripts/webapp/start_webapp.sh), [scripts/webapp/stop_webapp.sh](../scripts/webapp/stop_webapp.sh), [scripts/webapp/status_webapp.sh](../scripts/webapp/status_webapp.sh)
- Django manage: [django_app/manage.py](../django_app/manage.py)
- Dependências web: [requirements-webapp.txt](../requirements-webapp.txt)
- Plano detalhado: [DEPLOY_SERVICE_PLAN.md](DEPLOY_SERVICE_PLAN.md)
