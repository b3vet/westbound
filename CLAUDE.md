# Westbound

Mobile-first landscape endless highway game: drive west chasing a setting sun, cut through traffic.
Godot 4.7, GDScript only. iOS and Android first, web second.

- **Spec (source of truth):** [`WESTBOUND HANDOFF.md`](WESTBOUND%20HANDOFF.md). Read the sections for your task before coding.
- **Plan (order, work packages, gates):** [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md)
- **Contracts (coordinates, interfaces):** [`docs/CONTRACTS.md`](docs/CONTRACTS.md). Frozen after Phase 0; changes need an orchestrator decision.

## Commands

```
tools/test.sh                       # import + fast test tier (what CI runs)
tools/test.sh --tier=soak           # long soaks, before gates
tools/test.sh --filter=traffic      # substring of test path or method
tools/godot.sh <args>               # the pinned Godot 4.7 binary (downloads on first use; GODOT=... overrides)
tools/lint [--strict]               # budget + working-rule linter (rule table in docs/TOOLS.md)
tools/check_warnings.sh             # every enabled GDScript warning as an error (headless runs never print warnings)
tools/snap.sh <scene.tscn> [--renderer=compat|mobile|both] [--sweep=sky_t:0,0.5] [--key=value]   # screenshots to tests/out/snaps/
```

## Working rules (from the spec, non-negotiable)

1. **Test first.** Write the headless tests with each system, not after it. The spec lists the tests per system.
2. **Data over code.** Every gameplay number lives in tuning data (`data/tuning.tres` → per-system `data/tuning/*.tres`). No magic numbers in code. Structural literals (0, 1, 0.5, 2, array indices) are fine; anything a designer might tune is not.
3. **Rendering budget.** Never add `OmniLight3D`/`SpotLight3D`, shadow maps, `StandardMaterial3D`/PBR in gameplay, or post effects beyond the single color grade. One `DirectionalLight3D` with shadows off. Custom unlit or single-light vertex-lit shaders only. Every shader must look the same on the Mobile and Compatibility renderers.
4. **Pure simulation.** `vehicle_physics`, `traffic_sim` (+ idm, mobil), `scoring`, `sun_clock`, `passability`, `road_path` extend `RefCounted`, have no Node/scene/autoload dependencies, take state + inputs + params and return new state. They run headless. Events they produce are written to a caller-provided buffer; a thin Node adapter publishes them on the `Events` bus.
5. **Deterministic by seed.** All randomness comes from `Rng` streams derived from the run seed (`Rng.derive(...)`). Never use global `randf()`/`randi()`/`randomize()`, `randfn()`, `Time` or frame timing in simulation. Same seed + same inputs = same run.
6. **No allocations in sim ticks.** Per-tick code creates no `Array`, `Dictionary`, `String`, object or `Packed*Array`. Use pre-sized structure-of-arrays storage (`PackedFloat64Array` etc.) allocated at init, and pools for nodes.
7. **Road space first.** Traffic, player, scoring and collisions work in (`s`, `d`) road coordinates. World transforms are derived for rendering only.
8. **Event bus.** Gameplay emits on `Events` (`src/core/events.gd`); HUD, audio, haptics, camera and particles only listen, never drive gameplay.
9. **Flag, don't diverge.** If the spec must change, stop and flag it (the plan's §2 deviations table) instead of silently diverging.
10. **Keep the review tools alive.** The traffic sandbox and dev HUD must keep working at every milestone.

## GDScript conventions

- Static typing everywhere (`var x: float`, `-> void`, typed arrays). Untyped declarations warn.
- Tabs for indentation, `snake_case.gd` files, `PascalCase` `class_name`. Don't shadow Godot globals (`seed`, `randf`, `name` on Nodes, ...).
- Units: meters, seconds, radians, m/s internally. km/h and degrees only at the tuning/UI boundary, converted once when params load.
- Sim math in `float` (64-bit in GDScript). Avoid `Vector3` (32-bit) in simulation state; use it for rendering.
- A short `##` doc comment at the top of each script names the spec section it implements.

## Tests

- `tests/**/test_<system>.gd`, extending `WBTest` (`tests/lib/wb_test.gd`). Auto-discovered, no registry.
- `test_*` methods = fast tier (keep each under 5 s). `soak_*` methods = soak tier.
- Assertions: `check`, `eq`, `ne`, `near`, `within_pct`, `lt/le/gt/ge`, `finite`, `fail`.
- Seeded systems get a determinism test (hash of the state trace).
- Nodes created in tests go under `tree.root` and are freed in `after_each()`.

## Multi-agent workflow

- Each work package (WP) owns a list of paths; only modify those. Orchestrator-owned shared files: `project.godot`, `src/core/events.gd`, root `data/tuning.tres`, `export_presets.cfg`, `.github/workflows/ci.yml`, `CLAUDE.md`, `docs/IMPLEMENTATION_PLAN.md`. Need a change there? Put it in your handoff note (e.g. "needs: signal X", "needs: autoload Y").
- **Merge gate:** full fast tier green, `tools/lint` and `tools/check_warnings.sh` clean, no allocations in sim ticks, determinism test for seeded systems, `tools/snap.sh` screenshots for visual work.
- **Handoff note** (end of every WP): what was built, files, tests added, deviations or open questions, and requested shared-file changes.
- Third-party assets must be CC0 (or OFL for fonts) and logged in `assets/LICENSES.md` with source URL and license.
