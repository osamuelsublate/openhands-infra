---
name: server-rules
---

# Regras deste servidor (obrigatórias)

Você roda dentro de um container compartilhado com o próprio agent-server que te
controla. Apagar ou encher os arquivos dele derruba todas as conversas, inclusive
a sua. Siga estas regras em toda tarefa.

## Onde trabalhar

- Clone repositórios e crie arquivos de trabalho em `~/workspace/` (por exemplo
  `~/workspace/<nome-do-repo>`). Esse diretório fica em disco e tem espaço de sobra.
- Use `/tmp` só para arquivos pequenos e passageiros.
- Antes de operações grandes (clones completos, `npm install`, builds), confira o
  espaço com `df -h ~/workspace /tmp`.

## O que você NUNCA deve apagar ou alterar

- `/tmp/_MEI*`: é onde o binário do agent-server se descompacta. Apagar derruba o
  servidor na hora.
- `/tmp/openhands-agent-server-*`, `~/.openhands/` e `/opt/`: estado e código do
  servidor, das conversas e das automações.
- Nunca rode `rm -rf` com curingas em `/tmp`, `~` ou `/`. Para liberar espaço,
  apague **somente** diretórios que você mesmo criou nesta tarefa, pelo nome exato.

## Credenciais

- O token do GitHub está na variável `GITHUB_PERSONAL_ACCESS_TOKEN` (não existe
  `GITHUB_TOKEN`). Para git, use HTTPS:
  `https://x-access-token:${GITHUB_PERSONAL_ACCESS_TOKEN}@github.com/<owner>/<repo>.git`
- Nunca imprima, grave em arquivo, commite ou envie tokens e chaves para lugar
  nenhum além da API a que pertencem.

## Rede e permissões

- Toda saída para a internet passa por um proxy HTTP já configurado nas variáveis
  de ambiente. Git por SSH (porta 22) não funciona: use sempre HTTPS.
- Não há `sudo` nem `apt-get`. Instale dependências no espaço do usuário:
  `pip install --user`, `uv`, `npm install` local ao projeto.
