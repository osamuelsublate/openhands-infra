#!/usr/bin/env bash
# Cria secrets/prod.sops.env a partir do modelo, com chaves aleatórias, já cifrado.
# O texto plano nunca toca o disco: é gerado em memória e passado ao sops via stdin.
set -euo pipefail
cd "$(dirname "$0")/.."

readonly TARGET=secrets/prod.sops.env
readonly KEYFILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

command -v sops >/dev/null || { echo "instale o sops (https://github.com/getsops/sops)" >&2; exit 1; }
command -v age-keygen >/dev/null || { echo "instale o age (https://github.com/FiloSottile/age)" >&2; exit 1; }

if [[ -e "$TARGET" ]]; then
  echo "$TARGET já existe; use: just secrets-edit" >&2
  exit 1
fi

# 1) chave age do operador
if [[ ! -f "$KEYFILE" ]]; then
  echo "→ gerando sua chave age em $KEYFILE"
  mkdir -p "$(dirname "$KEYFILE")"
  (umask 077 && age-keygen -o "$KEYFILE")
fi
recipient="$(age-keygen -y "$KEYFILE")"

# 2) .sops.yaml aponta para a sua chave pública
if grep -q AGE_RECIPIENTS_PLACEHOLDER .sops.yaml; then
  sed -i "s|AGE_RECIPIENTS_PLACEHOLDER|${recipient}|" .sops.yaml
  echo "→ .sops.yaml agora cifra para ${recipient}"
  echo "  (recomendado: adicione uma 2ª chave de recuperação guardada offline)"
fi

# 3) gera os valores e cifra direto do stdin
rand_hex() { openssl rand -hex 32; }
rand_pw() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }

sed -e "s|^LOCAL_BACKEND_API_KEY=$|LOCAL_BACKEND_API_KEY=$(rand_hex)|" \
    -e "s|^OH_SECRET_KEY=$|OH_SECRET_KEY=$(rand_hex)|" \
    -e "s|^GRAFANA_ADMIN_PASSWORD=$|GRAFANA_ADMIN_PASSWORD=$(rand_pw)|" \
    secrets/prod.env.example \
  | grep -vE '^\s*(#|$)' \
  | sops encrypt --input-type dotenv --output-type dotenv \
      --filename-override "$TARGET" /dev/stdin > "$TARGET"

echo "✓ $TARGET criado e cifrado."
echo "  Falta preencher TELEGRAM_BOT_TOKEN e TELEGRAM_CHAT_ID: just secrets-edit"
