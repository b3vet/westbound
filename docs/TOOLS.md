# Review tools

The tools the orchestrator and every WP run at merge time (plan §3, §4 merge gate, §6 test tiers).

| Tool | What it answers | Gate |
| --- | --- | --- |
| `tools/test.sh` | Do the headless tests pass? (see `CLAUDE.md`) | every WP |
| `tools/lint` | Does the code respect the rendering budget and the sim working rules? | every WP |
| `tools/parity.sh` | Do the Mobile and Compatibility renderers produce the same pixels for this scene? | visual WPs touching shaders, every gate |
| `tools/snap.sh` | What does the scene look like on the Compatibility renderer, and on the Mobile renderer (`--renderer=mobile|both`, Mesa lavapipe)? | visual WPs, every gate |
| `WBBench` (`tests/lib/bench.gd`) | Does a sim tick fit its CPU budget? | sim WPs (WP2.4 onward) |
| `tools/drawcalls.sh` | How many draw calls, objects and primitives does a scene cost, split into 3D, each overlay and each top-level 3D node? | rendering WPs, perf gates (WP4.6) |

## tools/snap.sh — screenshots

```
tools/snap.sh src/main.tscn                                  # -> tests/out/snaps/main.png
tools/snap.sh src/main.tscn --renderer=both                  # + main_mobile.png (needs: apt-get install -y mesa-vulkan-drivers)
tools/snap.sh src/sun/sky_preview.tscn --sweep=sky_t:0,0.17,0.33,0.5,0.67,0.83,1
tools/snap.sh src/run.tscn --cam=hood --speed_kmh=200 --seconds=2 --tag=hood
tools/snap.sh src/road/road_preview.tscn --size=2400x1080 --out=/tmp/snaps
```

Renders with the **Compatibility** renderer (`gl_compatibility` / `opengl3`), under `xvfb-run` when there is no `$DISPLAY` (Mesa llvmpipe in the container), with the dummy audio driver and `--fixed-fps 60`, so simulated time is exact whatever the machine speed. `--renderer=mobile|both` also captures the **Mobile** renderer (Vulkan on Mesa lavapipe; install with `apt-get install -y mesa-vulkan-drivers`). Mobile images get a `mobile` tag. It prints the path of each PNG (relative to the repo when inside it), one per line.

| Option | Default | Meaning |
| --- | --- | --- |
| `--size=WxH` | `1280x720` | window and image size |
| `--frames=N` | `30` | frames to wait after `snap_setup` before capturing |
| `--seconds=S` | `0` | extra simulated time to wait (`S × 60` frames) |
| `--sweep=key:v1,v2,…` | none | one capture per value; repeat for a grid (cartesian product) |
| `--tag=NAME` | none | extra filename part, to keep variants apart |
| `--out=DIR` | `tests/out/snaps/` (gitignored) | output directory |
| `--key=value` | | any other pair goes to the scene's `snap_setup` |

**Files:** `<scene>[_<tag>][_<key>-<value>…].png`, e.g. `sky_preview_sky_t-0.5.png`. Characters other than `A-Za-z0-9._-` become `_`.

**Scene hook.** If the scene root has `func snap_setup(args: Dictionary) -> void`, it is called once per capture, after `_ready` and before the frame wait, with every non-reserved option plus the sweep values. Values arrive coerced: `true`/`false` → bool, integer text → int, other numbers → float, anything else → String, and a bare `--flag` is `true`. So convert defensively (`float(args.get("sky_t", 0.0))`). `snap_setup` may `await`. Each capture gets a fresh instance of the scene. A scene without the hook is captured as is, and any options are reported as ignored. See `tools/snap/example_snap_scene.tscn`:

```gdscript
func snap_setup(args: Dictionary) -> void:
	color_script.sky_t = float(args.get("sky_t", color_script.sky_t))
	camera_rig.mode = StringName(args.get("cam", "chase"))
```

