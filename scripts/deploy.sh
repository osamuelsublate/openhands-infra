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

rev="$(git rev-parse --short HEAD)"
ssh "$HOST" "echo '${rev} $(date -u +%FT%TZ)' >> '${DIR}/.deploys'"
step "no ar: ${rev}"
ssh "$HOST" "cd '${DIR}' && docker compose ps --format 'table {{.Service}}\t{{.Status}}'"
