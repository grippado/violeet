#!/usr/bin/env python3
"""Driver PTY: sobe o Claude Code interativo, digita um prompt, e captura a tela.

Uso: pty_drive.py <settings.json> <prompt> <segundos_de_captura> <arquivo_saida>

Nao pressiona nada no dialogo de permissao: a ideia e justamente ver se ele
aparece. Aceita apenas o dialogo de trust do diretorio (Enter na 1a opcao).
"""
import os
import pty
import re
import select
import subprocess
import sys
import time

BIN = "/Users/grippado/.local/share/claude/versions/2.1.220"
settings, prompt, secs, out = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]

master, slave = pty.openpty()
env = dict(os.environ)
env["TERM"] = "xterm-256color"
for k in list(env):              # nao herdar contexto da sessao pai
    if k.startswith("CLAUDE") and k != "CLAUDE_CONFIG_DIR":
        env.pop(k)
env.pop("CLAUDECODE", None)

p = subprocess.Popen(
    [BIN, "--settings", settings, "--model", "claude-haiku-4-5-20251001"],
    stdin=slave, stdout=slave, stderr=slave,
    cwd="/private/tmp/violeet-spike", env=env, preexec_fn=os.setsid,
)
os.close(slave)

buf = bytearray()
t0 = time.time()
trust_done = False
prompt_sent = False
events = []


def note(msg):
    events.append(f"[+{time.time()-t0:6.1f}s] {msg}")
    print(events[-1], flush=True)


def screen():
    return buf.decode("utf-8", "replace")


while time.time() - t0 < secs:
    r, _, _ = select.select([master], [], [], 0.5)
    if r:
        try:
            chunk = os.read(master, 65536)
        except OSError:
            note("pty fechou")
            break
        if not chunk:
            break
        buf.extend(chunk)

    s = screen()

    if not trust_done and re.search(r"trust this folder|trust the files|Do you trust", s, re.I):
        note("dialogo de TRUST detectado -> aceitando (Enter)")
        os.write(master, b"\r")
        trust_done = True
        time.sleep(4)
        buf.clear()
        continue

    if not prompt_sent and time.time() - t0 > 10:
        note(f"digitando prompt: {prompt!r}")
        for ch in prompt:                 # digitar devagar: o TUI le raw
            os.write(master, ch.encode())
            time.sleep(0.01)
        time.sleep(1.5)
        os.write(master, b"\r")           # Enter separado do texto
        note("Enter enviado")
        prompt_sent = True
        time.sleep(1)
        continue

    if prompt_sent:
        # frame mais recente: tudo depois da ultima limpeza de tela
        frame = re.sub(r"\s+", "", s[-6000:])
        vis = "Doyouwanttoproceed?" in frame
        prev = globals().get("_vis", False)
        if vis and not prev:
            note(">>> DIALOGO DE PERMISSAO VISIVEL NA TELA <<<")
        if prev and not vis:
            note("<<< dialogo saiu da tela >>>")
        globals()["_vis"] = vis

note("captura encerrada")
try:
    p.terminate()
    time.sleep(1)
    p.kill()
except Exception:
    pass

with open(out, "w") as f:
    f.write("===== EVENTOS DO DRIVER =====\n")
    f.write("\n".join(events))
    f.write("\n\n===== SAIDA BRUTA DO PTY =====\n")
    f.write(screen())
print(f"\nsaida salva em {out} ({len(buf)} bytes)")
