#!/usr/bin/env bash
# Runs westbound-server behind Caddy with local TLS (`tls internal`) on
# https://localhost:8443, for the N0 wss:// gate and client testing. Runbook: docs/SERVER.md.
#
#   deploy/local-tls.sh [up|down|status]          Docker: builds westbound-server:local
#                                                 (or uses WB_IMAGE), then
#                                                 `docker compose --profile local-tls up`
#   deploy/local-tls.sh --native [up|down|status] No Docker: the release binary +
#                                                 a caddy binary (CADDY=path, else caddy
#                                                 on PATH, else downloaded to
#                                                 ~/.cache/westbound/caddy, never the repo)
#
# Env: WB_LOCAL_TLS_PORT (8443), WB_IMAGE, CADDY, CADDY_VERSION, DOCKER_BUILD_ARGS.
# Then: curl -k https://localhost:8443/api/v1/health
#       tools/godot.sh --headless --script res://tools/net_echo_check.gd -- --insecure
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ws_root="$(cd "$here/.." && pwd)"
port="${WB_LOCAL_TLS_PORT:-8443}"
# Local runs use dev mode (dev auth secrets; the server refuses to start without secrets otherwise).
export WB_SERVER__ENV="${WB_SERVER__ENV:-dev}"
mode=docker
if [[ "${1:-}" == "--native" ]]; then
	mode=native
	shift
fi
action="${1:-up}"

wait_healthy() {
	local url="https://localhost:$port/api/v1/health"
	for _ in $(seq 1 60); do
		if body="$(curl -fsSk --max-time 2 "$url" 2>/dev/null)"; then
			echo "local-tls: $url -> $body"
			return 0
		fi
		sleep 0.5
	done
	echo "local-tls: $url did not become healthy" >&2
	return 1
}

# ---------------------------------------------------------------- docker mode
docker_mode() {
	cd "$ws_root"
	export WB_LOCAL_TLS_PORT="$port"
	case "$action" in
	up)
		if [[ -z "${WB_IMAGE:-}" ]]; then
			export WB_IMAGE=westbound-server:local
			# shellcheck disable=SC2086
			docker build ${DOCKER_BUILD_ARGS:-} \
				--build-arg "WB_BUILD=$(git -C "$ws_root" rev-parse --short HEAD 2>/dev/null || echo local)" \
				-t "$WB_IMAGE" .
		fi
		# Local runs: allow any CORS origin and a localhost public origin.
		WB_HTTP__CORS_ALLOWED_ORIGINS='*' WB_SERVER__PUBLIC_ORIGIN="https://localhost:$port" \
			docker compose --profile local-tls up -d --no-build
		wait_healthy
		;;
	down) docker compose --profile local-tls down ;;
	status) docker compose --profile local-tls ps ;;
	*) echo "usage: $0 [--native] [up|down|status]" >&2; exit 2 ;;
	esac
}

# ---------------------------------------------------------------- native mode
state_dir="${XDG_RUNTIME_DIR:-/tmp}/westbound-local-tls"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/westbound/caddy"

find_caddy() {
	if [[ -n "${CADDY:-}" ]]; then echo "$CADDY"; return; fi
	if command -v caddy >/dev/null 2>&1; then command -v caddy; return; fi
	local version="${CADDY_VERSION:-2.11.2}" arch
	case "$(uname -m)" in
	x86_64) arch=amd64 ;;
	aarch64 | arm64) arch=arm64 ;;
	*) echo "local-tls: unsupported arch $(uname -m); set CADDY=" >&2; exit 1 ;;
	esac
	local os
	os="$(uname -s | tr '[:upper:]' '[:lower:]')"
	[[ "$os" == darwin ]] && os=mac
	local bin="$cache_dir/$version/caddy"
	if [[ ! -x "$bin" ]]; then
		mkdir -p "$cache_dir/$version"
		local url="https://github.com/caddyserver/caddy/releases/download/v$version/caddy_${version}_${os}_${arch}.tar.gz"
		echo "local-tls: downloading $url" >&2
		curl -fsSL "$url" | tar -xz -C "$cache_dir/$version" caddy
	fi
	echo "$bin"
}

native_mode() {
	mkdir -p "$state_dir"
	case "$action" in
	up)
		(cd "$ws_root" && cargo build --release -p server --bin westbound-server)
		local caddy
		caddy="$(find_caddy)"
		(
			cd "$ws_root"
			WB_HTTP__CORS_ALLOWED_ORIGINS='*' WB_SERVER__PUBLIC_ORIGIN="https://localhost:$port" \
				nohup target/release/westbound-server --config config/dev.toml serve \
				>"$state_dir/server.log" 2>&1 &
			echo $! >"$state_dir/server.pid"
		)
		WB_UPSTREAM=127.0.0.1:8080 WB_TLS_PORT="$port" XDG_DATA_HOME="$state_dir/caddy-data" \
			nohup "$caddy" run --config "$here/Caddyfile" --adapter caddyfile \
			>"$state_dir/caddy.log" 2>&1 &
		echo $! >"$state_dir/caddy.pid"
		echo "local-tls: logs in $state_dir"
		wait_healthy
		;;
	down)
		for p in caddy server; do
			if [[ -f "$state_dir/$p.pid" ]]; then
				kill -TERM "$(cat "$state_dir/$p.pid")" 2>/dev/null || true
				rm -f "$state_dir/$p.pid"
			fi
		done
		;;
	status)
		for p in server caddy; do
			if [[ -f "$state_dir/$p.pid" ]] && kill -0 "$(cat "$state_dir/$p.pid")" 2>/dev/null; then
				echo "$p: running (pid $(cat "$state_dir/$p.pid"))"
			else
				echo "$p: stopped"
			fi
		done
		;;
	*) echo "usage: $0 [--native] [up|down|status]" >&2; exit 2 ;;
	esac
}

"${mode}_mode"
