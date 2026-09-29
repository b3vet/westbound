#!/usr/bin/env bash
# Sharded traffic soak: the spec's 10,000 simulated km (docs/SOAK.md).
#
#   tools/soak.sh [--km=10000] [--shards=4] [--seed=N] [--legs=8] [--leg-km=3.5] [--no-windows] [--all-pieces] [--canyon]
#                 [--out=tests/out/soak] [--compare-with=OTHER/summary.json]
#   tools/soak.sh --update-baseline      # rewrite tests/baselines/traffic_metrics.json (deliberately)
#   tools/soak.sh --merge [--out=DIR]    # re-summarize existing shard files in DIR
#
# Starts one headless Godot per shard (tests/soak/soak_main.gd), each running every
# N-th soak run (rotated). Each run is seeded by its index alone, so any --shards gives the same
# per-run traces (--compare-with checks that against another summary). Prints coarse
# progress every minute, writes DIR/summary.json and exits 1 when a gate counter is
# not zero (or a shard failed).
set -euo pipefail
cd "$(dirname "$0")/.."

km=""; shards=4; seed=""; legs=""; leg_km=""; out="tests/out/soak"; windows=1; all_pieces=0; canyon=0
update_baseline=0; merge_only=0; compare_with=""
for a in "$@"; do
  case "$a" in
    --km=*) km="${a#*=}" ;;
    --shards=*) shards="${a#*=}" ;;
    --seed=*) seed="${a#*=}" ;;
    --legs=*) legs="${a#*=}" ;;
    --leg-km=*) leg_km="${a#*=}" ;;
    --out=*) out="${a#*=}" ;;
    --no-windows) windows=0 ;;
    --all-pieces) all_pieces=1 ;;
    --canyon) canyon=1 ;;
    --update-baseline) update_baseline=1 ;;
    --merge) merge_only=1 ;;
    --compare-with=*) compare_with="${a#*=}" ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "soak.sh: unknown argument $a" >&2; exit 2 ;;
  esac
done

log="$(mktemp)"
if ! tools/godot.sh --headless --path . --import >"$log" 2>&1; then
  cat "$log"; echo "soak.sh: import failed" >&2; exit 1
fi
rm -f "$log"

if [[ $update_baseline -eq 1 ]]; then
  echo "soak.sh: running the metrics reference (16 runs, ~3 min) ..."
  tools/godot.sh --headless --path . --script res://tests/soak/soak_main.gd -- \
    --metrics=all --out=res://tests/baselines/traffic_metrics.json
  echo "soak.sh: wrote tests/baselines/traffic_metrics.json (review the diff before committing)"
  exit 0
fi

mkdir -p "$out"
start=$(date +%s)
if [[ $merge_only -eq 0 ]]; then
  rm -f "$out"/shard_*.json "$out"/shard_*.log "$out"/summary.json
  pids=()
  for ((i = 0; i < shards; i++)); do
    args=(--shard="$i" --shards="$shards" --out="res://$out/shard_$i.json")
    [[ -n "$km" ]] && args+=(--km="$km")
    [[ -n "$seed" ]] && args+=(--seed="$seed")
    [[ -n "$legs" ]] && args+=(--legs="$legs")
    [[ -n "$leg_km" ]] && args+=(--leg-km="$leg_km")
    [[ $windows -eq 0 ]] && args+=(--no-windows)
    [[ $all_pieces -eq 1 ]] && args+=(--all-pieces)
    [[ $canyon -eq 1 ]] && args+=(--canyon)
    tools/godot.sh --headless --path . --script res://tests/soak/soak_main.gd -- "${args[@]}" \
      >"$out/shard_$i.log" 2>&1 &
    pids+=($!)
  done
  echo "soak.sh: $shards shards started (logs: $out/shard_*.log)"
  # Coarse progress: every minute, each shard's latest progress line.
  while :; do
    alive=0
    for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
    [[ $alive -eq 0 ]] && break
    for ((w = 0; w < 60; w++)); do
      alive=0
      for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
      [[ $alive -eq 0 ]] && break
      sleep 1
    done
    [[ $alive -eq 0 ]] && break
    echo "  [$(( $(date +%s) - start )) s]"
    for ((i = 0; i < shards; i++)); do
      grep -E "^  shard " "$out/shard_$i.log" | tail -n 1 || true
    done
  done
  failed=0
  for ((i = 0; i < shards; i++)); do
    if ! wait "${pids[$i]}"; then
      echo "soak.sh: shard $i exited non-zero (see $out/shard_$i.log)" >&2
      tail -n 20 "$out/shard_$i.log" >&2
      failed=1
    fi
  done