**Exit status:** 0 on success, 1 when the scene fails to load or instance, or the capture or write fails, 2 for bad arguments. Godot `ERROR`/`WARNING`/`SCRIPT ERROR` lines are always echoed to stderr, and the full Godot log is printed on failure. A script error inside the scene does not fail the snap, so read stderr. The Xvfb "Could not set V-Sync mode" warning is filtered out as noise.

**Review convention:** visual WPs attach snaps across the seven color-script keyframes (`--sweep=sky_t:…`) and read them before handing off. Agents look at the PNGs with their image-reading tool.

## tools/drawcalls.sh — draw-call measurement

```
tools/drawcalls.sh src/dev/car_drive.tscn --cam=hood --set=_leg:8 --s=3000     # traffic-heavy leg 8
tools/drawcalls.sh src/dev/car_drive.tscn --cam=chase --sky_t=0.7 --no-breakdown
tools/drawcalls.sh src/vehicle/dev/car_preview.tscn --cam=chase3q --renderer=mobile
```

Renders the scene like `tools/snap.sh`: Compatibility renderer (the web build's) under `xvfb-run` on Mesa llvmpipe, `--fixed-fps 60`, dummy audio. The default size is 1361x720, the owner's iPhone canvas. It then:

1. Calls the scene's `snap_setup(args)` with the unreserved `--key=value` pairs, and waits `--frames` frames.
2. Samples the monitors for `--sample` frames while the scene runs.
3. Pauses the tree and measures the frozen frame. From here on every number is exact and repeats run to run:
    - the total
    - each visible CanvasLayer's share
    - the 3D-only count, with every CanvasLayer hidden
    - each top-level 3D child's share (the child is hidden in turn; the camera's branch is skipped)

Each row prints three numbers:

- *draws*: `Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME`, which counts 3D and canvas.
- *3d*: the root viewport's own draws (`get_render_info`). This is the gameplay cost; the Dev HUD shows it as `3d N`.
- *objects* and *prims*.

It also prints the scene's DevStats counts (vehicles, opposite, leg, camera, sky_t) when they are reported. Before/after numbers live in `docs/PERF.md`.

| Option | Default | Meaning |
| --- | --- | --- |
| `--renderer=compat\|mobile` | `compat` | Mobile uses Vulkan on Mesa lavapipe (draw counting differs slightly between renderers) |
| `--size=WxH` | `1361x720` | window size |
| `--frames=N` | `180` | warm-up frames after `snap_setup` |
| `--sample=N` | `60` | frames averaged for the moving sample |
| `--set=prop:value` | none | set a property on the scene root before `snap_setup` (repeatable), e.g. `--set=_leg:8` in `car_drive` |
| `--no-breakdown` | off | only the totals |
| `--key=value` | | goes to the scene's `snap_setup` (e.g. `--cam=hood --s=3000 --sky_t=0.7`) |

**Output:** one line per measurement on stdout. Godot errors and warnings go to stderr, minus the exit-time leak noise. **Exit status:** 0 on success, 1 when the scene fails to load or nothing was measured, 2 for bad arguments.

## tools/lint — budget and working-rule linter

```
tools/lint                  # whole repo; exit 1 on any error
tools/lint src/traffic      # only these files or dirs
tools/lint --strict         # warnings fail too
tools/lint --self-test      # rules against the seeded fixtures; run after changing a rule
tools/lint --rules          # list rule ids
```

Output is `path:line: RULE message`; warnings print as `RULE (warning)`. A summary line goes to stderr. The linter needs Python 3.9+ and nothing else. It lints `.gd`, `.tscn` and `.tres` files and skips `.git`, `.godot`, `.claude`, `build`, `tests/out` and any directory containing a `.gdignore`. Rule scopes use repo-relative paths.

### Rules

