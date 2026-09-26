# Primeiro deploy

Siga na ordem. Cada passo pode ser repetido sem efeito colateral.

## 1. DNS

| Registro | Tipo | Valor | Status |
|---|---|---|---|
| `openhands.samuelsublate.com.br` | A | `179.199.150.4` | ✅ já existe |

O Grafana fica no mesmo domínio, em `/grafana/`, então não precisa de outro registro.

Não crie registros AAAA por enquanto. O servidor não tem IPv6 configurado na stack, e um AAAA sem suporte quebra o acesso de quem usa IPv6.

## 2. Firewall da Hostinger (hPanel)

hPanel → VPS → **Segurança → Firewall** → crie um firewall com as regras abaixo, **ative** e clique em **sincronizar**:

| Protocolo | Porta | Origem |
|---|---|---|
| TCP | 22 | seu IP, se for fixo; senão, qualquer |
| TCP | 80 | qualquer (o Let's Encrypt precisa) |
| TCP | 443 | qualquer |
| UDP | 443 | qualquer (HTTP/3) |

Isto é defesa em profundidade: o Docker não consegue furar esse firewall, ao contrário do UFW.

## 3. Bot do Telegram (alertas)

1. No Telegram, fale com o **@BotFather** → `/newbot` → guarde o **token**.
2. Mande qualquer mensagem para o seu bot novo.
3. Abra `https://api.telegram.org/bot<TOKEN>/getUpdates` e copie o `chat.id`.

## 4. Segredos

```bash
just secrets-init    # gera sua chave age (se não existir) e o secrets/prod.sops.env cifrado
just secrets-edit    # preencha TELEGRAM_BOT_TOKEN e TELEGRAM_CHAT_ID
```

**Guarde uma cópia de `~/.config/sops/age/keys.txt` no seu gerenciador de senhas.** Sem ela, ninguém decifra os segredos, e o `OH_SECRET_KEY` é o que protege as chaves de LLM salvas no OpenHands.

Opcional e recomendado: crie uma segunda chave age de recuperação (`age-keygen -o recovery.txt`), adicione a pública ao `.sops.yaml`, rode `just secrets-updatekeys` e guarde `recovery.txt` **offline**.

## 5. Host (Ansible)

```bash
just bootstrap       # como root: usuário deploy, SSH endurecido, UFW, fail2ban, swap, daemon.json...
```

Agora, **em outro terminal**, confirme que o novo usuário entra:

```bash
ssh deploy@179.199.150.4 'id && docker ps'
```

Funcionou? Então bloqueie o root:

```bash
just lockdown        # PermitRootLogin no, AllowUsers deploy
just audit           # confira: sshd efetivo, UFW, fail2ban e portas abertas
```

Se algo der errado, use o console VNC do hPanel como acesso de emergência.

## 6. Deploy

```bash
git add -A && git commit -m "feat: configuração inicial"
just deploy
```

O deploy valida as configs, envia a pasta `stack/`, envia os segredos em stream, compila o Smokescreen, baixa as imagens e só termina quando os healthchecks passam.

## 7. Conferir

1. Abra `https://openhands.samuelsublate.com.br` e cole a chave que `just api-key` mostra.
2. Em **Settings**, configure o provedor de LLM. A chave fica cifrada com o `OH_SECRET_KEY` no volume `canvas_state`.
   - Se o provedor não estiver em `stack/egress/acl.yaml`, ele funciona do mesmo jeito (a ACL está em modo `report`), mas vale incluir.
3. Abra `https://openhands.samuelsublate.com.br/grafana/`, usuário `admin`, senha em `just grafana-password`.
   - Pasta **OpenHands** → *OpenHands — Agentes*: tudo verde na linha Saúde.
4. Confira a versão real do agent-server (a issue OpenHands#17531 relatou imagem com versão errada):

   ```bash
   curl -s https://openhands.samuelsublate.com.br/server_info | jq '{version, sdk_version}'
   ```

5. Mande um alerta de teste: Grafana → Alerting → Contact points → `telegram` → **Test**.

## 8. Backups (recomendado)

1. Crie um bucket no Backblaze B2 (ou outro S3) com lifecycle **"Keep only the last version"** e uma application key restrita a ele.
2. Gere um par age **só para backups** e guarde a chave privada offline:
   ```bash
   age-keygen -o backup-recovery.txt   # a linha "public key: age1..." vai para o segredo
   ```
3. `just secrets-edit` → descomente e preencha o bloco de backup, incluindo `COMPOSE_PROFILES=backup`.
4. `just deploy` e depois `just backup-now`. Confira o arquivo no bucket.
5. **Teste a restauração** ([operations.md](operations.md#restaurar-backup)). Backup que nunca foi restaurado não é backup.
