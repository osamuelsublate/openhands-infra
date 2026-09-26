#!/usr/bin/env bash
# Hook do pre-commit: todo secrets/*.sops.env precisa ter o MAC do SOPS (= está cifrado).
set -euo pipefail
for f in "$@"; do
  grep -q '^sops_mac=' "$f" || { echo "NÃO CIFRADO: $f" >&2; exit 1; }
done
