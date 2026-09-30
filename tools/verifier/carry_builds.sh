#!/usr/bin/env bash
# Assemble the verifier image's build context (WP N8.3; docs/DETERMINISM.md → Verifier
# deploy): build/verifier/ holds the build tools/verifier/export_verifier.sh just exported
# (<client_build>/westbound + westbound.pck + build_info.cfg); this adds the verifiers of
# older client builds from the previously published image, so players still on an older
# build (a cached web page, a native app not yet updated) keep being verified. The newest
# --keep build numbers stay (the fresh one always). A build number the fresh export has
# replaces the old one.
#
#   tools/verifier/carry_builds.sh --from-image=ghcr.io/b3vet/westbound-verifier:edge \
#       [--keep=3] [--context=build/verifier] [--sample=DIR]
#
# No previous image (the first run, or a pull that fails): only the fresh build. Writes
# <context>/BUILDS.txt (one line per build: number, commit, export date).
#
# --sample=DIR (sample.wbr + claims.json from export_verifier.sh --keep-sample): when the
# previous image has a verifier for the SAME build number, it must still accept a replay
# of this commit; otherwise the simulation changed without a client_build bump, and
# replays from clients still on the previous deploy will fail against the new verifier
# (path_mismatch: rejected; tuning_mismatch: set aside). That is a warning (a GitHub
# Actions annotation in CI), not a failure: the new verifier matches the new clients.
set -euo pipefail
cd "$(dirname "$0")/../.."

from=""
keep=3
ctx="build/verifier"
sample=""
for a in "$@"; do
  case "$a" in
    --from-image=*) from="${a#--from-image=}" ;;
    --keep=*) keep="${a#--keep=}" ;;
    --context=*) ctx="${a#--context=}" ;;
    --sample=*) sample="${a#--sample=}" ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "carry_builds.sh: unknown argument $a" >&2; exit 2 ;;
  esac
done
[[ -n "$from" ]] || { echo "carry_builds.sh: --from-image=<ref> is required" >&2; exit 2; }
[[ "$keep" =~ ^[1-9][0-9]*$ ]] || { echo "carry_builds.sh: --keep must be a positive number" >&2; exit 2; }

builds_in() { # dir -> the build numbers it holds (directories with a westbound binary)
  local d
  for d in "$1"/*/; do
    d="${d%/}"; d="${d##*/}"
    [[ "$d" =~ ^[0-9]+$ && -x "$1/$d/westbound" && -f "$1/$d/westbound.pck" ]] && echo "$d"
  done
  return 0
}

warn() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then echo "::warning title=Verifier build parity::$*"; fi
  echo "carry_builds.sh: WARNING: $*" >&2
}

mapfile -t fresh < <(builds_in "$ctx")
[[ ${#fresh[@]} -gt 0 ]] || { echo "carry_builds.sh: no exported build in $ctx (run tools/verifier/export_verifier.sh)" >&2; exit 1; }

prev="$(mktemp -d)"
trap 'rm -rf "$prev"' EXIT
if docker pull -q "$from" >/dev/null 2>&1 || docker image inspect "$from" >/dev/null 2>&1; then
  cid="$(docker create "$from")"
  docker cp "$cid:/verifier/." "$prev/" >/dev/null
  docker rm -v "$cid" >/dev/null
  mapfile -t old < <(builds_in "$prev")
  echo "carry_builds.sh: $from has build(s): ${old[*]:-none}" >&2
else
  old=()
  echo "carry_builds.sh: no previous image $from (first publish?): only the fresh build" >&2
fi

# The fresh builds, then the older ones newest first, up to --keep.
mapfile -t kept < <(
  printf '%s\n' "${fresh[@]}"
  for b in "${old[@]}"; do
    [[ " ${fresh[*]} " == *" $b "* ]] || echo "$b"
  done | sort -rn
)
kept=("${kept[@]:0:$keep}")
for b in "${kept[@]}"; do
  if [[ " ${fresh[*]} " != *" $b "* ]]; then
    cp -a "$prev/$b" "$ctx/$b"
    echo "carry_builds.sh: carried build $b over from $from" >&2
  fi
done
for b in "${old[@]}"; do
  [[ " ${kept[*]} " == *" $b "* ]] || echo "carry_builds.sh: dropped build $b (older than the newest $keep)" >&2
done

# Build parity across deploys of the same build number.
if [[ -n "$sample" && -f "$sample/sample.wbr" && -f "$sample/claims.json" ]]; then
  seed="$(sed -n 's/.*"seed": *"\{0,1\}\([0-9]*\).*/\1/p' "$sample/claims.json")"
  score="$(sed -n 's/.*"score": *\([0-9]*\).*/\1/p' "$sample/claims.json")"
  hits="$(sed -n 's/.*"hits": *\([0-9]*\).*/\1/p' "$sample/claims.json")"
  for b in "${fresh[@]}"; do
    [[ -x "$prev/$b/westbound" ]] || continue
    work="$(mktemp -d)"
    set +e
    HOME="$work" nice -n 10 "$prev/$b/westbound" --headless -- --verifier=1 --server=off \
      --replay="$(realpath "$sample/sample.wbr")" --out="$work/result.json" --seed="$seed" \
      --claimed-score="$score" --claimed-hits="$hits" --require-inputs=1 >"$work/log" 2>&1
    status=$?
    set -e
    line="$(grep -h '^verify_replay:' "$work/log" || tail -n 3 "$work/log")"
    rm -rf "$work"
    if [[ $status -eq 0 ]]; then
      echo "carry_builds.sh: the previous build $b verifier accepts this commit's replay (same simulation)" >&2
    else
      prev_commit="$(sed -n 's/^commit="\(.*\)"$/\1/p' "$prev/$b/build_info.cfg" 2>/dev/null || true)"
      warn "client_build $b changed its simulation since ${prev_commit:-the previous image} without a bump (the previous verifier says: ${line}). Replays from clients still on the previous deploy will now fail verification. Bump client_build in data/tuning/net.tres with simulation changes."
    fi
  done
fi

{
  for b in $(printf '%s\n' "${kept[@]}" | sort -rn); do
    commit="$(sed -n 's/^commit="\(.*\)"$/\1/p' "$ctx/$b/build_info.cfg" 2>/dev/null || true)"
    date="$(sed -n 's/^date="\(.*\)"$/\1/p' "$ctx/$b/build_info.cfg" 2>/dev/null || true)"
    echo "$b ${commit:-unknown} ${date:-unknown}"
  done
} >"$ctx/BUILDS.txt"
echo "carry_builds.sh: the image will verify builds (build commit date):" >&2
sed 's/^/  /' "$ctx/BUILDS.txt" >&2
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Verifier builds in the image"
    echo
    echo "| client_build | commit | exported |"
    echo "| --- | --- | --- |"
    while read -r b c d; do echo "| $b | $c | $d |"; done <"$ctx/BUILDS.txt"
  } >>"$GITHUB_STEP_SUMMARY"
fi
