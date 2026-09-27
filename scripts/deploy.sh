#!/usr/bin/env bash
# Deploy: rsync da pasta stack/ + segredos decifrados em stream + compose up.
# O servidor não tem git, nem chave age: recebe só o estado renderizado.
#
# uso: scripts/deploy.sh <user@host> <dir>
set -euo pipefail
cd "$(dirname "$0")/.."

readonly HOST="${1:?uso: deploy.sh user@host dir}"
readonly DIR="${2:?uso: deploy.sh user@host dir}"
readonly SECRETS=secrets/prod.sops.env
step() { printf '\033[1m▸ %s\033[0m\n' "$1"; }

# Uma única conexão SSH multiplexada para todo o deploy: o host tem `ufw limit`
# na porta 22 (6 conexões/30s por IP) e o deploy abre várias em sequência.
SSH_OPTS=(-o ControlMaster=auto -o "ControlPath=$HOME/.ssh/cm-%r@%h:%p" -o ControlPersist=120)
ssh() { command ssh "${SSH_OPTS[@]}" "$@"; }
export RSYNC_RSH="ssh ${SSH_OPTS[*]}"

[[ -f "$SECRETS" ]] || { echo "falta $SECRETS (just secrets-init)" >&2; exit 1; }

step "conferindo segredos"
env_plain="$(sops decrypt "$SECRETS")"
if grep -qE '^COMPOSE_PROFILES=.*backup' <<<"$env_plain"; then
  for v in BACKUP_AGE_PUBLIC_KEYS BACKUP_S3_ENDPOINT BACKUP_S3_BUCKET BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY; do
    grep -qE "^${v}=.+" <<<"$env_plain" || { echo "profile backup ligado, mas falta $v" >&2; exit 1; }
  done
fi

step "sincronizando stack/ → ${HOST}:${DIR}"
rsync -az --delete --checksum --itemize-changes \
  --exclude '.env' --exclude '.deploys' \
  stack/ "${HOST}:${DIR}/"

step "enviando segredos (stream, 0600, nunca em disco no laptop)"
printf '%s\n' "$env_plain" | ssh "$HOST" "umask 077 && cat > '${DIR}/.env.tmp' && mv '${DIR}/.env.tmp' '${DIR}/.env'"
unset env_plain

step "build, pull e subida"
ssh "$HOST" "cd '${DIR}' \
  && docker compose config -q \
  && docker compose build --pull egress-proxy \
  && docker compose pull --ignore-buildable --quiet \
  && docker compose up -d --remove-orphans --wait --wait-timeout 300"

step "recarregando provisionamento do Grafana (alertas e datasources só são lidos no boot)"
# O Host precisa ser o domínio público: o Grafana roda com enforce_domain.
ssh "$HOST" "cd '${DIR}' && docker compose exec -T grafana sh -c '
  auth=\$(printf %s \"\$GF_SECURITY_ADMIN_USER:\$GF_SECURITY_ADMIN_PASSWORD\" | base64 | tr -d \"\\n\")
  for r in datasources alerting; do
    wget -qO- --post-data= --header \"Host: \$GF_SERVER_DOMAIN\" --header \"Authorization: Basic \$auth\" \\
      \"http://127.0.0.1:3000/grafana/api/admin/provisioning/\$r/reload\" >/dev/null && echo \"  \$r ok\" || exit 1
  done'"

rev="$(git rev-parse --short HEAD)"
ssh "$HOST" "echo '${rev} $(date -u +%FT%TZ)' >> '${DIR}/.deploys'"
step "no ar: ${rev}"
ssh "$HOST" "cd '${DIR}' && docker compose ps --format 'table {{.Service}}\t{{.Status}}'"