fi
wall=$(( $(date +%s) - start ))

python3 - "$out" "$wall" "$compare_with" "${failed:-0}" <<'PY'
import glob, json, math, os, sys

out, wall, compare_with, failed = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
shards = []
for p in sorted(glob.glob(os.path.join(out, "shard_*.json"))):
    with open(p) as f:
        shards.append(json.load(f))
runs = sorted((r for s in shards for r in s["runs"]), key=lambda r: r["run"])
if not runs:
    print("soak.sh: no runs found in %s" % out)
    sys.exit(1)

GATES = ["collision_pairs", "signal_violations", "unsignaled_moves", "ambush_violations", "decel_violations",
         "brake_flag_violations", "rear_end_normal", "impossible_traffic", "offroad_violations", "closed_area_violations"]
COUNTERS = GATES + ["collision_ticks", "collisions_at_pieces", "impossible_windows", "impossible_player_induced", "impossible_checks",
                    "window_checks", "signals", "moves", "cancels", "lane_moves_checked", "player_contact_ticks",
                    "contact_episodes", "rear_end_episodes", "spawned_ahead", "spawned_behind", "despawned",
                    "rejected_cap", "rejected_ghost", "rejected_visible", "rejected_overlap", "sim_signals",
                    "set_pieces", "set_pieces_started", "set_piece_hard_decels", "merges", "set_pieces_passed",
                    "set_pieces_unmet", "set_pieces_ended_zone", "set_pieces_ended_duration", "set_pieces_ended_empty",
                    "peaks_seen", "peaks_no_chance", "peaks_no_kind", "peaks_missed", "peaks_unfit", "peaks_busy",
                    "prop_hits",
                    "sim_moves", "sim_completed", "sim_cancel_player", "sim_cancel_hesitant", "sim_cancel_unsafe",
                    "ticks"]

def summed(rs):
    d = {k: sum(int(r.get(k, 0)) for r in rs) for k in COUNTERS}
    d["runs"] = len(rs)
    d["km"] = round(sum(r["km"] for r in rs), 3)
    d["sim_hours"] = round(sum(r["sim_s"] for r in rs) / 3600.0, 3)
    d["unfinished_runs"] = sum(1 for r in rs if not r["finished"])
    d["peak_active"] = max(r["peak_active"] for r in rs)
    d["min_accel_mps2"] = min(r["min_accel"] for r in rs)
    d["sim_usec_per_tick"] = round(sum(r["sim_usec_per_tick"] * r["ticks"] for r in rs) / max(1, d["ticks"]), 1)
    d["mean_active"] = round(sum(r["mean_active"] * r["ticks"] for r in rs) / max(1, d["ticks"]), 2)
    kinds = {}
    for r in rs:
        for k, v in r.get("set_pieces_by_kind", {}).items():
            kinds[k] = kinds.get(k, 0) + int(v)
    d["set_pieces_by_kind"] = kinds
    d["set_pieces_per_leg"] = round(d["set_pieces"] / max(1, sum(int(r.get("legs", 0)) for r in rs)), 4)
    return d

def metrics(rs):
    m = [r["metrics_raw"] for r in rs]
    vs = sum(x["vehicle_seconds"] for x in m)
    lane_km = sum(x["gap_lane_km"] for x in m)
    legs = sum(x["legs"] for x in m)
    res = {
        "gaps_per_km": sum(x["gap_count"] for x in m) / lane_km if lane_km else 0.0,
        "lane_changes_per_vehicle_min": sum(x["lane_changes"] for x in m) / (vs / 60.0) if vs else 0.0,
        "set_pieces_per_leg": sum(x["set_pieces"] for x in m) / legs if legs else 0.0,
        "density_per_km_lane": sum(x["density_vehicles"] for x in m) / lane_km if lane_km else 0.0,
    }
    n_l = len(m[0]["lane_speed_sum"])
    for l in range(n_l):
        n = sum(x["lane_speed_n"][l] for x in m)
        if n:
            res["mean_speed_kmh_lane_%d" % l] = sum(x["lane_speed_sum"][l] for x in m) / n * 3.6
    return {k: round(v, 4) for k, v in res.items()}

total = summed(runs)
by_lanes = {}
for lanes in sorted(set(r["lanes"] for r in runs)):
    rs = [r for r in runs if r["lanes"] == lanes]
    by_lanes["%d_lanes" % lanes] = dict(summed(rs), metrics=metrics(rs))
