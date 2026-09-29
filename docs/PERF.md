# Performance measurements

Spec: Performance budget (100 draw calls or fewer in gameplay, 150k triangles, render scale per tier). Plan: WP4.6.

The phone numbers come from the owner's COPY reports (Dev HUD). The container numbers come from `tools/drawcalls.sh` (see `docs/TOOLS.md`). The container uses the same Compatibility renderer as the web build, on Mesa llvmpipe under Xvfb. Draw calls and triangles do not depend on the GPU, so they carry over. Frame times do not: only device numbers count for fps and thermal (D4).

## Draw calls: WP4.6 before and after

**Setup.** `src/dev/car_drive.tscn`, seed 20260928, 1361x720 (the owner's iPhone canvas), render scale 0.75. The "leg 8" rows are the densest leg, at s = 3000 m with 47 vehicles and 19 on the opposite carriageway. The rows come from the frozen frame (tree paused after a 3 s warm-up), so they are exact and repeat run to run.

**Columns.**

- *3D* is the root viewport's own draw count, which is what gameplay pays.
- *canvas* is every CanvasLayer in the scene: here the dev overlays only (Dev HUD 4, sky_t slider 8, dev buttons 8). The touch-controls overlay draws nothing on a desktop, so it adds 0.
- *total* is what the Dev HUD's `draws` row shows.

```
tools/drawcalls.sh src/dev/car_drive.tscn --cam=hood  --set=_leg:8 --s=3000
tools/drawcalls.sh src/dev/car_drive.tscn --cam=chase --set=_leg:8 --s=3000
tools/drawcalls.sh src/dev/car_drive.tscn --cam=hood  --set=_leg:8 --s=3000 --sky_t=0.7
tools/drawcalls.sh src/dev/car_drive.tscn --cam=hood
```

| Scenario | Before: total / 3D | After: total / 3D | 3D saved |
| --- | --- | --- | --- |
| hood cam, leg 8, day | 77 / 57 | 68 / 48 | −9 |
| chase cam, leg 8, day | 83 / 63 | 68 / 48 | −15 |
| hood cam, leg 8, night (sky_t 0.7) | 78 / 58 | 69 / 49 | −9 |
| hood cam, leg 3, s = 0 (34 vehicles) | 73 / 53 | 64 / 44 | −9 |

The canvas share is 20 in every row, before and after. The Dev HUD's new quality row adds no draw calls, because its buttons are flat and batch with the readouts.

**3D breakdown, chase cam, leg 8** (each top-level node hidden in turn):

| Node | Before | After | What changed |
| --- | --- | --- | --- |
| PlayerCar | 16 | 6 | Body 3 (paint, trim, glass) + merged lamps 1 + wheels 1 (one MultiMesh) + blob shadow 1. Braking adds 1 (the merged brake lights), where it used to add 2 |
| RoadBuilder | 10 | 5 | one surface per chunk (road + markings + reflectors + barrier + rails + ground) |
| Roadside | 18 | 18 | not in WP4.6 (see below) |
| TrafficView | 16 | 16 | not in WP4.6: one MultiMesh per model on screen, plus glow and shadows |
| Sky | 3 (4 at night) | 3 (4 at night) | dome, horizon and clouds (+ stars) |
| **3D total** | **63** | **48** | |

**Headroom.**

- Gameplay: 48 in 3D, plus the touch controls and the real HUD (WP4.3, about 15 to 20) = **about 65 to 70**, inside the ~70 target and 100 budget.
- Triangles: about 73k of 150k.

**Pixels.** Before and after snaps are pixel-identical: max per-channel difference 0 on both renderers.

- Scenes: `car_preview` chase3q driving with steer and brake at sky_t 0.2 / 0.5 / 0.66, front3q parked with steer at 0.2 / 0.66, and side view at 60 km/h. Also `car_drive` chase across all seven keyframes and hood at 0.2 / 0.66.
- The only masked area is the Dev HUD panel, which changed by design.

### Why the phone showed 109

The owner's iPhone report showed 109 draw calls with 45 vehicles, against 77 here with 47 vehicles. The difference is canvas:

- On a touch device the controls overlay draws its pedals and steering ring. It draws nothing here.
- The DEV rows were probably open, adding more dev buttons.

The Dev HUD's `draws` row now reads `total / budget  3d N`, so the next COPY report separates the 3D cost from overlays.

## Tick cost: OppositeTraffic.step

`tests/unit/test_opposite_traffic.gd::test_step_tick_budget`: leg 8, 19 vehicles, player at 200 km/h, desktop median.

| | µs per tick |
| --- | --- |
| before | 17 to 19 |
| after | 5 to 6 |

The phone measured about 26 µs before. The cut comes from two changes:

- The lane-center refresh (the only road query per vehicle) runs at the far-traffic rate: 30 Hz, a quarter of the vehicles per tick.
- The loop reads the state arrays through locals. Packed arrays are shared by reference, so this skips a property lookup per access.

The early return when the count is on target skips the top-up search.

## Render scale and MSAA (the owner's "a bit low res")

Current defaults:

- Medium: 0.75, MSAA off.
- Web: MSAA is always forced off (`web_msaa_samples = 0`).

On the owner's iPhone the web build ran at 60 fps with a 17 ms frame (vsync-bound) and a 24 ms worst frame. At 2496x1320, a scale of 0.75 renders 3D at 1872x990.

The Dev HUD's quality row (`3D`, `MSAA`, tier) now changes both live for the session. It shows the internal 3D resolution, and the COPY report's `render` line carries tier, scale, internal size, MSAA and whether a dev override was used.

**Proposal (needs a device measurement before changing tier defaults):**

1. Owner plays leg 8 on the phone at 3D 0.85, MSAA off, then 3D 1.0, then 0.75 with MSAA 2x. Paste a COPY report for each after a minute of driving.
2. If the `frame` average stays at 16.7 ms and `worst` stays under about 20 ms at 0.85, raise web Medium to 0.85. The web build is the playtest path (D4), and a 17 ms frame is vsync, not load. `QualityTuning` has no per-platform scale today, so this needs a `web_render_scale` override next to `web_msaa_samples` (a small schema addition), or it raises Medium everywhere.
3. Keep MSAA off on web unless 2x holds the frame. MSAA on Compatibility resolves an extra multisampled buffer every frame, which is the kind of pixel cost the spec warns about (cool_drive).
4. Native iOS tiers stay as the spec table says until the thermal soak (D4) says otherwise.
