# Arquitetura

## Redes

O princípio: **cada container só enxerga quem precisa**. As redes `internal: true` não têm rota para fora (sem gateway nem NAT); só resolvem os nomes dos containers da própria rede.

| Rede | Interna? | Quem participa | Para quê |
|---|---|---|---|
| `edge` | não | caddy | única rede com portas publicadas (80, 443, 443/udp) |
| `canvas_front` | **sim** | caddy, agent-canvas, blackbox | Caddy → UI/API; blackbox testa os backends por dentro |
| `grafana_front` | não | caddy, grafana | Caddy → Grafana; saída para o Telegram |
| `agent_egress` | **sim** | agent-canvas, egress-proxy | a única saída do agente |
| `egress_out` | não | egress-proxy | proxy → internet |
| `telemetry` | **sim** | agent-canvas, alloy | traces/logs OTLP |
| `obs` | **sim** | prometheus, loki, tempo, alloy, grafana, cadvisor, blackbox, caddy, egress-proxy | backend de observabilidade e scraping |
| `docker_api` | **sim** | alloy, docker-socket-proxy | leitura de logs dos containers |
| `hostmetrics` | não | prometheus | chega no node-exporter (rede do host) em `172.31.250.1:9100` |
| `probe` | não | blackbox | testa as URLs públicas como um visitante |
| `backup_api` / `backup_out` | sim / não | backup, backup-socket-proxy | parar/iniciar containers; upload S3 |

O **agent-canvas só está em redes internas**. Mesmo que uma ferramenta ignore as variáveis de proxy, não há rota para a internet e nem DNS externo. A única porta de saída é o Smokescreen, que registra cada destino.

## Fluxo de uma requisição

1. O navegador acessa `https://openhands.samuelsublate.com.br`. O Caddy termina o TLS, que tem certificado Let's Encrypt renovado sozinho. `/grafana/*` vai para o Grafana; todo o resto vai para o OpenHands.
2. O Caddy encaminha para `agent-canvas:8080`, a instância em **modo público**: o HTML não traz a chave, então a tela pede a chave de acesso.
3. A SPA chama `/api/*` e `/sockets` com o header `X-Session-API-Key`. O agent-server valida a chave.
4. Quando o agente chama o LLM, ou roda `pip`, `git` ou `curl`, a conexão sai via `egress-proxy:4750`. O Smokescreen decide com base em `stack/egress/acl.yaml` e grava uma linha JSON.
5. O SDK do agente emite traces OTLP para `alloy:4318`. O Alloy mascara segredos, normaliza o `service.name` e envia para o Tempo, e gera uma linha de log por span (com tokens e custo) para o Loki.

## Observabilidade

| Pergunta | Onde olhar |
|---|---|
| O site está no ar? O certificado vence quando? | Dashboard *OpenHands — Agentes* (linha Saúde) e alertas `public-url-down` e `tls-cert-expiring` |
| Quanto gastei de LLM? Qual modelo? | *OpenHands — Agentes* → Tokens e custo |
| O que o agente fez naquela conversa? | *OpenHands — Agentes* → Conversas recentes (abre o trace no Tempo) |
| Para onde os agentes se conectam? | *Rede — Entrada e Saída* |
| Alguém está tentando entrar? | *Segurança*, e o alerta `ssh-login` a cada login |
| O servidor aguenta mais? | *Host — Node Exporter Full*, *Stack — Saúde* |

### Retenção

| Dado | Retenção | Onde muda |
|---|---|---|
| Métricas | 30 dias ou 15 GB | `compose.yaml` → flags do prometheus |
| Logs | 30 dias (journal do host: 90) | `observability/loki/loki.yaml` |
| Traces | 7 dias (contêm prompts) | `observability/tempo/tempo.yaml` |

### Conteúdo sensível nos traces

O SDK do OpenHands (via `lmnr`) grava **sempre** o texto dos prompts, das respostas e das entradas e saídas das ferramentas nos spans; não há opção para desligar. Por isso o Alloy:

- apaga atributos com nome de credencial (`*api_key*`, `*token*`, `*secret*`...);
- mascara padrões de segredo em qualquer valor (`sk-...`, `ghp_...`, `github_pat_...`, `AKIA...`, `xox?-...`, `Bearer ...`, chaves privadas PEM);
- corta atributos em 32 KB.

Os traces ficam só 7 dias e são acessíveis só pelo Grafana, que exige login.

## Recursos

Limites (`deploy.resources.limits`) num VPS de 4 vCPU e 16 GB:

| Serviço | Memória | CPU |
|---|---|---|
| agent-canvas | 8 GB | 3 |
| prometheus, tempo | 1.5 GB cada | 1 |
| loki | 1 GB | 1 |
| grafana | 768 MB | 1 |
| alloy | 512 MB | 1 |
| demais | ≤ 256 MB | ≤ 1 |

Uso típico da observabilidade: 1.5–2.5 GB. O `OH_MAX_CONCURRENT_RUNS=3` limita as conversas simultâneas. Há 4 GB de swap como colchão.
