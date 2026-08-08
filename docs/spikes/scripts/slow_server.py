#!/usr/bin/env python3
"""Cenario B: servidor HTTP minimo que segura a decisao por N segundos.

Rotas:
  /slow-allow   -> espera DELAY s, responde 200 com decision allow
  /error-500    -> responde 500 imediatamente (teste de erro)
  /never        -> nunca responde (dorme 20 min) para medir o timeout efetivo
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

DELAY = float(os.environ.get("SPIKE_DELAY", "90"))
LOG = "/tmp/violeet-spike/http.log"


def log(msg):
    with open(LOG, "a") as f:
        f.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")
        f.flush()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode()
        t0 = time.time()
        log(f"POST {self.path} recebido, {n} bytes")
        log(f"  payload: {body}")
        try:
            d = json.loads(body)
            log(f"  chaves: {sorted(d.keys())}")
            for k in ("tool_name", "tool_input", "permission_suggestions"):
                log(f"  {k}: {json.dumps(d.get(k), ensure_ascii=False) if k in d else '<AUSENTE>'}")
        except Exception as e:
            log(f"  !! payload nao e JSON: {e}")

        if self.path == "/error-500":
            log("  respondendo 500 imediatamente")
            self.send_response(500)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if self.path == "/never":
            log("  NUNCA respondendo (dormindo 20 min) - medindo timeout do cliente")
            try:
                for i in range(1200):
                    time.sleep(1)
                    if i % 30 == 29:
                        log(f"  ...ainda segurando ha {i+1}s")
            except Exception as e:
                log(f"  conexao morreu apos {time.time()-t0:.1f}s: {type(e).__name__}: {e}")
            return

        # /slow-allow
        log(f"  segurando por {DELAY}s antes de responder allow...")
        try:
            slept = 0.0
            while slept < DELAY:
                time.sleep(1)
                slept += 1
                if slept % 15 == 0:
                    log(f"  ...segurando ha {slept:.0f}s")
        except Exception as e:
            log(f"  interrompido apos {slept:.0f}s: {e}")
            return

        payload = json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {"behavior": "allow"},
            }
        }).encode()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            self.wfile.flush()
            log(f"  RESPONDIDO allow apos {time.time()-t0:.1f}s (cliente ainda conectado)")
        except Exception as e:
            log(f"  !! falhou ao responder apos {time.time()-t0:.1f}s: {type(e).__name__}: {e} "
                f"(cliente provavelmente ja desistiu)")

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    log(f"=== servidor de pe na porta {port}, DELAY={DELAY}s ===")
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
