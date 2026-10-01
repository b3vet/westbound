#!/usr/bin/env python3
"""End-to-end smoke test of the replay verifier image (WP N8.3; docs/DETERMINISM.md ->
Verifier deploy, docs/OPERATIONS.md -> Replay verification).

Runs the production layout with Docker: the server image (`serve`, its own worker off) and
the verifier image (`verify-worker`) on one shared /data volume. Then, through the public
API, like a client: four device accounts each submit a run and upload its replay.

  honest      the sample replay, the sample's claims          -> verified
  teleported  the sample with its path edited (tamper_replay) -> rejected (path_mismatch)
  inflated    the sample, a claimed score above the recomputed -> rejected (score)
  no-verifier the sample under a client build the image lacks  -> set aside: the run stays
                                                                 "verifying", the job
                                                                 `set_aside` with the reason

and the verifier binary once directly (`docker run` its entrypoint) on the honest and the
teleported replay. Exit 0 when every case answers as expected.

  tools/verifier/smoke_image.py --verifier-image=westbound-verifier:ci \\
      --server-image=westbound-server:ci --sample=DIR [--keep]

DIR holds sample.wbr + claims.json (tools/verifier/export_verifier.sh --keep-sample=DIR)
and gets tampered.wbr (written here with the Godot editor: tools/verifier/tamper_replay.gd,
unless it already exists). Needs docker and python3 (stdlib only).
"""

import argparse
import json
import os
import secrets
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
RUN_ID_OFFSET = 8  # westbound-server/crates/server/src/replays/format.rs
BUILD_OFFSET = 24
MISSING_BUILD = 999_999
INFLATE = 2
TIMEOUT_S = 300


def sh(*args, check=True, capture=True, **kw):
    r = subprocess.run(list(args), capture_output=capture, text=True, **kw)
    if check and r.returncode != 0:
        raise SystemExit(f"smoke_image: {' '.join(args)} failed ({r.returncode}):\n{r.stdout}{r.stderr}")
    return r


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Api:
    def __init__(self, base):
        self.base = base

    def call(self, method, path, token=None, body=None, content_type=None):
        headers = {}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        data = None
        if body is not None:
            if isinstance(body, (bytes, bytearray)):
                data = bytes(body)
                headers["Content-Type"] = content_type or "application/octet-stream"
            else:
                data = json.dumps(body).encode()
                headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        # Straight to the container, never through an HTTP proxy.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            with opener.open(req, timeout=30) as r:
                return r.status, json.loads(r.read() or b"null")
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"null")

    def account(self):
        status, body = self.call("POST", "/api/v1/auth/device", body=b"")
        assert status == 201, f"device account: {status} {body}"
        return body["access_token"]

    def me(self, token):
        status, body = self.call("GET", "/api/v1/boards/journey?period=all&view=global&limit=1", token)
        assert status == 200, f"board: {status} {body}"
        return body.get("me")


def run_body(key, claims, score, build):
    """A submission for the sample run (the shape of tests/common journey_run)."""
    return {
        "idempotency_key": key, "mode": "journey", "seed": claims["seed"], "date": claims["date"],
        "car": claims["car"], "client_build": build, "score": score,
        "distance_m": claims["distance_m"], "duration_s": claims["duration_s"],
        "legs_completed": 0, "coast_reached": False, "best_chain": 5000, "best_multiplier": 20.0,
        "passes": 1000, "close_passes": 50, "threads": 10, "cuts": 20, "top_speed_kmh": 280.0,
        "night_time_s": 0.0, "hits": claims["hits"], "journey_complete": False,
        "journey_time_s": 0.0, "journey_distance_m": 0.0,
    }


