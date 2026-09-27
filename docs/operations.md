# Operação

## Mudar qualquer coisa

1. Edite no repositório.
2. `just validate` (o CI roda o mesmo).
3. Commit e `just deploy`.

O deploy recusa árvore suja. O servidor guarda o histórico em `just history`.

## Rollback

As imagens são fixadas por digest, então voltar o commit devolve exatamente os mesmos bytes:

```bash
git revert <commit>      # ou: git checkout <sha-bom> -- stack/
just deploy
```

Migrações de dados **não** voltam (banco do Grafana, estado do OpenHands). Antes de atualizar uma versão major, rode `just backup-now`.

## Atualizações

- **Imagens**: o Renovate abre PRs às segundas. O OpenHands tem PR próprio a qualquer hora (lança cerca de 2x por semana). Majors esperam aprovação no Dependency Dashboard.
  - Antes de aceitar um PR do OpenHands, leia as release notes e confira se o bug de autenticação descrito em [security.md](security.md) mudou.
- **Host**: patches de segurança são automáticos (unattended-upgrades), com reboot às 03:30 de Brasília quando necessário.
- **Docker Engine**: fica fora das atualizações automáticas porque reinicia tudo. Faça à mão:
  ```bash
  ssh deploy@179.199.150.4 'sudo apt-get update && sudo apt-get install --only-upgrade docker-ce docker-ce-cli containerd.io docker-compose-plugin'
  ```

## Egress: de "observar" para "bloquear"

A ACL começa em `action: report`: tudo passa e é registrado.

1. Use por 1–2 semanas.
2. Grafana → *Rede — Entrada e Saída* → **Destinos fora da allowlist**.
3. Adicione os legítimos em `stack/egress/acl.yaml` → `allowed_domains`.
4. Troque para `action: enforce`, faça commit e `just deploy`.

Com `enforce`, uma conta de agente comprometida (por exemplo, via prompt injection) não consegue mandar dados para um domínio qualquer.

## Rotacionar a chave de acesso do OpenHands

```bash
just secrets-edit        # novo LOCAL_BACKEND_API_KEY (openssl rand -hex 32)
just deploy
```

Os navegadores com a chave antiga vão pedir a nova. **Não** troque o `OH_SECRET_KEY`: ele cifra as chaves de LLM já salvas.

## Logs rápidos sem Grafana

```bash
just logs agent-canvas
just logs egress-proxy
just ps
```

## Acessar UIs internas (Prometheus, Alloy)

Elas não têm porta publicada. Use um túnel SSH:

```bash
just tunnel prometheus 9090    # http://localhost:9090
just tunnel alloy 12345        # http://localhost:12345 (grafo de componentes)
```

## Restaurar backup

```bash
# 1. no laptop: baixe o arquivo do bucket e decifre com a chave privada de backup (offline)
age -d -i backup-recovery.txt openhands-AAAA-MM-DDTHH-MM-SS.tar.zst.age | tar --zstd -x
# → backup/canvas_state, backup/canvas_workspace, backup/grafana_data ...

# 2. envie a pasta desejada para o servidor
rsync -az backup/canvas_state/ deploy@179.199.150.4:/tmp/restore-canvas_state/

# 3. no servidor: pare o serviço, copie para o volume, suba de novo
ssh deploy@179.199.150.4 '
  cd /opt/openhands && docker compose stop agent-canvas &&
  docker run --rm -v openhands_canvas_state:/dst -v /tmp/restore-canvas_state:/src:ro alpine \
    sh -c "cp -a /src/. /dst/" &&
  docker compose start agent-canvas && rm -rf /tmp/restore-canvas_state'
```

O estado do OpenHands só abre com o **mesmo** `OH_SECRET_KEY` que está nos segredos.

## Problemas comuns

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| `502` no domínio | agent-canvas reiniciando | `just logs agent-canvas`; o healthcheck leva até 3 min no boot |
| Certificado inválido | DNS não aponta para o servidor ou porta 80 fechada | confira DNS e firewall da Hostinger; `just logs caddy` |
| Agente não baixa pacotes | domínio negado no proxy | painel *Rede* → Decisões recentes; ajuste a `acl.yaml` |
| `git clone git@github.com:...` falha | SSH (porta 22) não passa pelo proxy HTTP | use URLs `https://` com token |
| Sem traces no Tempo | Alloy fora ou nenhuma conversa rodou | `just logs alloy`; dashboard *Stack — Saúde* |
| Alerta "Componente fora do ar" | um scrape falhou por mais de 5 min | o alerta traz o `job`; `just ps` |
| Canvas: *"Could not determine this backend's agent-server version… reported unknown"* | um agente apagou `/tmp/_MEI*`, onde o binário do agent-server se descompacta | o healthcheck detecta e reinicia o container sozinho em ~1 min; se persistir, `just restart agent-canvas` |