cpu = sum(r["wall_s"] for r in runs)
sim_s = sum(r["sim_s"] for r in runs)
summary = {
    "km": total["km"], "runs": total["runs"], "shards": len(shards),
    "wall_s": wall, "shard_wall_s": [s["wall_s"] for s in shards],
    "cpu_s_in_runs": round(cpu, 1), "sim_speedup_per_process": round(sim_s / cpu, 1) if cpu else 0.0,
    "km_per_wall_hour": round(total["km"] / (wall / 3600.0), 1) if wall else 0.0,
    "windows_checked": all(s["windows"] for s in shards),
    "gates": {k: total[k] for k in GATES},
    "gate_passed": all(total[k] == 0 for k in GATES) and total["unfinished_runs"] == 0,
    "totals": total, "by_lanes": by_lanes,
    "engine_errors": [e for s in shards for e in s["engine_errors"]],
    "window_examples": [w for r in runs for w in r["window_examples"]][:24],
    "messages": [m for r in runs for m in r["messages"]][:24],
    "traces": {str(r["run"]): r["trace"] for r in runs},
}
if compare_with:
    with open(compare_with) as f:
        other = json.load(f)["traces"]
    common = sorted(set(other) & set(summary["traces"]), key=int)
    bad = [k for k in common if other[k] != summary["traces"][k]]
    summary["trace_compare"] = {"with": compare_with, "common_runs": len(common), "mismatches": bad}
with open(os.path.join(out, "summary.json"), "w") as f:
    json.dump(summary, f, indent=2, sort_keys=True)

print("")
print("TRAFFIC SOAK  %.1f km in %d runs, %d shards, %.1f simulated hours, wall %d s (%.0f km per wall hour, %.1fx real time per process)" % (
    total["km"], total["runs"], len(shards), total["sim_hours"], wall, summary["km_per_wall_hour"],
    summary["sim_speedup_per_process"]))
for k in GATES:
    print("  %-24s %d" % (k, total[k]))
print("  impossible windows: %d total, %d player-induced (the player's own cut-in), %d traffic; %d / %d checks failed" % (
    total["impossible_windows"], total["impossible_player_induced"], total["impossible_traffic"],
    total["impossible_checks"], total["window_checks"]))
print("  contacts with the player: %d episodes (%d rear-end, %d of a normally driving player)" % (
    total["contact_episodes"], total["rear_end_episodes"], total["rear_end_normal"]))
print("  lane moves checked %d, signals %d, cancels %d, peak active %d, min accel %.2f m/s^2" % (
    total["lane_moves_checked"], total["signals"], total["cancels"], total["peak_active"], total["min_accel_mps2"]))
print("  set pieces: %d spawned, %d started, %d passed, %d unmet, %d ended at a road zone, %d timed out, %d emptied; "
      "hard decels %d; peaks %d (no chance %d, no kind %d, missed %d, unfit %d); merges %d" % (
    total["set_pieces"], total["set_pieces_started"], total["set_pieces_passed"], total["set_pieces_unmet"],
    total["set_pieces_ended_zone"], total["set_pieces_ended_duration"], total["set_pieces_ended_empty"],
    total["set_piece_hard_decels"], total["peaks_seen"], total["peaks_no_chance"], total["peaks_no_kind"],
    total["peaks_missed"], total["peaks_unfit"], total["merges"]))
print("  set pieces per leg %.3f, by kind: %s; prop hits (the bot) %d; collision pairs at a live piece %d" % (
    total["set_pieces_per_leg"], json.dumps(total["set_pieces_by_kind"], sort_keys=True), total["prop_hits"],
    total["collisions_at_pieces"]))
for name, g in by_lanes.items():
    print("  %s: %.0f km, impossible (traffic) %d, collisions %d, violations %d | %s" % (
        name, g["km"], g["impossible_traffic"], g["collision_pairs"],
        sum(g[k] for k in GATES if k not in ("collision_pairs", "impossible_traffic")), json.dumps(g["metrics"])))
if summary["engine_errors"]:
    print("  ENGINE ERRORS: %s" % summary["engine_errors"][:5])
if "trace_compare" in summary:
    tc = summary["trace_compare"]
    print("  traces vs %s: %d common runs, %d mismatches" % (tc["with"], tc["common_runs"], len(tc["mismatches"])))
print("  summary: %s" % os.path.join(out, "summary.json"))
ok = summary["gate_passed"] and not summary["engine_errors"] and not failed
if "trace_compare" in summary and summary["trace_compare"]["mismatches"]:
    ok = False
print("GATE %s" % ("PASSED" if ok else "FAILED"))
sys.exit(0 if ok else 1)
PY
