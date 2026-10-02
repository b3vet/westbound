# Audio

WP7A (plan WP7.1 engine and wind, WP7.2 pass and traffic audio, WP7.3 music and stingers). Spec: *Audio, haptics and game feel*. The system only **listens** to `Events` and **reads** state (the player's `VehicleState` and `VehicleInput`, `TrafficState`, the road's features). It never drives gameplay.

## Overview

| File | What it does |
| --- | --- |
| `src/audio/game_audio.gd` (`GameAudio`) | The hub. It connects to `Events`, re-reads the run's car, traffic, road and origin every frame (a retry rebuilds them), and updates the other parts. It also sets bus volumes from Settings and handles mute (the setting and the M key). |
| `src/audio/engine_audio.gd` (`EngineAudio`) | Engine loops (6 rpm steps × on/off throttle), crossfaded and pitched by rpm, with the gear-shift dip. Also the boost intake roar and the wind. |
| `src/audio/traffic_audio.gd` (`TrafficAudio`) | Tire hum of the nearest cars, the truck air-brake hiss, finding the passed car for the whoosh, and doppler and placement for positional voices. |
| `src/audio/music_mood.gd` (`MusicMood`) | Pure: which mood the moment wants (MENU, DAY, GOLDEN, NIGHT, RUSH), with the golden latch. |
| `src/audio/music_player.gd` (`MusicPlayer`) | The mood pools in rotation, the minimum play, crossfades (two players), waiting for tracks still being fetched (web), the night filter fade, and feeding `MusicClock`. |
| `src/audio/voice_pool.gd` (`VoicePool`) | Fixed one-shot voices with a cap and priorities. It also keeps the test hook: a log of started sound ids with their process frames. |
| `src/audio/audio_buses.gd` (`AudioBuses`) | Bus names, effect slots, the night and tunnel effect controls, and the volume and mute settings keys. |
| `src/audio/audio_math.gd` (`AudioMath`) | Pure curves: engine weights and pitch, whoosh and zip versus clearance, stinger pitch versus multiplier, doppler, wind. |
| `src/audio/audio_bank.gd` (`AudioBank`) | Every sound file, loaded once. |
| `src/audio/music_clock.gd` (`MusicClock`) | The Tempo Highway hook. It is synced from the playing track when that track's tempo is known (`music_bpm`, 0 for the placeholders, so it stays stopped as in v1). |
| `src/core/tuning/audio_tuning.gd`, `data/tuning/audio.tres` | Every audio number. |
| `default_bus_layout.tres` | The bus layout (Godot loads `res://default_bus_layout.tres` by default, so `project.godot` needs no change). Built by `tools/audio/build_bus_layout.gd`. |

**Hookup.** `run.gd` calls `GameAudio.attach(self)` once in `_ready`. If a `/root/Audio` autoload exists, `attach` binds that node to the run; otherwise it adds a `GameAudio` child to the run. Registering `Audio="*res://src/audio/game_audio.gd"` as an autoload therefore needs no code change, and it keeps music playing across future menus. `GameAudio` runs with `PROCESS_MODE_ALWAYS`: music keeps playing while paused, and the car loops pause. It smooths on real time, so slow motion doesn't bend audio. Reduced motion doesn't affect audio.

## Buses

| Bus | Effects | Carries |
| --- | --- | --- |
| Master | [0] HardLimiter (always on) | everything |
| Music | [0] LowPassFilter, [1] Reverb (night) | the playlist |
| SFX | [0] Reverb (tunnels) | whooshes, zip, thump, horns, hiss, hum, wind, impacts, boost whoosh |
| Engine | [0] Reverb (tunnels) | engine loops, intake roar |
| UI | none | stingers, banking count-up and chime, HESITATED and hit stings |

