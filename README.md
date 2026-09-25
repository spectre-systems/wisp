# wisp

<p align="center"><img src="docs/hero.jpg" alt="Espíritos saindo de um notebook, pousando em caixas sobre servidores e voltando com o resultado" width="820"></p>

Subagentes efêmeros em outras máquinas, com **Claude Code** ou **Codex**. Cada `wisp spawn` sobe um
container Docker novo num host via SSH, roda o agente com o seu login e apaga o container quando o
resultado é recolhido. Nada fica rodando entre uma tarefa e outra.

Só biblioteca padrão do Python, sem dependências.

## O problema que ele resolve

<p align="center"><img src="docs/problema.jpg" alt="À esquerda, um notebook superaquecido cheio de agentes; à direita, o mesmo notebook tranquilo mandando os agentes para servidores" width="820"></p>

Rodar vários agentes em paralelo no seu computador pesa: cada um carrega ferramentas, builds,
testes e navegadores, e tudo isso disputa RAM com o que você está fazendo. E um agente com
permissão total na sua máquina enxerga seus arquivos e credenciais.

O wisp manda esse trabalho para máquinas que estão sobrando:

- **sua máquina fica leve**: o agente roda noutro lugar, você só recebe a resposta;
- **isolado de verdade**: container sem root, disco só leitura, teto de RAM e CPU, sem suas chaves;
- **não atrapalha o dono do host**: respeita uma cota e uma reserva de RAM que nunca é tocada;
- **some depois**: recolheu o resultado, o container é apagado, junto com o token.

## Como funciona

<p align="center"><img src="docs/flow.svg" alt="Animação: o controlador consulta o host, envia o token, o container nasce, trabalha e é apagado quando o resultado volta" width="820"></p>

Há dois papéis:

| | Controlador (seu computador) | Host (onde os agentes rodam) |
|---|---|---|
| O que tem | CLI `wisp`, MCP, `~/.wisp/hosts.json`, seus logins | Docker + imagem `wisp-agent` |
| O que roda | nada: cada comando é um SSH que roda `docker` no host | só os containers, enquanto trabalham |

Não há servidor, daemon nem banco de dados. O estado são os próprios containers, marcados com
rótulos do Docker (`wisp`, `wisp.ram`, `wisp.engine`) em cada host.

Um `spawn`, passo a passo:

1. pergunta a cada host, por SSH, a RAM livre e quanto da cota já está reservado;
2. escolhe o host onde o agente cabe mais justo sem invadir a reserva (*best-fit*);
3. manda só o access token pelo stdin do SSH (não aparece em `argv` nem no histórico);
4. sobe o container: sem root, `--read-only`, `--cap-drop ALL`, teto de RAM, CPU e processos;
5. `wisp wait` lê a saída, devolve o JSON e apaga o container.

## Uso

```bash
wisp spawn "missão autocontida" --ram 2          # devolve {"id": "wp-xxxxxx", ...} na hora
wisp spawn "missão" --engine codex [--model M]   # mesmo fluxo, com Codex
wisp wait wp-xxxxxx                              # espera, imprime o JSON e apaga o container
wisp result wp-xxxxxx                            # igual, sem esperar
wisp kill wp-xxxxxx
wisp ls                                          # cota e RAM livre por host, agentes vivos
wisp gc                                          # remove containers terminados esquecidos
wisp dash                                        # painel em http://127.0.0.1:7717
```

O resultado tem o mesmo formato nos dois motores (`result`, `usage`, `engine`, `exit_code`).
O container começa vazio: não vê arquivos da sua máquina e não tem credenciais de git/SSH.
Todo o contexto vai na missão. Ele tem internet.

## Dashboard

`wisp dash` abre uma página local (só `127.0.0.1`, nada exposto na rede) que atualiza a cada 5 s:

- RAM da máquina: quanto é de outros processos, quanto é dos agentes, quanto está livre;
- cota do wisp reservada vs. máximo do host;
- cada agente com motor, idade, RAM real, teto, CPU e um botão para matar.

## Instalação