| Id | Sev | Scope | Rule | Escape |
| --- | --- | --- | --- | --- |
| WB001 | error | render | `OmniLight3D`/`SpotLight3D` (in a scene, resource, or code) | none |
| WB002 | error | render | `StandardMaterial3D`/`ORMMaterial3D` | file under a `debug/` or `dev/` directory (editor/debug-only content, never shipped in gameplay scenes) |
| WB003 | error | render | `shadow_enabled = true` (`.tscn`/`.tres` property or `.gd` assignment) | none |
| WB004 | error | render | `glow`, `ssao`, `ssr`, `ssil`, `sdfgi`, `volumetric_fog`, `dof_blur_far/near`, `auto_exposure` `_enabled = true` (or `set_…_enabled(true)`) | none. The single color grade (`adjustment_enabled`) is allowed |
| WB100 | error | `.gd` | malformed `# lint:` directive: an unknown name, or an escape without a reason | fix it |
| WB101 | error | sim | numeric literal outside the allow-list | `# lint: allow-number <reason>` on the line |
| WB102 | error | sim | nondeterminism: global `randf/randi/randf_range/randi_range/randomize/randfn/seed/rand_from_seed(`, `RandomNumberGenerator`, `hash()`/`.hash()`, `Time.`, `OS.get_ticks*/unix_time*/system_time*`, `Engine.get_*frames*`, `get_(physics_)process_delta_time()` | none: sims take an `Rng` stream and `dt` |
| WB103 | error | sim | impurity: `extends` a Node-family class (`Node`, `Control`, `*2D`, `*3D`, `SceneTree`, `Timer`, …), `get_tree/get_node/get_node_or_null/get_parent/add_child/remove_child/find_child/get_viewport/get_window(`, `$Node`, `Input`, `Engine.get_main_loop/get_singleton`, autoload access (names read from `project.godot`) | none: use a Node adapter file |
| WB104 | warning | sim tick functions | allocation: `[…]` array literal, `{…}`, `.new(`, `Array/Dictionary/String/StringName/NodePath/Packed*Array(`, `str(`, `"…" %`, `.duplicate/slice/keys/values/split/join/format/map/filter(`, lambdas, `.bind(` | `# lint: allow-alloc <reason>` on the line |
| WB105 | error | sim, plus `LIBM_GLOBS` | the platform math library: `sin/cos/tan/asin/acos/atan/atan2/exp/log/pow/sinh/cosh/tanh/asinh/acosh/atanh/ease/lerp_angle/angle_difference/rotate_toward(` and `.angle/angle_to/angle_to_point/rotated/slerp/from_angle/from_euler/get_euler(`: they round differently per platform (N8.2, docs/DETERMINISM.md). `DetMath.sin(...)` etc. are fine | `# lint: allow-libm <reason>` on the line (rendering-only values that never feed back) |
| WB201 | warning | `src/**.gd` | named `func` without `-> Type` | none |

**Scopes.**

- *render*: `.gd`, `.tscn` and `.tres` under `src/`, `assets/` and `data/`. In `.gd` files, comments and strings are ignored. In scenes, `;` comment lines are skipped.
- *sim*: `src/road/road_path*.gd`, `src/vehicle/vehicle_physics.gd`, `src/traffic/*.gd` (recursive), `src/scoring/*.gd` and `src/sun/sun_clock.gd`, plus any `.gd` file with a `# lint: sim` line.
  - A file in those paths that is really a Node adapter (e.g. `src/traffic/traffic_view.gd`) opts out with `# lint: not-sim <reason>`. The reviewer checks the reason.
  - Comments and string contents are ignored.
