# syntax=docker/dockerfile:1.7
# westbound-server image: a static musl binary on distroless/static (CA certs,
# non-root user, no shell). docs/MULTIPLAYER_PLAN.md MP-D1; runbook: docs/SERVER.md.
#
#   docker build -t westbound-server westbound-server
#   docker build --build-arg WB_BUILD=$(git rev-parse --short HEAD) -t westbound-server westbound-server
#
# Build context: the westbound-server/ workspace. Dependencies are cooked in their
# own layer (cargo-chef), so a source-only change rebuilds just the workspace crates.

ARG CHEF_IMAGE=lukemathwalker/cargo-chef:latest-rust-1.94-alpine
ARG RUNTIME_IMAGE=gcr.io/distroless/static-debian12:nonroot

FROM ${CHEF_IMAGE} AS chef
WORKDIR /src
# Same profile for the cooked dependencies and the final build.
ENV CARGO_PROFILE_RELEASE_STRIP=symbols \
    CARGO_TERM_COLOR=never \
    SQLX_OFFLINE=true

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
COPY --from=planner /src/recipe.json recipe.json
# Optional `extra_ca` secret: a CA bundle for builds behind a TLS-intercepting
# proxy (`--secret id=extra_ca,src=/path/ca.crt`). CI does not need it.
RUN --mount=type=secret,id=extra_ca,required=false \
    if [ -s /run/secrets/extra_ca ]; then export CARGO_HTTP_CAINFO=/run/secrets/extra_ca; fi \
 && cargo chef cook --release --locked --recipe-path recipe.json -p server
COPY . .
# Baked into the binary: /api/v1/health reports it as "build".
ARG WB_BUILD=dev
ENV WB_BUILD=${WB_BUILD}
RUN --mount=type=secret,id=extra_ca,required=false \
    if [ -s /run/secrets/extra_ca ]; then export CARGO_HTTP_CAINFO=/run/secrets/extra_ca; fi \
 && cargo build --release --locked -p server --bin westbound-server \
 && mkdir -p /out/data/backups /out/data/well-known \
 && cp target/release/westbound-server /out/westbound-server

FROM ${RUNTIME_IMAGE}
LABEL org.opencontainers.image.title="westbound-server" \
      org.opencontainers.image.description="Westbound Online server: HTTP API, WebSocket gateway, SQLite" \
      org.opencontainers.image.source="https://github.com/b3vet/westbound"
COPY --from=builder /out/westbound-server /usr/local/bin/westbound-server
# Owned by the distroless nonroot user (65532) so a fresh named volume inherits it.
COPY --from=builder --chown=65532:65532 /out/data /data
# The runtime image has no libc or shell: this only runs if the binary is static.
RUN ["/usr/local/bin/westbound-server", "--version"]
# N10.2: JSON logs by default in the image (structured, one object per line, with the
# request id in HTTP spans); WB_LOG__FORMAT=text for a local terminal.
ENV WB_SERVER__BIND=0.0.0.0:8080 \
    WB_DB__PATH=/data/westbound.db \
    WB_BACKUP__DIR=/data/backups \
    WB_DEEPLINKS__DIR=/data/well-known \
    WB_LOG__FORMAT=json
USER 65532:65532
VOLUME ["/data"]
EXPOSE 8080
# No curl in the image: the binary probes its own /api/v1/health.
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD ["/usr/local/bin/westbound-server", "healthcheck"]
# SIGTERM starts the planned restart: a 60 s notice to players (WB_SERVER__RESTART_NOTICE_SECS),
# the room handover, close 1012. Give the container a stop timeout above it (compose
# stop_grace_period: 75s; docs/OPERATIONS.md → Restarts).
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/westbound-server"]
CMD ["serve"]