def direct_checks(args, sample, claims, build):
    """The image's verifier binary on its own, exactly as the worker runs it."""
    work = tempfile.mkdtemp(prefix="wb-verifier-direct-")
    os.chmod(work, 0o777)
    for name in ("sample.wbr", "tampered.wbr"):
        shutil.copy(os.path.join(sample, name), work)
    ok = True
    for name, want in (("sample.wbr", 0), ("tampered.wbr", 1)):
        r = sh("docker", "run", "--rm", "--network", "none", "-v", f"{work}:/work",
               "--entrypoint", "nice", args.verifier_image, "-n", "10", f"/verifier/{build}/westbound",
               "--headless", "--", "--verifier=1", "--server=off", f"--replay=/work/{name}",
               f"--out=/work/{name}.json", f"--seed={claims['seed']}",
               f"--claimed-score={claims['score']}", f"--claimed-hits={claims['hits']}",
               "--require-inputs=1", check=False)
        line = next((l for l in r.stdout.splitlines() if l.startswith("verify_replay:")), r.stdout[-400:])
        good = r.returncode == want
        ok &= good
        print(f"smoke_image: direct {name}: exit {r.returncode} (want {want}) {line}")
    shutil.rmtree(work, ignore_errors=True)
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--verifier-image", required=True)
    ap.add_argument("--server-image", required=True)
    ap.add_argument("--sample", required=True, help="dir with sample.wbr and claims.json")
    ap.add_argument("--keep", action="store_true", help="leave the containers and volume running")
    args = ap.parse_args()
    sample = os.path.abspath(args.sample)
    claims = json.load(open(os.path.join(sample, "claims.json")))
    honest = open(os.path.join(sample, "sample.wbr"), "rb").read()
    tampered_path = os.path.join(sample, "tampered.wbr")
    if not os.path.exists(tampered_path):
        sh(os.path.join(REPO, "tools", "godot.sh"), "--headless", "--path", REPO, "--script",
           "res://tools/verifier/tamper_replay.gd", "--", f"--in={os.path.join(sample, 'sample.wbr')}",
           f"--out={tampered_path}")
    tampered = open(tampered_path, "rb").read()
    build = int(claims["client_build"])

    ok = direct_checks(args, sample, claims, build)

    tag = secrets.token_hex(4)
    net, vol = f"wb-smoke-{tag}", f"wb-smoke-data-{tag}"
    server, verifier = f"wb-smoke-server-{tag}", f"wb-smoke-verifier-{tag}"
    port = free_port()
    env = {
        "WB_AUTH__JWT_SECRET": secrets.token_hex(32),
        "WB_AUTH__DEVICE_SECRET_PEPPER": secrets.token_hex(32),
        "WB_LOG__FORMAT": "text",
    }
    env_args = [a for k, v in env.items() for a in ("-e", f"{k}={v}")]
    try:
        sh("docker", "network", "create", net)
        sh("docker", "volume", "create", vol)
        sh("docker", "run", "-d", "--name", server, "--network", net, "-v", f"{vol}:/data",
           "-p", f"127.0.0.1:{port}:8080", *env_args,
           "-e", "WB_REPLAYS__WORKER_ENABLED=false",
           "-e", "WB_SERVER__RESTART_NOTICE_SECS=1",
           "-e", "WB_RATE_LIMITS__DEVICE_CREATE_BURST=50",
           args.server_image)
        api = Api(f"http://127.0.0.1:{port}")
        for _ in range(60):
            try:
                if api.call("GET", "/api/v1/health")[0] == 200:
                    break
            except (urllib.error.URLError, ConnectionError, OSError):
                pass
            time.sleep(1)
        else:
            raise SystemExit("smoke_image: the server did not come up")
        # The sidecar as in production: same volume, 1 CPU, 1 GB, verify-worker.
        sh("docker", "run", "-d", "--name", verifier, "--network", net, "-v", f"{vol}:/data",
           "--cpus", "1", "--memory", "1g", "--memory-swap", "1g", *env_args,
           "-e", "WB_REPLAYS__POLL_INTERVAL_SECS=1", args.verifier_image)

        cases = [
            ("honest", honest, claims["score"], build, "verified"),
            ("teleported", tampered, claims["score"], build, "rejected"),
            ("inflated", honest, claims["score"] * INFLATE + 100, build, "rejected"),
            ("no-verifier", honest, claims["score"], MISSING_BUILD, "set_aside"),
        ]
        runs = []
        for i, (name, data, score, run_build, want) in enumerate(cases):
            tok = api.account()
            status, receipt = api.call("POST", "/api/v1/runs", tok,
                                       run_body(f"smoke-{tag}-{i:04d}", claims, score, run_build))
            assert status == 201 and receipt.get("replay_required"), f"{name}: {status} {receipt}"
            run_id = int(receipt["run_id"])
            body = bytearray(data)
            struct.pack_into("<q", body, RUN_ID_OFFSET, run_id)
            struct.pack_into("<I", body, BUILD_OFFSET, run_build)
            status, up = api.call("POST", f"/api/v1/runs/{run_id}/replay", tok, body)
            assert status == 201, f"{name}: upload {status} {up}"
            runs.append((name, tok, run_id, want))
            print(f"smoke_image: {name}: run {run_id} submitted, replay uploaded")

        def replays():
            return sh("docker", "exec", server, "westbound-server", "admin", "replays", check=False).stdout

        deadline = time.time() + TIMEOUT_S
        while time.time() < deadline:
            out = replays()
            settled = sum(int(l.split()[1]) for l in out.splitlines()
                          if l.split()[:1] in (["done"], ["failed"], ["set_aside"]) and len(l.split()) == 2)
            if settled >= len(runs):
                break
            time.sleep(2)
        out = replays()
        print("smoke_image: admin replays:\n  " + out.strip().replace("\n", "\n  "))
        for name, tok, run_id, want in runs:
            me = api.me(tok)
            got = "rejected" if me is None else me.get("verification")
            if want == "set_aside":
                # N10.3 lists parked jobs as `set_aside` ("set aside run N"); older
                # servers listed them as `failed` with the reason.
                parked = f"set aside run {run_id} " in out or f"failed run {run_id} " in out
                good = got == "pending" and parked \
                    and f"no verifier for build {MISSING_BUILD}" in out
                got = f"{got} (verifying), job set aside" if good else got
            else:
                good = got == want
            ok &= good
            print(f"smoke_image: {name}: {got} (want {want}) {'OK' if good else 'FAIL'}")
        if not ok:
            print("---- verifier logs ----")
            print(sh("docker", "logs", verifier, check=False).stdout[-6000:])
            print(sh("docker", "logs", verifier, check=False).stderr[-6000:])
    finally:
        if not args.keep:
            for c in (server, verifier):
                subprocess.run(["docker", "rm", "-f", c], capture_output=True)
            subprocess.run(["docker", "volume", "rm", "-f", vol], capture_output=True)
            subprocess.run(["docker", "network", "rm", net], capture_output=True)
    print("smoke_image: PASS" if ok else "smoke_image: FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
