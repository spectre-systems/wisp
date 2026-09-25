#!/usr/bin/env python3
"""Servidor MCP (stdio) do wisp. Só biblioteca padrão; chama o CLI `wisp` por baixo.

Registro:  claude mcp add --scope user wisp -- python3 ~/Projects/wisp/mcp_server.py
"""
import json, subprocess, sys, threading, time
from pathlib import Path

WISP = str(Path(__file__).resolve().parent / "wisp")
PROTOCOLS = {"2024-11-05", "2025-03-26", "2025-06-18"}

INSTRUCTIONS = """\
wisp roda subagentes Claude efêmeros e isolados em outras máquinas (hoje o optimus), sem gastar RAM desta.
Cada subagente é um container novo (sem root, raiz só leitura, teto de RAM) que roda `claude -p <missão>`
com o login do usuário e é apagado quando o resultado é recolhido.

Quando usar: o usuário pede subagente remoto / "roda no wisp" / "sobe N subagentes", ou há tarefas
independentes e pesadas que podem rodar em paralelo fora daqui.

Como usar bem:
- Paralelo: chame spawn_agent para todas as missões primeiro, depois wait_agent para cada id (em paralelo).
- A missão tem que ser autocontida: o container começa vazio, não vê arquivos desta máquina e não tem
  credenciais de git/SSH. Ponha todo o contexto e dados na própria missão e peça resposta em JSON ou markdown curto.
  Ele tem internet (WebFetch, curl, git clone de repositório público).
- Cota: optimus aceita 4 GB somados. Se spawn_agent disser que não há RAM, espere um terminar ou peça menos.
  Não aumente a cota em ~/.wisp/hosts.json sem o usuário pedir (o optimus roda WAHA em produção).
- Sempre recolha com wait_agent ou agent_result: é isso que apaga o container. Ao fim, list_agents deve estar vazio.
- Cada subagente consome o limite da assinatura do usuário. Não dispare dezenas.
"""

TOOLS = [
    {"name": "spawn_agent",
     "description": "Sobe um subagente Claude efêmero num host com RAM livre e devolve o id na hora (não espera).",
     "inputSchema": {"type": "object", "required": ["mission"], "properties": {
         "mission": {"type": "string", "description": "Missão completa e autocontida, com todo o contexto necessário."},
         "ram_gb": {"type": "integer", "default": 2, "minimum": 1, "maximum": 16},
         "max_turns": {"type": "integer", "default": 20},
         "timeout_s": {"type": "integer", "default": 1800, "description": "Tempo máximo da missão."},
         "host": {"type": "string", "description": "Força um host da lista. Omitir = escolha automática."}}}},
    {"name": "wait_agent",
     "description": "Espera o subagente terminar e devolve o JSON final (campo result = resposta). Apaga o container.",
     "inputSchema": {"type": "object", "required": ["id"], "properties": {
         "id": {"type": "string"},
         "max_wait_s": {"type": "integer", "default": 900,
                        "description": "Desiste de esperar depois disso e devolve status running."}}}},
    {"name": "agent_result",
     "description": "Resultado sem esperar: devolve o JSON final (e apaga o container) ou status running.",
     "inputSchema": {"type": "object", "required": ["id"], "properties": {"id": {"type": "string"}}}},
    {"name": "kill_agent",
     "description": "Mata e apaga um subagente na hora.",
     "inputSchema": {"type": "object", "required": ["id"], "properties": {"id": {"type": "string"}}}},
    {"name": "list_agents",
     "description": "Cota livre de RAM por host e subagentes vivos.",
     "inputSchema": {"type": "object", "properties": {}}},
]


def cli(*args, timeout=120):
    r = subprocess.run([sys.executable, WISP, *map(str, args)], capture_output=True, text=True, timeout=timeout)
    out = (r.stdout.strip() + ("\n" + r.stderr.strip() if r.stderr.strip() else "")).strip()
    return out, r.returncode != 0


def call(name, a):
    if name == "spawn_agent":
        args = ["spawn", a["mission"], "--ram", a.get("ram_gb", 2), "--turns", a.get("max_turns", 20),
                "--timeout", a.get("timeout_s", 1800)]
        if a.get("host"):
            args += ["--host", a["host"]]
        return cli(*args)
    if name == "wait_agent":
        deadline = time.time() + a.get("max_wait_s", 900)
        while True:
            out, err = cli("result", a["id"])
            if err or '"status": "running"' not in out or time.time() > deadline:
                return out, err
            time.sleep(4)
    if name == "agent_result":
        return cli("result", a["id"])
    if name == "kill_agent":
        return cli("kill", a["id"])
    if name == "list_agents":
        return cli("ls")
    return f"ferramenta desconhecida: {name}", True


lock = threading.Lock()


def send(msg):
    with lock:
        sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def handle(m):
    mid, method, p = m.get("id"), m.get("method"), m.get("params") or {}
    if mid is None:
        return                                          # notificação: nada a responder
    try:
        if method == "initialize":
            v = p.get("protocolVersion")
            res = {"protocolVersion": v if v in PROTOCOLS else "2025-06-18",
                   "capabilities": {"tools": {}},
                   "serverInfo": {"name": "wisp", "version": "0.1.0"},
                   "instructions": INSTRUCTIONS}
        elif method == "ping":
            res = {}
        elif method == "tools/list":
            res = {"tools": TOOLS}
        elif method == "tools/call":
            out, err = call(p["name"], p.get("arguments") or {})
            res = {"content": [{"type": "text", "text": out or "(sem saída)"}], "isError": err}
        else:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"método não suportado: {method}"}})
            return
        send({"jsonrpc": "2.0", "id": mid, "result": res})
    except Exception as e:  # erro de ferramenta vira resultado com isError, não derruba o servidor
        send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": f"erro: {e}"}], "isError": True}})


workers = []
for line in sys.stdin:
    if line.strip():
        t = threading.Thread(target=handle, args=(json.loads(line),))
        t.start(); workers.append(t)
for t in workers:                                        # stdin fechou: termina o que estava rodando
    t.join()
