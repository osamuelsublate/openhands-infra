# Modelo de segurança

## Achados sobre o OpenHands 1.24 (importante)

Encontrados lendo o código e **testando a stack localmente** (2026-09-26):

1. **`LOCAL_BACKEND_API_KEY` deixa a API do agent-server SEM autenticação.**
   - O `docker/entrypoint.sh` só exporta `OH_SESSION_API_KEYS_0` (a variável que o agent-server lê) quando **nenhuma** chave é informada. Se você passa `LOCAL_BACKEND_API_KEY`, como o README oficial manda, só a automação fica protegida.
   - Nesse caso `/api/settings`, `/api/conversations/*`, `/api/file/*` e `/api/bash/*` respondem `200` para qualquer um.
   - **Mitigação aqui:** o compose passa a chave em `OH_SESSION_API_KEYS_0`. Teste depois do deploy:
     ```bash
     curl -s -o /dev/null -w '%{http_code}\n' https://openhands.samuelsublate.com.br/api/settings   # esperado: 401
     ```
   - Vale reportar upstream (security@openhands.dev).
2. **A porta 8000 embute a chave de API no HTML** (OpenHands#16879). O Caddy aponta só para a 8080 (`PUBLIC_MODE_PORT`), que pede a chave na tela. A 8000 existe dentro do container, mas só o Caddy e o blackbox, ambos confiáveis, compartilham rede com ela.
3. **O token do editor VSCode é a própria chave de API** e aparece na URL (software-agent-sdk#4317). Editor desligado (`OH_ENABLE_VSCODE=false`) e `/vscode` retorna 404 no Caddy.
4. **A imagem traz a chave do PostHog embutida** e ativa telemetria mesmo com `DO_NOT_TRACK=1`. Desligada por variáveis, e `*.posthog.com` bloqueado no proxy mesmo em modo report.
5. **O usuário `openhands` tem sudo sem senha na imagem.** Neutralizado com `cap_drop: ALL` + `no-new-privileges`. Efeito colateral: o agente não consegue `apt-get install`.
6. **A chave fica no `localStorage` do navegador** (OpenHands#16492). Qualquer script na mesma origem a lê, então não instale extensões suspeitas no navegador que usa para acessar.
7. **Uma chave só, sem papéis** (OpenHands#17505): quem tem a chave tem tudo.
8. `/docs`, `/redoc` e `/openapi.json` são públicos por padrão e ficam bloqueados no Caddy.

## Camadas

```
internet
  │  Firewall da Hostinger (22, 80, 443/tcp+udp)       ← o Docker não fura
  │  UFW + fail2ban (22 com rate limit)
  ▼
Caddy (TLS, headers, log sem credenciais, allowlist opcional de IP)
  ▼
agent-canvas (chave de 256 bits; redes só internas; sem capabilities)
  │
  └─▶ egress-proxy (registra tudo; anti-SSRF; allowlist quando em enforce)
```

## O que está exposto

| Porta | Serviço | Observação |
|---|---|---|
| 22/tcp | sshd | só chave; root bloqueado após `just lockdown`; fail2ban |
| 80/tcp | Caddy | só redireciona para HTTPS e responde ao ACME |
| 443/tcp+udp | Caddy | OpenHands (`/`) e Grafana (`/grafana/`) |

Nenhum outro serviço publica porta, e o `scripts/validate.sh` falha se isso mudar. O node-exporter escuta só no IP da bridge interna `172.31.250.1`.

## Riscos residuais (conhecidos e aceitos)

- **Grafana e OpenHands dividem a mesma origem** (`/grafana/` no mesmo domínio), por escolha, para evitar um segundo subdomínio.
  - Como o OpenHands guarda a chave no `localStorage` (#16492), uma falha de XSS no Grafana poderia ler essa chave.
  - Mitigações: o Grafana exige login, o sanitizador de HTML dos painéis fica ligado (`GF_PANELS_DISABLE_SANITIZE_HTML=false`), a CSP do Grafana está ativa e não instalamos plugins de terceiros.
  - Para isolar de vez: servir o Grafana num subdomínio próprio (uma mudança no `Caddyfile` e no `compose.yaml`).

- **O agente enxerga as próprias variáveis de ambiente**, incluindo `OH_SESSION_API_KEYS_0` e `OH_SECRET_KEY`, porque roda como o mesmo usuário do servidor. Um agente manipulado por prompt injection poderia vazar a chave. Mitigações: ACL do egress em `enforce`, alerta de destinos novos e rotação da chave. A separação completa exigiria o runtime Docker por conversa (que precisa do `docker.sock`, um risco maior).
- **Grupo `docker` equivale a root.** A chave SSH do `deploy` é, na prática, uma chave de root. Proteja-a com senha.
- **O cAdvisor roda `privileged`** para ler cgroups v2. Fica só na rede interna `obs`.
- **O backup usa um socket-proxy com POST** (start/stop). É restrito a essas duas ações, sem exec nem criação de containers.
- **Traces contêm prompts e saídas de ferramentas.** Há redação de padrões de segredo, retenção de 7 dias e acesso só pelo Grafana com login.

## Segredos

- No git: só `secrets/*.sops.env`, cifrados com age (SOPS). O pre-commit bloqueia arquivo não cifrado e o gitleaks roda no pre-commit e no CI.
- No servidor: `/opt/openhands/.env` com modo `0600`, dono `deploy`. Ele é escrito via stream SSH e nunca toca o disco do laptop em texto plano.
- Chaves age: `~/.config/sops/age/keys.txt` no laptop, com cópia no gerenciador de senhas. A chave privada dos **backups** é outra e fica offline.