- **Volumes.** Each bus has a base level in `AudioTuning` (`*_db`) and a player setting (`volume_master`, `volume_music`, `volume_sfx`, `volume_engine`, `volume_ui`: linear 0 to 1). The result is `base + linear_to_db(setting)`, gliding over `volume_glide_s`. A setting of 0 mutes the bus. `audio_muted` mutes Master; the M key (`PlayerInput.mute_toggled`) flips it. All six keys persist with the other settings.
- **Night.** `night_started` fades the Music low-pass (20 kHz down to `night_lowpass_hz`, an exponential sweep) and the reverb in over `night_fade_s`. `dawn_started(duration)` fades them out over the dawn (capped at `night_fade_s`). `morning_reached` snaps them off. Effects are disabled whenever they are at 0.
- **Tunnels.** `TunnelLight.factor_at(player.s)` gives the same smooth 0 to 1 at the portals that the lighting uses (it reads the road's `TUNNEL` features). It sets the SFX and Engine reverb wet level (`tunnel_reverb_wet` × factor). Outside tunnels the effect is off.
- **Web.** The web build is single-threaded, so Godot plays one-shots and loops as **Web Audio samples** (and never pauses a loop there: see [Loops on the web](#loops-on-the-web)). Samples get bus volume and mute, pan and pitch, but **no bus effects**, so the tunnel reverb is native-only. Music uses stream playback on the web (`music_stream_on_web`). That keeps the night filter working and avoids decoding a whole 3-minute track into a PCM buffer. Godot resumes the browser's AudioContext on the first input event. Nothing here plays before the countdown except music, which the browser holds until that gesture (WP9.2 polishes the unlock).

## Settings

The in-run settings panel (`src/ui/screens/settings_panel.gd`) has two pages, **GAME** (the rows it had before) and **AUDIO**. The two tabs sit in the header row between the title and ACCOUNT / DONE. The AUDIO page has a row per bus (MASTER, MUSIC, EFFECTS, ENGINE, INTERFACE) with the `volume_steps` choices (OFF, 50%, 75%, 100%), plus SOUND (ON / MUTED). The panel was already full at a 88 px touch target, which is why it needed a second page.

## Engine and wind

- `engine_step_rpm = [900, 1575, 2450, 3500, 4900, 7000]`. Each step is exact: 22050 × 120 / rpm is a whole number of samples per 4-stroke cycle, so the synthesized loops are seamless.
- **Weights.** An equal-power crossfade (cos and sin) runs between the two steps around the smoothed rpm. A second equal-power blend over the smoothed throttle (`throttle − brake`, with a dead band) splits on-throttle from off-throttle. The level ramps by `engine_idle_db` from idle to redline. Each loop's pitch is rpm / step rpm, clamped to 0.5–2. Voices with no gain are paused (on the web: stopped, see [Loops on the web](#loops-on-the-web)), so at most 4 engine loops mix at once.
- **Gear shifts.** An upshift (`VehicleState.gear` rises) dips the level by `engine_shift_dip_db` and recovers over `engine_shift_dip_s`. The gearbox itself drops the rpm, so the pitch falls on its own. `Events.gear_shifted` is never emitted by gameplay today, so the engine reads the gear from the state.
- **Fades.** The engine fades in during the countdown and driving, and fades out on the crash and at the results.
- **Wind.** The wind loop plays on SFX. Its level runs from `wind_min_db` at `wind_min_kmh` to `wind_max_db` at `wind_full_kmh`, its pitch rises with speed, and boosting adds `wind_boost_db`.
- **Boost.** `boost_started` plays the boost whoosh (a one-shot). The intake roar loop fades in while `boost_active` is set, pitched by rpm.

## Pass and traffic sounds

- **Pass whoosh**, on every `scored` pass or close pass. Its level and pitch come from the clearance: from `whoosh_far_*` at 3 m or more to `whoosh_near_*` at 0.2 m or less. A higher pitch plays the sample faster, so it is shorter and sharper. The voice is positional (`AudioStreamPlayer3D`, with the camera as listener), placed on the **passed car**. That car is found as the live traffic car nearest the player's tail, since a pass is paid once the car is fully behind. The voice then follows the car for its duration, with doppler from the road-space relative velocity (`AudioMath.doppler_pitch`). If no car is found, the whoosh sits beside and behind the player.
- **Zip.** A close pass adds the zip layer (SFX), sharper when closer.
- **Thump.** A thread adds the thump. Its two passes already had their whooshes.
- **Horns.** `traffic_horn(slot, pos)` plays a positional horn that follows the car, with doppler. Trucks and buses (mass ≥ `heavy_mass_kg`) play lower (`horn_heavy_pitch`), and each car gets a small per-vehicle pitch variation.
- **Air-brake hiss.** Two triggers, each with a per-slot cooldown: `traffic_brake_tap` on a heavy vehicle, and any heavy vehicle within `air_brake_radius_m` whose `FLAG_BRAKE_STRONG` switches on (a rising edge, keyed on `vehicle_id`).
- **Tire hum.** The `tire_hum_voices` (3) nearest cars within `tire_hum_radius_m` each get a looping positional hum. Its pitch follows the car's speed and its doppler; heavy vehicles are lower and louder. A voice keeps its car while that car stays among the nearest.
- **Barrier scrape.** `barrier_scrape(pos)` plays a scrape at the contact point, rate-limited.

## Stingers and stings (UI bus)

| Event | Sound |
| --- | --- |
| `scored` pass / close pass / cut / thread | `sting_pass` / `sting_close` / `sting_cut` / `sting_thread`, pitched by the multiplier: a major-pentatonic note, `stinger_steps_per_doubling` (2) steps per doubling of the multiplier, capped at 2 octaves |
| `chain_banked` (not at run end) | Count-up: one rising `chime_tick` per `chime_points_per_tick` banked (3–12 ticks, `chime_tick_s` apart; the first in the same frame), then `chime_bank` |
| `bonus_awarded` | `chime_bank`, quieter |
| `hesitated` | `sting_hesitated` (a descending wah) |
| `hit` | `hit_impact` (SFX) + `sting_hit` (a dissonant stab) |
| `crash_started` | `crash_metal` + `crash_glass` (SFX); the engine fades out |

Every handler starts its sound inside the signal callback, so the sound starts in the same frame as its event. `tests/audio/test_audio.gd` checks this through `VoicePool`'s frame log.

## Music

Music follows the **mood** of the moment (owner decision; not in the spec). Each frame `GameAudio` feeds `MusicMood` the game state, the room, the biome at the player and the run's `SunClock` (`sky_t`, `phase`; rooms and the loop mode set them from the room clock), and tells `MusicPlayer.want_mood()` the result.

| Mood | When | Pool (`music_pool_*`) |
| --- | --- | --- |
| MENU | no run is being driven: title, garage, results, room lobby (Game state not COUNTDOWN, RUNNING or CRASH) | `music_menu_1`, `music_menu_2` |
| RUSH | a room on RUSH HOUR density (`NetRoomState.density == "rush"`), or a solo run (Journey, Daily Drive; not a room, not the loop mode) in a `music_rush_biomes` biome (default `city`: legs 6 and 7) | `music_rush_hour_1`, `music_rush_hour_2`, `music_cyber_runner` |
| NIGHT | sun phase NIGHTFALL or NIGHT | `music_night_drive_1`, `music_night_drive_2`, `music_midnight_drive` |
| GOLDEN | sun phase DAY with `sky_t` in [`sky_t_golden_hour`, `sky_t_sunset`); **latched**: a checkpoint's sun lift back below the golden hour keeps GOLDEN until the night or a new run | `music_golden_hour_1`, `music_golden_hour_2` |
| DAY | the rest of the day, and the dawn | `music_day_cruise_1`, `music_day_cruise_2`, `music_slampe` |

Priority when several apply: MENU > RUSH > NIGHT > GOLDEN > DAY. A city leg in a room is not RUSH (only the room's density counts there).

`MusicPlayer` rules:

- **Rotation.** At a track's end the next track of the wanted mood's pool plays, after `music_gap_s`, with a `music_fade_in_s` fade-in. Each pool rotates (deterministically, no randomness), never plays the same track twice in a row (pools of 2+), and keeps its place across mood changes, so coming back to a mood plays its next track. A track always starts from the top. Only the playing tracks are loaded; a faded-out player drops its stream.
- **Mood change.** A crossfade (equal power) over `music_crossfade_s` (4 s) on the second of two players (A/B), once the playing track has played `music_min_play_s` (45 s). A change asked for earlier waits, and is dropped if the mood flips back to the playing track's meanwhile. Entering or leaving MENU (run start, run end, quit to the title) switches at once, still crossfaded. The minimum counts from when a track actually started.
- **Tracks not here yet** (the web, [docs/WEB.md → Music packs](WEB.md#music-packs)): the player asks `WebMusicPack` for the track, keeps the current music (or silence at boot) and starts or crossfades when it lands; a failed track is skipped for the next of its pool. When a track starts it prefetches the next track of its pool, then the first of the likely next mood (MENU → DAY, DAY → GOLDEN, GOLDEN → NIGHT, NIGHT → DAY, RUSH → the time-of-day mood).
- **Night filter.** Unchanged: the Music bus low-pass and reverb fade in on `night_started` and out over the dawn (see Buses), whatever track plays.
- `MusicClock` follows the current (incoming) track; `music_bpm` is per track (by `music_tracks` index).

Tuning (`data/tuning/audio.tres`): `music_tracks`, `music_bpm`, `music_pool_menu/day/golden/night/rush`, `music_rush_biomes`, `music_crossfade_s`, `music_min_play_s`, `music_gap_s`, `music_fade_in_s`.

## Voice budget

| Kind | Count | Notes |
| --- | --- | --- |
| Flat one-shots (`AudioStreamPlayer`) | 10 | stingers, chimes, impacts, zip, thump, boost whoosh |
| Positional one-shots (`AudioStreamPlayer3D`) | 6 | whooshes, horns, hiss, scrape |
| Cap across one-shots | 16 (`max_voices`) | A new sound steals the lowest-priority, oldest voice at or below its own priority; otherwise it drops. Priorities: hit 10 > stinger 9 > whoosh / thump 8 > zip 7 > chime 6 > boost / scrape 5 > horn 4 > hiss 3 |
| Engine loops | 12 players, ≤ 4 audible | Zero-gain loops are paused (web: stopped after `loop_stop_hold_s`) |
| Intake, wind | 2 | Paused when silent (web: stopped) |
| Tire hum (3D loops) | 3 | Paused when silent (web: stopped) |
| Music | 2 | both only during a crossfade |

Worst case: 16 one-shots + 4 engine + 2 + 3 + 2 = **27 mixing voices**; typical is about 10. Every player is created once in `setup()`, and no node is created per event or per frame (a test checks the node count over 200 event bursts). Per-frame code allocates nothing: the traffic scan and nearest-car insertion use fixed arrays. Godot itself creates a short-lived stream-playback object per `play()`; it is freed when the sound ends.

## Loops on the web

**The bug (owner report, web build on an iPhone and desktop): the engine and the wind stopped for good after a few minutes of play; one-shots and music kept going.**

**Cause: Godot 4.7's Web Audio sample pause/resume** (`GodotAudio.SampleNode` in the engine's `godot.js`). On the web every loop player (engine steps, intake, wind, tire hum) is a Web Audio *sample*, and Godot loops a sample by starting a fresh `AudioBufferSourceNode` from the source's `ended` event. `EngineAudio` paused a loop whenever its gain reached 0 (a step the rpm left, the off-throttle side at full throttle, the wind below 40 km/h, everything at a crash, the pause menu) and resumed it when heard again. The engine's resume has two defects:

1. `_pause()` stores `pauseTime = ctx.currentTime - _sourceStartTime`, but `_sourceStartTime` is only reset by a full restart (the `ended` path), not by a resume. So after one pause/resume the next pause measures from the old start, **paused time included**, and the value is never wrapped to the buffer (nor scaled by the pitch).
2. `_restart()` starts the new source at `offset + pauseTime`, which is soon past the end of a 2 s (engine) or 4 s (wind) buffer.

Chrome clamps such a start to the end and fires `ended` at once, so its loop restarts (a hiccup). **WebKit (Safari, and every browser on iOS) neither plays nor ends a source started past its end**: no `ended`, so no restart, and Godot still reports the player as playing. The loop is silent until it happens to be paused and resumed again, and that resume starts even further past the end (`pauseTime` keeps growing with every minute since the last full restart), so after a few minutes of play the loops are silent for good. The wind and the dominant engine step are the first to go: at speed they are never paused, so nothing retries them. Measured in Playwright's WebKit with a probe on `GodotAudio.SampleNode`: after a pause, the wind was resumed at 6.2 s into its 4 s buffer and an engine loop at 36.9 s into its 2 s buffer, and neither sounded or restarted again while driving (tens of seconds, until the next crash paused them).

**Fix: on the web a loop is never paused.** `AudioTuning.loop_stop_on_web` (on) makes `EngineAudio` and `TrafficAudio` stop a silent loop instead, once it has been silent for `loop_stop_hold_s` (0.5 s; a gain that hovers at silence then doesn't restart the loop every frame, and each `play()` sets up a Vorbis decoder), and `play()` it again when it is heard. The game pause stops the loops too; they start again on resume. A fresh `play()` starts the source at 0 and Godot's `ended` restart path resets its clock, so the broken resume is never used. Native builds keep pausing (they mix in the engine, where pause works). In WebKit the fixed build drove 8 minutes with pauses and 15 crash/retry cycles: no paused loop, none stuck; in Chromium the smoke below reports 0 loop pauses and 0 resumes past the end (the unfixed build: 62 pauses, 18 resumes past the end in 60 s).

**Checks.**

- `tests/audio/test_audio_loops.gd`: with the web mode forced (`stop_silent`), no loop is ever paused, silent loops stop after the hold and start again when heard, the pause stops them, short silences don't restart them; in both modes, through a real Run with a weaving bot that lifts off the throttle, boosts, gets hit, crashes, sees the results and retries, with pauses, slow motion, night and dawn and jumps to the next checkpoint (leg changes), every loop that should be heard is playing every frame and the engine and wind are heard while driving (`test_loops_survive_a_run_with_every_event`, 13 s per mode; `soak_loops_survive_minutes_with_every_event`, 12 minutes per mode). The web-mode checks fail on the old pause behaviour.
- `node tools/web_smoke/smoke.mjs --landscape --dpr 1 --audio-loops 60`: starts a run, drives it with the gas on and off and the pause key, and watches the engine's sample nodes (the smoke serves an `index.js` that exposes `GodotAudio` to its probe). It fails on any pause of a looping sample, a resume past the end, a stuck loop, or no loop at all.

## Assets

Two formats, by how a sound plays:

- **Loops and music: OGG Vorbis.** The engine loops, `wind_loop`, `tire_hum_loop` and `intake_loop` are mono 22.05 kHz; music is 32 kHz stereo. A loop's decoder is set up once when it starts and then streams.
- **One-shots: WAV, imported with QOA compression** (`compress/mode=2` in each `.wav.import`, about 3.2 bits per sample). The source files are mono 16-bit 22.05 kHz. This is WP7.6's fix for the burst hitch: `play()` on an OGG Vorbis stream sets up a new Vorbis decoder, about 0.55–0.65 ms per voice, so a 20-event frame (32 voices) took about 20 ms mean on the main thread. A QOA voice starts in about 0.05–0.07 ms (it decodes its first 5120-sample frame), and the same burst drains in about 2 ms mean. `tests/feel/test_one_frame.gd` asserts the burst budget (mean ≤ 6 ms with audio, ≤ 0.25 ms of audio per voice), and `tests/audio/test_audio.gd` (`test_one_shots_are_wav`) fails if an OGG one-shot comes back.
  - *Why QOA and not IMA-ADPCM or PCM* (measured in the container). IMA-ADPCM starts in about 1 µs, but Godot's encoder breaks down on the loud broadband noise sounds: the whoosh, zip, air brake and boost come out about 14 dB hotter and distorted (SNR below 0 dB), so it's unusable here. Plain PCM starts in about 1 µs and saves about 1 ms more per 20-event burst, but it is 4.6 times the size (0.48 MB against 0.10 MB). QOA's SNR against the PCM source is 12–17 dB on the noise sounds (the error is itself noise, under the sound) and 24–53 dB on the tonal ones. Switching one file to PCM is just `compress/mode=0` in its `.import`.
  - *Unchanged to the ear.* Durations match the old OGGs to the sample, and RMS is within 1 dB for every file. The WAVs are the synth's own output, and the old Vorbis encode had added about 1–1.5 dB of hiss above 5 kHz on the noise sounds (whoosh, air brake, zip, boost whoosh), so those are now up to 1 dB quieter overall and slightly less hissy. The stingers, chimes, horn, thump and Kenney impacts match within 0.2 dB RMS. Played through Godot, sample peaks are within 0.5 dB, except whoosh (2.3 dB lower) and zip (1.4 dB lower), where QOA's noise-like error moves a single sample of broadband noise; their RMS is unchanged from PCM.

Sizes. **Packed** (the imported files an export ships): one-shots **0.10 MB** as QOA (the OGG one-shots were 0.13 MB), loops 0.25 MB, music 3.89 MB, so audio totals **about 4.24 MB** (was 4.27 MB). **In the repo**, the one-shot sources are 16-bit WAV (0.47 MB), so `assets/audio` grew from 4.0 MB to 4.4 MB; that doesn't reach the pack. Everything is logged in `assets/LICENSES.md`.

- **Synthesized in-house** (`tools/audio/gen_audio.py synth`, numpy + soundfile, deterministic seeds). The engine loops are an 8-cylinder pulse train with slightly uneven firing (the V8 burble), convolved with an exhaust resonance, plus firing-modulated combustion noise and a half-order rumble; the off-throttle loops are softer and low-passed. Also wind, tire hum, intake, the whoosh (a band-pass sweep up then down, like a doppler pass-by), zip, thump, horn, air brake, boost whoosh, and the musical stingers and chimes (additive plucks and bells in C major pentatonic).
- **Kenney CC0 packs** (`tools/audio/gen_audio.py cc0` downloads and converts them): the hit impact, crash metal and glass, the scrape, a UI click.
- **Music, CC0 from OpenGameArt**: "Midnight Drive" (congusbongus), "Cyber Runner" (ansimuz), "Slampe" (fupi). They are re-encoded to 32 kHz stereo at about 55 kbps.
- **Not used: the cool_drive MP3s.** They are Suno generations (the ID3 tags link to suno.com) with no licence note in the repo, their rights depend on the owner's Suno plan, and they are 4–5.5 MB each. The owner can drop them in later (see below).

Regenerate with `pip install numpy soundfile`, then `python3 tools/audio/gen_audio.py all`, then `tools/godot.sh --headless --path . --import`. Loop files have `loop=true` in their `.import`: `engine_*`, `wind_loop`, `tire_hum_loop`, `intake_loop`. The script writes one-shots as `.wav`, plus a QOA `.wav.import` stub when a file has none; Godot fills in the rest on import. The sample data is deterministic (fixed seeds, and the WAVs come out byte-identical), but libsndfile gives each OGG a random stream serial, so a re-run rewrites the loop and music bytes without changing their audio. Commit only the files you meant to change. Rebuild the bus layout with `tools/godot.sh --headless --path . --script res://tools/audio/build_bus_layout.gd`.

## Swapping in licensed audio

1. **Same name, same path.** Replace `assets/audio/<name>.ogg` (a loop) or `assets/audio/<name>.wav` (a one-shot) with the new file, keeping the name. For a loop, keep `loop=true` in its `.import` (or tick Loop in the import dock). A one-shot stays WAV with QOA compression (`compress/mode=2`); convert an OGG or MP3 source to WAV first, since an OGG one-shot costs about 0.6 ms per play and fails `test_one_shots_are_wav`. Record the source and licence in `assets/LICENSES.md`.
2. **Engine recordings.** Record or buy loops at a few steady rpm values, on and off throttle. Name them `engine_on_<rpm>.ogg` / `engine_off_<rpm>.ogg` and set `engine_step_rpm` in `data/tuning/audio.tres` to those rpm values. Any count of steps works (at least 2 recommended).
3. **Music.** Add the track to `music_tracks` (and its `music_bpm` if the tempo is known, which starts the music clock) and to one mood pool (`music_pool_*`) in `data/tuning/audio.tres`. Keep tracks at 128 kbps or less (each is its own web pack); 32–44.1 kHz OGG is fine.
4. **Levels.** Adjust the per-sound `*_db` and per-bus `*_db` values in `data/tuning/audio.tres`; no code changes are needed.

## Tests

`tests/audio/test_audio.gd` covers:

- the bus layout and effects;
- volume settings and mute (including the M key);
- engine crossfade weights (equal power, at most two steps), pitch, on/off throttle, the shift dip and the fade-out;
- wind rising with speed, and the boost whoosh and intake;
- every scoring event, plus banking, HESITATED, hit and crash, sounding in the same frame;
- zip on close passes and thump on threads;
- whoosh level and pitch scaling with clearance;
- the whoosh on the passed car's side, with doppler;
- stinger pitch rising with the multiplier;
- the banking count-up;
- horns (lower for trucks), the air brake (tap, hard-brake edge, cooldown) and tire hum on the nearest cars;
- the night filter on night and dawn, and the tunnel reverb on entry and exit (a straight road with a tunnel feature);
- the music starting and the clock;
- loop import flags, and every one-shot being a non-looping QOA WAV (no OGG one-shots);
- the voice cap and priority stealing;
- no new nodes or leftover objects per event;
- the run attaching the audio.

`tests/audio/test_music_mood.gd` covers the mood choice: menu, day, golden, night, the priority, room rush versus a solo city leg (a city leg in a room is not rush), the golden latch across a sun lift and its clearing at night, dawn to day, and that every track sits in exactly one pool. `tests/audio/test_music_player.gd` covers the player: start from the top, the minimum play (deferral and cancel), the crossfade finishing and stopping the old player, rotation without back-to-back repeats and across moods, MENU switching at once, hold and stop, and tracks fetched first (waiting, the prefetch order, a failed track skipped).

`tests/audio/test_audio_loops.gd` covers the loops over long runs and on the web (see [Loops on the web](#loops-on-the-web)).

`tests/audio/test_audio_settings.gd` covers the AUDIO page of the in-run settings: the tabs, the rows, taps writing Settings, and text fit at both text sizes on the plain and the notched canvas.

Review scene: `tools/snap.sh src/audio/dev/audio_settings_preview.tscn --sweep=page:game,audio`.
