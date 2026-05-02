#!/usr/bin/env python3
"""
sync-webhook — HMAC-authenticated trigger for the image-sync / config-sync
CronJobs. Routes:
  POST /_sync/image   → kubectl create job --from=cronjob/image-sync
  POST /_sync/config  → kubectl create job --from=cronjob/config-sync
  GET  /healthz       → 200 OK (kubelet probes)

Body must be JSON: {"job": "image-sync"|"config-sync", "ts": <unix-epoch>, ...}
Header X-Hub-Signature-256: "sha256=<hex(hmac(SECRET, raw_body))>"

Replay protection: |now - ts| ≤ TS_WINDOW_SEC.

Env:
  SYNC_HMAC_SECRET  — shared secret (sourced from k8s Secret cloudless-app-config)
  NAMESPACE         — k8s namespace for Jobs (default: cloudless)
  TS_WINDOW_SEC     — replay window in seconds (default: 300)
  PORT              — listen port (default: 8080)

This service holds no state. The actual drift detection + rollout logic lives
in the image-sync / config-sync CronJobs — we just *trigger* them via Job
creation. So replay-bombing is bounded by Job RBAC and kubectl rate limits;
even a flood would just create no-op Jobs that exit immediately when in sync.
"""
from __future__ import annotations

import hashlib
import hmac
import http.server
import json
import logging
import os
import socketserver
import subprocess
import sys
import time

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("sync-webhook")

SECRET = os.environ.get("SYNC_HMAC_SECRET", "").encode()
NAMESPACE = os.environ.get("NAMESPACE", "cloudless")
TS_WINDOW_SEC = int(os.environ.get("TS_WINDOW_SEC", "300"))
PORT = int(os.environ.get("PORT", "8080"))

# Path → CronJob name. Anything not in this map → 404.
JOB_MAP = {
    "/_sync/image": "image-sync",
    "/_sync/config": "config-sync",
}


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "sync-webhook/1.0"

    # Quieten access log; we emit our own structured lines below.
    def log_message(self, fmt, *args):
        pass

    def _json(self, status: int, body: dict) -> None:
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self._json(200, {"ok": True})
            return
        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:
        if not SECRET:
            log.error("missing SYNC_HMAC_SECRET — refusing all requests")
            self._json(503, {"error": "server not configured"})
            return

        cronjob = JOB_MAP.get(self.path)
        if not cronjob:
            self._json(404, {"error": "unknown path"})
            return

        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0 or length > 4096:
            self._json(400, {"error": "bad content length"})
            return
        body = self.rfile.read(length)

        sig_header = self.headers.get("X-Hub-Signature-256", "")
        expected = "sha256=" + hmac.new(SECRET, body, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig_header, expected):
            log.warning("hmac fail: path=%s sig=%s", self.path, sig_header[:16])
            self._json(401, {"error": "bad signature"})
            return

        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            self._json(400, {"error": "invalid json"})
            return

        ts = payload.get("ts")
        if not isinstance(ts, (int, float)) or abs(time.time() - ts) > TS_WINDOW_SEC:
            self._json(403, {"error": "stale or missing ts"})
            return

        # Stamp Job name with the SHA prefix when present (helps trace which
        # commit triggered it in `kubectl get jobs`).
        sha = str(payload.get("sha", ""))[:8] or "manual"
        job_name = f"{cronjob}-webhook-{sha}-{int(time.time())}"[:63]

        cmd = [
            "kubectl", "-n", NAMESPACE,
            "create", "job", job_name,
            f"--from=cronjob/{cronjob}",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if result.returncode != 0:
            log.error("kubectl create job failed: %s", result.stderr.strip())
            self._json(500, {"error": "kubectl failed", "stderr": result.stderr.strip()[:500]})
            return

        log.info("created job=%s cronjob=%s sha=%s", job_name, cronjob, sha)
        self._json(202, {"job": job_name, "cronjob": cronjob, "sha": sha})


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main() -> None:
    if not SECRET:
        log.error("SYNC_HMAC_SECRET not set in environment — exiting")
        sys.exit(1)
    log.info("listening on 0.0.0.0:%d (namespace=%s, ts-window=%ds)",
             PORT, NAMESPACE, TS_WINDOW_SEC)
    Server(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