- *sim tick functions*: named `step*`, `tick*`, `_physics_process`, `_process` or `*_into` in sim files. The function body is found by indentation, and default arguments count.
- *WB105* (N8.2) covers the sim scope except `src/net/` (network client code follows the server's authority and is never replayed bit for bit), plus these simulation-side files outside it: `src/vehicle/vehicle_params.gd`, `src/vehicle/vehicle_state.gd`, `src/run/run.gd`, `src/run/run_finale.gd`, `src/run/run_forks.gd`, `src/meta/daily/daily_script_driver.gd`, `src/traffic/dev/sandbox_bot.gd` and `tools/verifier/*.gd` (`LIBM_GLOBS` in `tools/lint_rules/__init__.py`), whatever their `not-sim` marker.

**Magic-number allow-list (WB101).**

- **Allowed anywhere:** `0`, `1`, `2`, `0.5` in any spelling (`1.0`, `-1`, `0.50`). These are identities, negation, doubling and halving. Everything else, including `0.25`, `3`, `10`, `100`, `1000` and epsilons like `1e-6`, is a tuning value or needs a stated reason. An epsilon belongs in tuning or a documented `const` with `allow-number`.
- **Integer literals are allowed in structural positions:**
  - `const` declarations, e.g. capacities, bit flags, hash constants (`const CAPACITY := 60`, `const FLAG_BRAKING := 1 << 3`)
  - `enum` bodies
  - subscripts (`_s[3]`)
  - bit-operator operands (`x >> 16`, `h & 0xFFFF`, `1 << 3`)
- **Float literals in a `const` are errors:** a float constant is almost always physical (`const GRAVITY := 9.81`), so it belongs in tuning data, or it carries `# lint: allow-number <reason>` (e.g. a true physical constant or a unit conversion).

**Escapes** always need a reason in words (`# lint: allow-number physical constant`), and apply to their own line only. The directive must start that line's comment. Any text after a further `#` is not part of the reason.

**Self-test.** `tools/lint_rules/fixtures/` is a mini repo of seeded violations. Each line that must trigger carries `expect: WBxxx[, WByyy]`, and every other line must stay clean. `--self-test` fails on any missed or extra finding, on any rule without a fixture, and if there is no clean fixture. The directory has a `.gdignore`, so Godot never imports the deliberately broken files and `tools/lint` skips them on the real repo. When you add or change a rule, add fixture lines first.

**Known blind spots** (the review catches these):

- `%UniqueNode` access
- materials inside imported `.glb` files
- `ClassDB.instantiate("OmniLight3D")`
- allocations hidden inside called helpers
- `.append()` growth

## WBBench — tick-cost budgets

`tests/lib/bench.gd` (`class_name WBBench`), used from ordinary `WBTest` suites:

```gdscript
func test_traffic_tick_budget() -> void:
	var sim := _make_sim(60)                         # warmed-up, 60 vehicles
	var usec := WBBench.usec_per_call(sim.step.bind(1.0 / 120.0), 200)
	WBBench.report("traffic step, 60 vehicles", usec, 400.0)
	le(usec, WBBench.budget(400.0), "traffic step usec")
```

- `usec_per_call(fn, iterations, warmup = one batch, batches = 7) -> float`: the median over `batches` timed batches of the mean µs per call, after untimed warmup calls. The median shrugs off one GC pause or scheduler hiccup.
- `measure(...) -> {median, min, max, batches}` for when you want the spread.
- `call_overhead_usec()`: the cost of an empty `Callable.call` (sub-microsecond). If a measurement is near this, loop inside the callable instead.
- `budget(usec)`: the budget scaled by the `WB_BENCH_SCALE` env var (default 1.0). Set it (e.g. `2`) on a slow CI runner rather than editing budgets.
- `report(label, usec, budget)`: prints one `bench …` line into the test log, so the numbers are visible in every run.

**Budget guidance for noisy CI:**

- Benchmark one whole tick per call, never a single tiny op.
- Warm up (fill pools, settle the state) before measuring.
- Set the budget at about 3× the median you measure locally. It must still sit well inside the real frame share (e.g. traffic at 120 Hz has an 8.3 ms tick and shares it). A budget test catches order-of-magnitude regressions, not 10% drift.
- Keep each fast-tier bench under about 0.5 s. Longer or more precise runs go in `soak_*` methods.
- Allocation freedom is not measured here. That is WB104 plus review.

## tools/check_warnings.sh — GDScript warnings as errors

Headless Godot never prints GDScript warnings, so a clean `tools/test.sh` run doesn't mean the code has none. This script temporarily writes an `override.cfg` that raises every warning the project enables (level 1 in `project.godot`) to an error. Warnings the project disables stay off. It then loads every `.gd` file under `src/`, `tests/` and `tools/`, skipping fixtures and `out/`.

```
tools/check_warnings.sh        # exit 1 and list offending scripts with the warning text
```

It runs in CI before the tests. To silence one warning, use `@warning_ignore("name")` with a short reason.
