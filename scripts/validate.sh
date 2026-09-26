#!/usr/bin/env bash
# Valida TODAS as configurações com as mesmas imagens (tag+digest) do compose.yaml.
# Roda igual no laptop (`just validate`) e no CI.
set -euo pipefail
cd "$(dirname "$0")/.."

readonly ENV_FILE=ci/dummy.env
readonly COMPOSE=(docker compose -f stack/compose.yaml --env-file "$ENV_FILE")
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
step() { printf '\033[1m▸ %s\033[0m\n' "$1"; }

# imagem exata de um serviço, lida do compose (Renovate só precisa atualizar um lugar)
image_of() { "${COMPOSE[@]}" config --format json | jq -r --arg s "$1" '.services[$s].image'; }

step "compose"
"${COMPOSE[@]}" config -q
ok "compose.yaml válido"

# Só o Caddy pode publicar portas: o Docker publica por fora do UFW.
published="$("${COMPOSE[@]}" --profile backup config --format json \
  | jq -r '.services | to_entries[] | select(.value.ports != null and .key != "caddy") | .key')"
if [[ -n "$published" ]]; then
  echo "  ✗ serviços publicando portas além do caddy: $published" >&2
  exit 1
fi
ok "só o caddy publica portas"

step "caddy"
docker run --rm --env-file "$ENV_FILE" -e ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory \
  -e CADDY_ALLOWED_CIDRS="0.0.0.0/0 ::/0" -v "$PWD/stack/caddy:/etc/caddy:ro" "$(image_of caddy)" \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1
ok "Caddyfile válido"
docker run --rm -v "$PWD/stack/caddy:/etc/caddy:ro" "$(image_of caddy)" \
  sh -c 'caddy fmt /etc/caddy/Caddyfile | diff -u /etc/caddy/Caddyfile -'
ok "Caddyfile formatado"

step "prometheus"
docker run --rm -v "$PWD/stack/observability/prometheus:/p:ro" --entrypoint promtool "$(image_of prometheus)" \
  check config /p/prometheus.yml >/dev/null
ok "prometheus.yml válido"

step "loki"
docker run --rm -v "$PWD/stack/observability/loki:/etc/loki:ro" "$(image_of loki)" \
  -config.file=/etc/loki/loki.yaml -verify-config >/dev/null 2>&1
ok "loki.yaml válido"

step "alloy"
docker run --rm -v "$PWD/stack/observability/alloy:/a:ro" "$(image_of alloy)" validate /a/config.alloy
docker run --rm -v "$PWD/stack/observability/alloy:/a:ro" "$(image_of alloy)" fmt /a/config.alloy \
  | diff -u stack/observability/alloy/config.alloy -
ok "config.alloy válido e formatado"

step "blackbox"
docker run --rm -v "$PWD/stack/observability/blackbox:/b:ro" "$(image_of blackbox)" \
  --config.file=/b/blackbox.yml --config.check >/dev/null 2>&1
ok "blackbox.yml válido"

step "tempo"
# O Tempo não tem modo "só validar": sobe o binário por alguns segundos e procura erro de config.
tempo_out="$(timeout 20 docker run --rm -v "$PWD/stack/observability/tempo:/etc/tempo:ro" "$(image_of tempo)" \
  -target=all -config.file=/etc/tempo/tempo.yaml 2>&1 || true)"
if grep -qiE 'failed parsing config|field .* not found|invalid' <<<"$tempo_out"; then
  echo "$tempo_out" | grep -iE 'failed|not found|invalid' >&2
  exit 1
fi
ok "tempo.yaml válido"

step "grafana dashboards"
for f in stack/observability/grafana/dashboards/*/*.json; do
  jq -e '.uid and .title' "$f" >/dev/null || { echo "  ✗ $f sem uid/title" >&2; exit 1; }
done
dupes="$(jq -r '.uid' stack/observability/grafana/dashboards/*/*.json | sort | uniq -d)"
[[ -z "$dupes" ]] || { echo "  ✗ uid duplicado: $dupes" >&2; exit 1; }
ok "dashboards com uid único"

printf '\033[32m✔ tudo válido\033[0m\n'
