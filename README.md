# wisp

Subagentes efêmeros em outras máquinas, com **Claude Code** ou **Codex**. Cada `wisp spawn` sobe um
container Docker novo num host via SSH (sem root, raiz só leitura, teto de RAM e CPU), roda o motor
escolhido com o login deste Mac e apaga o container quando o resultado é recolhido.

Só biblioteca padrão do Python, sem dependências.

## Uso

```bash
wisp spawn "missão autocontida" --ram 2      # devolve {"id": "wp-xxxxxx", ...} na hora
wisp spawn "missão" --engine codex [--model M]   # mesmo fluxo, com Codex
wisp wait wp-xxxxxx                         # espera, imprime o JSON e apaga o container
wisp result wp-xxxxxx                       # igual, sem esperar
wisp kill wp-xxxxxx
wisp ls                                     # cota e RAM livre por host, agentes vivos
wisp gc                                     # remove containers terminados esquecidos
wisp dash                                   # painel em http://127.0.0.1:7717
```

O resultado tem o mesmo formato nos dois motores (`result`, `usage`, `engine`, `exit_code`).
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

No Codex (`~/.codex/config.toml`); o timeout alto é porque `wait_agent` espera até 900 s:

```toml
[mcp_servers.wisp]
command = "python3"
args = ["/Users/you/Projects/wisp/mcp_server.py"]
tool_timeout_sec = 1000

[mcp_servers.wisp.tools.wait_agent]      # idem list_agents e agent_result
approval_mode = "approve"
```

`hosts.json`: `ssh` (alias do `~/.ssh/config`), `max_ram_gb` (cota somada dos agentes),
`keep_free_gb` (RAM que a máquina precisa manter livre), `cpus_per_agent`.

## Credenciais

Só o access token sai do Mac, **nunca o refresh token**: o container não consegue renovar nem
rotacionar a sessão, então o login daqui nunca cai. Vai pelo stdin do SSH para não aparecer em
`argv`, e o `timeout` da missão é cortado para caber na validade do token.

- **claude**: `$CLAUDE_CODE_OAUTH_TOKEN`, ou o login do Claude Code no Keychain.
- **codex**: `$OPENAI_API_KEY`, ou o login do ChatGPT em `~/.codex/auth.json` (`$CODEX_HOME`); o
  container recebe uma cópia desse arquivo sem o `refresh_token`. O access token vale ~10 dias; se
  vencer, abra o Codex uma vez neste Mac para ele renovar.
