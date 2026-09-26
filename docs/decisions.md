# Decisões de arquitetura

Registro curto do "por quê" de cada escolha. Formato: contexto → decisão → consequência.

### 1. Imagem oficial `ghcr.io/openhands/agent-canvas`, não imagens do Docker Hub
Nenhum resultado para "openhands" no Docker Hub é oficial; todos são builds de terceiros. O projeto publica no GHCR, com proveniência e SBOM. **Fixamos tag + digest.**

### 2. Docker Compose num VPS único, sem Kubernetes nem Terraform
Um servidor, um operador. O compose dá healthchecks, limites e redes isoladas com o menor número de peças. O provider Terraform da Hostinger não gerencia firewall, então não compensaria.

### 3. Caddy como borda
Certificados automáticos (emissão e renovação), HTTP/3 e WebSocket sem configuração, métricas Prometheus nativas, Caddyfile legível. Aponta só para a porta em modo público do agent-canvas.

### 4. Ansible para o host, pequeno e sem roles de terceiros
Idempotência, `--check --diff` para detectar drift e `validate:` antes de gravar o sshd. Não usamos `devsec.hardening`, que desliga `ip_forward` e quebra o Docker, nem `geerlingguy.docker`, porque o Docker já veio instalado.

### 5. Deploy por rsync + ssh, não por `docker context`
Com contexto remoto, os arquivos montados (Caddyfile, configs) não existiriam no servidor. O rsync entrega o estado renderizado, e o servidor não precisa de git nem da chave age.

### 6. SOPS + age para segredos
Os segredos ficam cifrados no próprio repositório, com diff legível por chave e sem GPG. São decifrados só no laptop e enviados em stream.

### 7. Smokescreen como proxy de saída
Faz exatamente este trabalho: log JSON por decisão, modo `report` (observar antes de bloquear), allowlist por domínio e anti-SSRF por padrão. Não publica imagem, então compilamos de um commit fixo; o Renovate acompanha o commit.

### 8. Prometheus coleta; Alloy só logs e traces
O Prometheus faz pull direto de tudo, com página de targets e `up{}`. O Alloy é o coletor único de logs (Docker e journald) e de OTLP, onde fica a redação de segredos. O Tempo empurra span metrics para o Prometheus.

### 9. Span logs para tokens e custo
Os tokens estão em atributos de span, que o span-metrics do Tempo não soma. O conector `spanlogs` do Alloy grava uma linha logfmt por span no Loki, e o LogQL `unwrap` soma tokens e custo por modelo.

### 10. Alertas gerenciados pelo Grafana, com contato no Telegram
Um só lugar para regras de métricas (Prometheus) e de logs (Loki). Tudo provisionado por arquivo; o git é a fonte da verdade (`allowUiUpdates: false`).

### 11. Backup opcional por profile
O compose interpola até serviços de profiles inativos, então as variáveis `BACKUP_*` não são obrigatórias no YAML. O `deploy.sh` exige essas variáveis quando `COMPOSE_PROFILES=backup`.

### 12. Grafana em `/grafana/` no mesmo domínio do OpenHands
Evita um segundo subdomínio e registro DNS. O custo é compartilhar a origem com o OpenHands, que guarda a chave no `localStorage`. Esse risco foi aceito com mitigações (ver [security.md](security.md)). O Grafana usa `serve_from_sub_path` e o Caddy separa as rotas com `handle`.
