# wisp

Subagentes Claude efêmeros em outras máquinas. Cada `wisp spawn` sobe um container Docker
novo num host via SSH (sem root, raiz só leitura, teto de RAM e CPU), roda `claude -p <missão>`
com o login do Claude Code deste Mac e apaga o container quando o resultado é recolhido.

Só biblioteca padrão do Python, sem dependências.

## Uso

```bash
wisp spawn "missão autocontida" --ram 2      # devolve {"id": "wp-xxxxxx", ...} na hora
wisp wait wp-xxxxxx                         # espera, imprime o JSON e apaga o container
wisp result wp-xxxxxx                       # igual, sem esperar
wisp kill wp-xxxxxx
wisp ls                                     # cota e RAM livre por host, agentes vivos
wisp gc                                     # remove containers terminados esquecidos
wisp dash                                   # painel em http://127.0.0.1:7717
```

O container começa vazio: não vê arquivos desta máquina e não tem credenciais de git/SSH.
Todo o contexto vai na missão. Ele tem internet.

## Dashboard

`wisp dash` abre uma página local (só `127.0.0.1`, nada exposto na rede) que atualiza a cada 5 s:

- RAM da máquina: quanto é de outros processos, quanto é dos agentes, quanto está livre;
- cota do wisp reservada vs. máximo do host;
- cada agente com idade, RAM real, teto, CPU e um botão para matar.

## Instalação

```bash
git clone git@github.com:<org>/wisp.git ~/Projects/wisp
ln -s ~/Projects/wisp/wisp ~/.local/bin/wisp
mkdir -p ~/.wisp && cp ~/Projects/wisp/hosts.example.json ~/.wisp/hosts.json   # edite

# imagem em cada host
scp Dockerfile HOST:/root/wisp/ && ssh HOST 'docker build -t wisp-agent /root/wisp'

# MCP para o Claude Code (spawn_agent, wait_agent, agent_result, kill_agent, list_agents)
claude mcp add --scope user wisp -- python3 ~/Projects/wisp/mcp_server.py
```

`hosts.json`: `ssh` (alias do `~/.ssh/config`), `max_ram_gb` (cota somada dos agentes),
`keep_free_gb` (RAM que a máquina precisa manter livre), `cpus_per_agent`.

## Token

Usa `$CLAUDE_CODE_OAUTH_TOKEN` se existir; senão o access token do login do Claude Code no
Keychain deste Mac. Só o access token sai do Mac (nunca o refresh token), passado pelo stdin do
SSH para não aparecer em `argv`. O `timeout` da missão é cortado para caber na validade do token.
