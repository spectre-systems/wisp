#!/usr/bin/env python3
"""wisp: subagentes Claude efêmeros numa lista de máquinas via SSH + Docker.

  wisp spawn "missão" [--ram 2] [--host optimus] [--turns 20] [--timeout 1800]
  wisp wait ID          espera terminar, imprime o JSON e apaga o container
  wisp result ID        igual ao wait, mas não espera (diz se ainda está rodando)
  wisp status ID
  wisp kill ID
  wisp ls               capacidade de cada host e agentes vivos
  wisp gc               apaga containers terminados esquecidos
  wisp dash [--port 7717]   painel no navegador: RAM por host, cota, agentes vivos

Hosts em ~/.wisp/hosts.json. Token: $CLAUDE_CODE_OAUTH_TOKEN ou o login
do Claude Code guardado no Keychain deste Mac.
"""
import argparse, json, os, secrets, shlex, subprocess, sys, time
from pathlib import Path

HOME = Path.home() / ".wisp"
HOSTS = json.loads((HOME / "hosts.json").read_text())
IMAGE = "wisp-agent"


def ssh(host, cmd, stdin=None, check=True):
    r = subprocess.run(["ssh", "-o", "ConnectTimeout=8", HOSTS[host]["ssh"], cmd],
                       input=stdin, capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.exit(f"[{host}] {r.stderr.strip() or r.stdout.strip()}")
    return r


def _mac_login():
    """Access token do login do Claude Code neste Mac (sem o refresh token)."""
    r = subprocess.run(["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
                       capture_output=True, text=True)
    try:
        o = json.loads(r.stdout)["claudeAiOauth"]
        return o["accessToken"], o["expiresAt"] / 1000
    except (ValueError, KeyError):
        return None, 0


def token(need_secs):
    """(token, segundos de validade). Só o access token sai do Mac: o container
    não consegue renovar a sessão, então nunca derruba o login daqui."""
    t = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")
    if t:
        return t, None
    t, exp = _mac_login()
    if t and exp - time.time() < 600:
        # quase vencendo: uma chamada mínima faz o Claude Code local renovar
        subprocess.run(["claude", "-p", "ok", "--max-turns", "1"], capture_output=True, timeout=120)
        t, exp = _mac_login()
    if not t:
        sys.exit("sem login do Claude Code neste Mac (rode `claude` e faça login)")
    left = exp - time.time()
    if left < 600:
        sys.exit("o token local não renovou; abra o Claude Code uma vez e tente de novo")
    return t, left


def capacity(host):
    """(GB livres na cota do wisp, GB livres de verdade na máquina)"""
    r = ssh(host, "awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo; "
                  f"docker ps --filter label=wisp --format '{{{{.Label \"wisp.ram\"}}}}'", check=False)
    if r.returncode != 0:
        return None
    lines = r.stdout.split()
    avail, used = int(lines[0]), sum(int(x) for x in lines[1:])
    return HOSTS[host]["max_ram_gb"] - used, avail


def find(agent_id):
    for h in HOSTS:
        r = ssh(h, f"docker inspect -f '{{{{.State.Status}}}}' {shlex.quote(agent_id)}", check=False)
        if r.returncode == 0:
            return h, r.stdout.strip()
    sys.exit(f"{agent_id}: não encontrado em nenhum host")


def gc(host, quiet=True):
    r = ssh(host, "docker ps -aq --filter label=wisp --filter status=exited | xargs -r docker rm", check=False)
    if not quiet and r.stdout.strip():
        print(f"[{host}] removidos: {len(r.stdout.split())}")


def cmd_spawn(a):
    hosts = [a.host] if a.host else list(HOSTS)
    best = None
    for h in hosts:
        cap = capacity(h)
        if cap is None:
            print(f"[{h}] inacessível, pulando", file=sys.stderr); continue
        quota, avail = cap
        if a.ram <= quota and avail - a.ram >= HOSTS[h]["keep_free_gb"]:
            if best is None or quota < best[1]:
                best = (h, quota)                      # best-fit: onde cabe mais justo
    if not best:
        sys.exit(f"sem {a.ram} GB livres agora em {', '.join(hosts)} (veja `wisp ls`)")
    h = best[0]
    tok, left = token(a.timeout)
    if left is not None and left - 300 < a.timeout:
        a.timeout = int(left - 300)                    # não passar da validade do token
        print(f"timeout reduzido para {a.timeout}s (validade do token)", file=sys.stderr)
    gc(h)
    agent_id = "wp-" + secrets.token_hex(3)
    cpus = HOSTS[h].get("cpus_per_agent", 1)
    inner = (f"timeout {a.timeout} claude -p \"$MISSAO\" --output-format json "
             f"--max-turns {a.turns} --permission-mode bypassPermissions")
    run = ["docker", "run", "-d", "--name", agent_id,
           "--label", "wisp", "--label", f"wisp.ram={a.ram}",
           "--memory", f"{a.ram}g", "--memory-swap", f"{a.ram}g", "--cpus", str(cpus),
           "--pids-limit", "512", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
           "--read-only", "--tmpfs", "/tmp:size=512m,mode=1777",
           "--tmpfs", f"/home/agent:size={max(1, a.ram // 2)}g,mode=1777",
           "--log-opt", "max-size=5m", "--log-opt", "max-file=1",
           "-e", "CLAUDE_CODE_OAUTH_TOKEN", "-e", f"MISSAO={a.mission}",
           IMAGE, "sh", "-c", inner]
    # o token vai pelo stdin do ssh: não aparece em argv nem no histórico
    remote = 'read -r T; export CLAUDE_CODE_OAUTH_TOKEN="$T"; ' + shlex.join(run)
    ssh(h, remote, stdin=tok + "\n")
    print(json.dumps({"id": agent_id, "host": h, "ram_gb": a.ram}))


def fetch_result(agent_id, wait):
    h, st = find(agent_id)
    while wait and st == "running":
        time.sleep(3)
        st = ssh(h, f"docker inspect -f '{{{{.State.Status}}}}' {agent_id}").stdout.strip()
    if st == "running":
        print(json.dumps({"id": agent_id, "host": h, "status": "running"})); return
    out = ssh(h, f"docker logs {agent_id} 2>/dev/null; echo; docker inspect -f '{{{{.State.ExitCode}}}}' {agent_id}").stdout
    body, code = out.rstrip().rsplit("\n", 1)
    ssh(h, f"docker rm {agent_id} >/dev/null")         # evaporou (e o token junto)
    try:
        res = json.loads(body.strip().splitlines()[-1])
    except (ValueError, IndexError):
        res = {"raw": body.strip()[-2000:]}
    res.update({"id": agent_id, "host": h, "exit_code": int(code)})
    if int(code) == 124:
        res["erro"] = "timeout"
    print(json.dumps(res, ensure_ascii=False))


def cmd_status(a):
    h, st = find(a.id)
    print(json.dumps({"id": a.id, "host": h, "status": st}))


def cmd_kill(a):
    h, _ = find(a.id)
    ssh(h, f"docker rm -f {a.id} >/dev/null")
    print(json.dumps({"id": a.id, "host": h, "status": "killed"}))


def cmd_ls(a):
    for h in HOSTS:
        cap = capacity(h)
        if cap is None:
            print(f"{h:12} inacessível"); continue
        quota, avail = cap
        print(f"{h:12} cota livre {quota}/{HOSTS[h]['max_ram_gb']} GB · RAM livre na máquina {avail} GB "
              f"(reserva {HOSTS[h]['keep_free_gb']} GB)")
        r = ssh(h, "docker ps -a --filter label=wisp --format "
                   "'  {{.Names}}  {{.Label \"wisp.ram\"}}GB  {{.Status}}'", check=False)
        if r.stdout.strip():
            print(r.stdout.rstrip())


STATE_CMD = r"""awk '/^MemTotal|^MemAvailable/{print $2}' /proc/meminfo; echo @@
docker ps -a --filter label=wisp --format '{{.Names}}|{{.Label "wisp.ram"}}|{{.State}}|{{.RunningFor}}'; echo @@
ids=$(docker ps -q --filter label=wisp)
[ -n "$ids" ] && docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}|{{.CPUPerc}}' $ids; true"""
UNITS = {"B": 1 / 2**20, "KiB": 1 / 1024, "MiB": 1, "GiB": 1024}


def _mib(s):
    """'123.4MiB' -> 123.4"""
    for u in sorted(UNITS, key=len, reverse=True):
        if s.endswith(u):
            return float(s[:-len(u)]) * UNITS[u]
    return 0.0


def host_state(h):
    """Um SSH por host: RAM da máquina, cota e uso real de cada agente."""
    cfg = {k: HOSTS[h][k] for k in ("max_ram_gb", "keep_free_gb")}
    r = ssh(h, STATE_CMD, check=False)
    if r.returncode != 0:
        return {"host": h, "ok": False, "error": (r.stderr or r.stdout).strip()[-300:], **cfg}
    mem, ps, stats = (part.strip().splitlines() for part in r.stdout.split("@@"))
    stats = {n: (_mib(m.split("/")[0].strip()), cpu) for n, m, cpu in (l.split("|") for l in stats if l)}
    agents = []
    for line in ps:
        name, ram, state, age = line.split("|")
        used, cpu = stats.get(name, (0.0, ""))
        agents.append({"id": name, "ram_gb": int(ram or 0), "state": state, "age": age,
                       "used_mib": round(used), "cpu": cpu})
    total, avail = (int(x) / 2**20 for x in mem)
    return {"host": h, "ok": True, **cfg, "mem_total_gb": round(total, 1), "mem_avail_gb": round(avail, 1),
            "quota_used_gb": sum(a["ram_gb"] for a in agents if a["state"] == "running"), "agents": agents}


def cmd_dash(a):
    import re, threading, webbrowser
    from concurrent.futures import ThreadPoolExecutor
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    page = (Path(__file__).resolve().parent / "dash.html").read_bytes()
    pool = ThreadPoolExecutor(max_workers=max(1, len(HOSTS)))

    class H(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, code, body, ctype="application/json"):
            self.send_response(code)
            self.send_header("Content-Type", ctype + "; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/":
                return self.reply(200, page, "text/html")
            if self.path == "/api/state":
                hosts = list(pool.map(host_state, HOSTS))
                return self.reply(200, json.dumps({"hosts": hosts, "at": time.time()}).encode())
            self.reply(404, b"{}")

        def do_POST(self):
            m = re.fullmatch(r"/api/kill/([\w.-]+)/(wp-[0-9a-f]{6})", self.path)
            if not m or m[1] not in HOSTS or self.headers.get("Origin") not in (None, origin):
                return self.reply(400, b'{"error": "pedido invalido"}')
            ssh(m[1], f"docker rm -f {m[2]} >/dev/null", check=False)
            self.reply(200, json.dumps({"killed": m[2]}).encode())

    srv = ThreadingHTTPServer(("127.0.0.1", a.port), H)     # só loopback: nada exposto na rede
    origin = f"http://127.0.0.1:{a.port}"
    print(f"wisp dash em {origin}  (Ctrl+C para sair)")
    if not a.no_open:
        threading.Timer(0.3, webbrowser.open, [origin]).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


def main():
    p = argparse.ArgumentParser(prog="wisp")
    s = p.add_subparsers(dest="cmd", required=True)
    sp = s.add_parser("spawn"); sp.add_argument("mission"); sp.add_argument("--ram", type=int, default=2)
    sp.add_argument("--host"); sp.add_argument("--turns", type=int, default=20)
    sp.add_argument("--timeout", type=int, default=1800)
    for c in ("wait", "result", "status", "kill"):
        s.add_parser(c).add_argument("id")
    s.add_parser("ls"); s.add_parser("gc")
    d = s.add_parser("dash"); d.add_argument("--port", type=int, default=7717)
    d.add_argument("--no-open", action="store_true")
    a = p.parse_args()
    if a.cmd == "spawn": cmd_spawn(a)
    elif a.cmd == "wait": fetch_result(a.id, True)
    elif a.cmd == "result": fetch_result(a.id, False)
    elif a.cmd == "status": cmd_status(a)
    elif a.cmd == "kill": cmd_kill(a)
    elif a.cmd == "ls": cmd_ls(a)
    elif a.cmd == "dash": cmd_dash(a)
    elif a.cmd == "gc":
        for h in HOSTS: gc(h, quiet=False)


if __name__ == "__main__":
    main()
