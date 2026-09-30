# syntax=docker/dockerfile:1.7
# westbound-verifier: the replay verification sidecar (WP N8.2; docs/DETERMINISM.md →
# Verifier deploy, docs/SERVER.md → Running the verifier). Spec: multiplayer handoff →
# Resource budget ("the verifier: one job at a time, nice 10, 1 GB").
#
# It runs `westbound-server verify-worker` (the queue worker alone, against the server's
# /data volume) and, for each job, the headless Godot verifier of the SAME game build as
# the clients whose runs it checks (build parity): the Godot Linux debug template and the
# game pack exported with the "Verifier (Linux headless)" preset, one directory per
# supported client build: /verifier/<client_build>/westbound + westbound.pck (the pack
# next to the binary loads automatically; export templates ignore --script and
# --main-pack, so `-- --verifier=1` makes the game's main scene hand over to the
# verifier's command line).
#
# Build context: build/verifier/ as tools/verifier/export_verifier.sh leaves it
# (<build>/westbound + <build>/westbound.pck + <build>/build_info.cfg), plus the older
# builds tools/verifier/carry_builds.sh carries over from the previous image and its
# BUILDS.txt (N8.3). The server binary comes from a server image of the same commit
# (CI builds it from source: .github/workflows/verifier.yml):
#
#   tools/verifier/export_verifier.sh
#   docker build -t westbound-server:local westbound-server
#   docker build -f westbound-server/verifier/Dockerfile \
#       --build-arg SERVER_IMAGE=westbound-server:local \
#       -t westbound-verifier build/verifier
#
# A job whose build has no /verifier/<build>/ here is set aside (the run stays
# "verifying"; the next worker start retries it), and --require-inputs=1 sets aside N8.1
# replays (no input stream) instead of the kinematic playback (docs/SERVER.md → Replays).
#
# Run it next to the server on the same /data volume, 1 CPU, 1 GB, with the server's
# WB_REPLAYS__WORKER_ENABLED=false: docs/OPERATIONS.md → Replay verification (Coolify),
# or westbound-server/verifier/docker-compose.verifier.yml.

ARG SERVER_IMAGE=ghcr.io/b3vet/westbound-server:edge
ARG RUNTIME_IMAGE=debian:bookworm-slim

FROM ${SERVER_IMAGE} AS server

FROM ${RUNTIME_IMAGE}
LABEL org.opencontainers.image.title="westbound-verifier" \
      org.opencontainers.image.description="Westbound replay verifier: westbound-server verify-worker + the headless Godot verifier" \
      org.opencontainers.image.source="https://github.com/b3vet/westbound"
# glibc, coreutils (`nice`) and CA certificates; the Godot template loads its
# display and audio libraries only on demand, and --headless needs none of them.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=server /usr/local/bin/westbound-server /usr/local/bin/westbound-server
COPY . /verifier/
# N8.3: a dry run over the stored replays, nothing written (docs/OPERATIONS.md → Replay
# verification → Before you switch it on):
#   docker run --rm -v <server volume>:/data:ro --entrypoint verify-backlog <this image>
COPY --chmod=755 <<'EOF' /usr/local/bin/verify-backlog
#!/bin/sh
# Verifies every /data/replays/<run_id>.wbr (or the files in $1) with this image's
# verifiers and prints each verdict; the database is not touched. The claims are the
# replay header's own (the server passes the run's, normally the same).
set -u
dir="${1:-/data/replays}"
work="$(mktemp -d)"
n=0; accepted=0; rejected=0; cannot=0; nobuild=0; other=0
for f in "$dir"/*.wbr; do
  [ -f "$f" ] || continue
  n=$((n + 1))
  id="$(basename "$f" .wbr)"
  build="$(od -An -tu4 -j24 -N4 "$f" | tr -d ' ')"
  bin="/verifier/$build/westbound"
  if [ ! -x "$bin" ]; then
    echo "run $id build $build: no verifier for this build here (the worker sets it aside)"
    nobuild=$((nobuild + 1)); continue
  fi
  nice -n 10 "$bin" --headless -- --verifier=1 --server=off --replay="$f" --out="$work/result.json" \
    --require-inputs=1 >"$work/log" 2>&1
  status=$?
  case $status in
    0) accepted=$((accepted + 1)) ;;
    1) rejected=$((rejected + 1)) ;;
    3) cannot=$((cannot + 1)) ;;
    *) other=$((other + 1)) ;;
  esac
  line="$(grep -h '^verify_replay:' "$work/log" | head -n 1)"
  echo "run $id build $build exit $status: ${line#verify_replay: }"
done
rm -rf "$work"
echo "verify-backlog: $n replays: $accepted accepted, $rejected rejected, $cannot cannot verify (set aside), $nobuild without a verifier here, $other errors"
EOF
# Godot writes user:// and its logs under HOME: a writable, throwaway home for the
# non-root user (the verifier saves nothing; `record_best` is off).
RUN chmod -R a+rX /verifier \
 && ls /verifier/*/westbound >/dev/null \
 && mkdir -p /home/verifier \
 && chown 65532:65532 /home/verifier \
 && for b in /verifier/*/westbound; do "$b" --version; done
ENV HOME=/home/verifier \
    WB_DB__PATH=/data/westbound.db \
    WB_LOG__FORMAT=json \
    WB_REPLAYS__WORKER_ENABLED=true \
    WB_REPLAYS__POLL_INTERVAL_SECS=10 \
    WB_REPLAYS__VERIFIER_COMMAND=nice,-n,10,/verifier/{build}/westbound,--headless,--,--verifier=1,--server=off,--replay={replay},--out={out},--seed={seed},--claimed-score={claimed_score},--claimed-hits={claimed_hits},--require-inputs=1
USER 65532:65532
VOLUME ["/data"]
ENTRYPOINT ["/usr/local/bin/westbound-server"]
CMD ["verify-worker"]
