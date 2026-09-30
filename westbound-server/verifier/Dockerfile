# syntax=docker/dockerfile:1.7
# westbound-verifier: the replay verification sidecar (WP N8.2; docs/DETERMINISM.md →
# Verifier deploy, docs/SERVER.md → Running the verifier). Spec: multiplayer handoff →
# Resource budget ("the verifier: one job at a time, nice 10, 1 GB").
#
# It runs `westbound-server verify-worker` (the queue worker alone, against the server's
# /data volume) and, for each job, the headless Godot verifier of the SAME game build as
# the clients whose runs it checks (build parity): the Godot Linux release template and
# the game pack exported with the "Verifier (Linux headless)" preset, one pack per
# supported client build, named <client_build>.pck.
#
# Build context: build/verifier/ as tools/verifier/export_verifier.sh leaves it
# (westbound + <build>.pck). The server binary comes from the server image of the same
# commit:
#
#   tools/verifier/export_verifier.sh
#   docker build -f westbound-server/verifier/Dockerfile \
#       --build-arg SERVER_IMAGE=ghcr.io/b3vet/westbound-server:edge \
#       -t westbound-verifier build/verifier
#
# Run it next to the server (westbound-server/verifier/docker-compose.verifier.yml): the
# same /data volume, mem_limit 1g, cpus 1; the server gets
# WB_REPLAYS__WORKER_ENABLED=false. Never enabled in production by this file alone.

ARG SERVER_IMAGE=ghcr.io/b3vet/westbound-server:edge
ARG RUNTIME_IMAGE=debian:bookworm-slim

FROM ${SERVER_IMAGE} AS server

FROM ${RUNTIME_IMAGE}
LABEL org.opencontainers.image.title="westbound-verifier" \
      org.opencontainers.image.description="Westbound replay verifier: westbound-server verify-worker + the headless Godot verifier" \
      org.opencontainers.image.source="https://github.com/b3vet/westbound"
# glibc, coreutils (`nice`) and CA certificates; the Godot release template loads its
# display and audio libraries only on demand, and --headless needs none of them.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=server /usr/local/bin/westbound-server /usr/local/bin/westbound-server
COPY westbound /verifier/westbound
COPY *.pck /verifier/
# Godot writes user:// and its logs under HOME: a writable, throwaway home for the
# non-root user (the verifier saves nothing; `record_best` is off).
RUN chmod 0755 /verifier/westbound \
 && mkdir -p /home/verifier \
 && chown 65532:65532 /home/verifier \
 && /verifier/westbound --version
ENV HOME=/home/verifier \
    WB_DB__PATH=/data/westbound.db \
    WB_REPLAYS__WORKER_ENABLED=true \
    WB_REPLAYS__VERIFIER_COMMAND=nice,-n,10,/verifier/westbound,--headless,--main-pack,/verifier/{build}.pck,--script,res://tools/verifier/verify_replay.gd,--,--server=off,--replay={replay},--out={out},--seed={seed},--claimed-score={claimed_score},--claimed-hits={claimed_hits}
USER 65532:65532
VOLUME ["/data"]
ENTRYPOINT ["/usr/local/bin/westbound-server"]
CMD ["verify-worker"]
