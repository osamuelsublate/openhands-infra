# openhands-infra: rode `just` para ver todas as receitas.
set shell := ["bash", "-euo", "pipefail", "-c"]

host := env("OH_HOST", "deploy@179.199.150.4")
dir := "/opt/openhands"
ansible := "uvx --from ansible-core==2.21.4 ansible-playbook"
galaxy := "uvx --from ansible-core==2.21.4 ansible-galaxy"

# lista as receitas
default:
    @just --list --unsorted

# ─────────────────────────── qualidade ───────────────────────────

# valida compose, caddy, prometheus, loki, tempo, alloy e dashboards (igual ao CI)
[group('check')]
validate:
    scripts/validate.sh

# roda os hooks do pre-commit em todos os arquivos
[group('check')]
lint:
    pre-commit run --all-files

# validate + lint
[group('check')]
check: lint validate

# ─────────────────────────── host (Ansible) ───────────────────────────

# instala as collections do Ansible
[group('host')]
ansible-deps:
    cd ansible && {{ galaxy }} collection install -r requirements.yml

# 1º acesso: provisiona como root, cria o usuário deploy (root ainda entra, só com chave)
[group('host')]
bootstrap: ansible-deps
    cd ansible && {{ ansible }} site.yml -e ansible_user=root -e ssh_lockdown=false

# 2º passo, DEPOIS de testar `ssh deploy@...` em outro terminal: bloqueia o root
[confirm("Você já testou `ssh deploy@servidor` em outro terminal? (y/N)")]
[group('host')]
lockdown:
    cd ansible && {{ ansible }} site.yml -e ssh_lockdown=true

# aplica o playbook no host (idempotente)
[group('host')]
provision:
    cd ansible && {{ ansible }} site.yml -e ssh_lockdown=true

# dry-run com diff: mostra drift do host sem mudar nada
[group('host')]
provision-check:
    cd ansible && {{ ansible }} site.yml -e ssh_lockdown=true --check --diff

# estado de segurança do host (sshd efetivo, UFW, fail2ban, portas abertas)
[group('host')]
audit:
    ssh {{ host }} 'sudo sshd -T | grep -Ei "^(permitrootlogin|passwordauthentication|allowusers|maxauthtries)"; echo; sudo ufw status verbose; echo; sudo fail2ban-client status sshd; echo; sudo ss -tlnpu | grep -v 127.0.0'

# ─────────────────────────── segredos (SOPS + age) ───────────────────────────

# cria secrets/prod.sops.env com chaves aleatórias (e sua chave age, se não existir)
[group('secrets')]
secrets-init:
    scripts/secrets-init.sh

# edita os segredos cifrados no $EDITOR
[group('secrets')]
secrets-edit:
    sops edit secrets/prod.sops.env

# recifra após mudar os destinatários em .sops.yaml
[group('secrets')]
secrets-updatekeys:
    sops updatekeys -y secrets/prod.sops.env

# mostra a chave de acesso da UI do OpenHands
[group('secrets')]
api-key:
    @sops decrypt --extract '["LOCAL_BACKEND_API_KEY"]' secrets/prod.sops.env; echo

# mostra a senha de admin do Grafana
[group('secrets')]
grafana-password:
    @sops decrypt --extract '["GRAFANA_ADMIN_PASSWORD"]' secrets/prod.sops.env; echo

# ─────────────────────────── deploy e operação ───────────────────────────

# o que mudaria no servidor (sem aplicar)
[group('deploy')]
diff:
    rsync -azn --delete --checksum --itemize-changes --exclude '.env' --exclude '.deploys' stack/ {{ host }}:{{ dir }}/

# valida, sincroniza, envia segredos e sobe a stack
[confirm("Fazer deploy em produção? (y/N)")]
[group('deploy')]
deploy: _clean-tree validate
    scripts/deploy.sh {{ host }} {{ dir }}

# status dos containers
[group('deploy')]
ps:
    ssh {{ host }} "cd {{ dir }} && docker compose ps --format 'table {{{{.Service}}\t{{{{.Status}}\t{{{{.Image}}'"

# logs de um serviço (ou de todos): just logs agent-canvas
[group('deploy')]
logs svc="":
    ssh -t {{ host }} 'cd {{ dir }} && docker compose logs -f --tail=200 {{ svc }}'

# reinicia um serviço: just restart egress-proxy
[group('deploy')]
restart svc:
    ssh {{ host }} "cd {{ dir }} && docker compose restart {{ svc }}"

# histórico de deploys (commit + data)
[group('deploy')]
history:
    ssh {{ host }} 'tail -20 {{ dir }}/.deploys'

# roda um backup agora (profile backup precisa estar ligado)
[group('deploy')]
backup-now:
    ssh {{ host }} "cd {{ dir }} && docker compose exec backup backup"

# túnel para uma UI interna, ex.: just tunnel prometheus 9090
[group('deploy')]
tunnel svc port:
    @echo "abrindo http://localhost:{{ port }} → {{ svc }}:{{ port }} (Ctrl+C para fechar)"
    ssh -N -L {{ port }}:$(ssh {{ host }} "docker inspect -f '{{{{range .NetworkSettings.Networks}}{{{{.IPAddress}} {{{{end}}' openhands-{{ svc }}-1" | awk '{print $1}'):{{ port }} {{ host }}

_clean-tree:
    @git diff --quiet && git diff --cached --quiet || (echo "há mudanças não commitadas: commite antes do deploy" >&2; exit 1)