```bash
git clone git@github.com:spectre-systems/wisp.git ~/Projects/wisp
ln -s ~/Projects/wisp/wisp ~/.local/bin/wisp
mkdir -p ~/.wisp && cp ~/Projects/wisp/hosts.example.json ~/.wisp/hosts.json   # edite

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

## Adicionar um host

<p align="center"><img src="docs/add-host.svg" alt="Animação: três passos (docker build, alias SSH, entrada no hosts.json) e o novo host aparece conectado" width="820"></p>

1. **No PC novo** (Linux com Docker e sshd; atrás de roteador, ponha no mesmo tailnet):
   ```bash
   mkdir -p /root/wisp   # copie o Dockerfile para cá
   docker build -t wisp-agent /root/wisp
   ```
2. **No controlador**, um alias no `~/.ssh/config` com sua chave autorizada no PC:
   ```
   Host outro-pc
     HostName 100.x.y.z
     User root
   ```
3. **No controlador**, uma entrada no `~/.wisp/hosts.json`:
   ```json
   "outro-pc": { "ssh": "outro-pc", "max_ram_gb": 8, "keep_free_gb": 2, "cpus_per_agent": 2 }
   ```

Pronto: `wisp ls`, `wisp dash` e `wisp spawn` passam a usar o host. Para forçar: `--host outro-pc`.

| Campo | Significado |
|---|---|
| `ssh` | alias do `~/.ssh/config` |
| `max_ram_gb` | soma máxima dos tetos dos agentes nesse host |
| `keep_free_gb` | RAM que precisa continuar livre; se não sobrar, o wisp não sobe agente ali |
| `cpus_per_agent` | limite de CPU de cada container |

## FAQ

### Colocar Docker em outros computadores não vai comer RAM deles?

<p align="center"><img src="docs/ram.svg" alt="Gráfico animado: a RAM dos agentes só aparece enquanto eles rodam e some quando terminam; a reserva nunca é tocada" width="820"></p>

Quase nada enquanto não há agente rodando. A RAM só é usada **enquanto um agente trabalha**, e
volta assim que o resultado é recolhido.

| Parado | RAM | Disco |
|---|---|---|
| Docker no Linux | ~50–100 MB | — |
| Imagem `wisp-agent` | 0 (imagem é arquivo) | ~1,1 GB |
| Containers | nenhum existe | — |

- O **teto** (`--ram 1`) não é consumido: é o máximo permitido. Num teste real, um agente com
  teto de 1 GB usou **211 MB**. Quem "pensa" é a API do modelo; o container só executa os
  comandos que o agente pede. Build, testes e navegador é que gastam de verdade.
- O `keep_free_gb` garante que o wisp **não sobe** agente se a máquina estiver apertada.

**Exceção: Mac ou Windows como host.** Lá o Docker Desktop roda uma VM Linux que reserva 2–4 GB
enquanto está aberta, mesmo sem container. Linux é o host ideal; Mac/Windows só se sobrar RAM.

### Que máquinas servem de host?

| Máquina | Hoje |
|---|---|
| Linux x86_64 | funciona |
| Linux ARM (Raspberry Pi, servidor ARM) | ainda não: o Dockerfile baixa o Codex de x86_64 |
| Mac | ainda não: a leitura de RAM usa `/proc/meminfo` |
| Windows | via WSL2 com Docker e sshd |
| usuário sem root | funciona se estiver no grupo `docker` |

O controlador precisa alcançar o host por SSH. Se não alcança, Tailscale resolve.

### E se eu quiser mandar agentes de outro computador?

Ele vira mais um **controlador**: clone o repo, copie o `hosts.json`, tenha SSH até os hosts e
os logins do Claude/Codex. Os controladores não conversam entre si, mas enxergam os mesmos
containers, porque o estado está nos rótulos do Docker de cada host. Hoje o controlador precisa ser
um Mac para o motor `claude` (o token vem do Keychain) ou exportar `CLAUDE_CODE_OAUTH_TOKEN`.

### O agente vê meus arquivos ou minhas chaves?

Não. O container começa vazio, sem seus arquivos, sem chave SSH e sem credencial de git. Recebe só
o access token do motor escolhido, que expira sozinho e não serve para renovar a sessão.

### Quanto custa?

Cada agente consome o limite da sua assinatura (Claude ou ChatGPT) como uma sessão normal. O
resultado traz `usage` com os tokens gastos.

## Credenciais

Só o access token sai do controlador, **nunca o refresh token**: o container não consegue renovar
nem rotacionar a sessão, então seu login nunca cai. Vai pelo stdin do SSH para não aparecer em
`argv`, e o `timeout` da missão é cortado para caber na validade do token.

- **claude**: `$CLAUDE_CODE_OAUTH_TOKEN`, ou o login do Claude Code no Keychain.
- **codex**: `$OPENAI_API_KEY`, ou o login do ChatGPT em `~/.codex/auth.json` (`$CODEX_HOME`); o
  container recebe uma cópia desse arquivo sem o `refresh_token`. O access token vale ~10 dias; se
  vencer, abra o Codex uma vez no controlador para ele renovar.

---

<sub>Ilustrações geradas com o Codex; animações em SVG puro (acompanham o tema claro/escuro do sistema).</sub>
