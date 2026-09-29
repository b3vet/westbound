# Audio

WP7A (plan WP7.1 engine and wind, WP7.2 pass and traffic audio, WP7.3 music and stingers). Spec: *Audio, haptics and game feel*. The system only **listens** to `Events` and **reads** state (the player's `VehicleState` and `VehicleInput`, `TrafficState`, the road's features). It never drives gameplay.

## Overview

| File | What it does |
| --- | --- |
| `src/audio/game_audio.gd` (`GameAudio`) | The hub. It connects to `Events`, re-reads the run's car, traffic, road and origin every frame (a retry rebuilds them), and updates the other parts. It also sets bus volumes from Settings and handles mute (the setting and the M key). |
| `src/audio/engine_audio.gd` (`EngineAudio`) | Engine loops (6 rpm steps × on/off throttle), crossfaded and pitched by rpm, with the gear-shift dip. Also the boost intake roar and the wind. |
| `src/audio/traffic_audio.gd` (`TrafficAudio`) | Tire hum of the nearest cars, the truck air-brake hiss, finding the passed car for the whoosh, and doppler and placement for positional voices. |
| `src/audio/music_player.gd` (`MusicPlayer`) | The playlist, the night filter fade, and feeding `MusicClock`. |
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
- **Web.** The web build is single-threaded, so Godot plays one-shots and loops as **Web Audio samples**. Samples get bus volume and mute, pan and pitch, but **no bus effects**, so the tunnel reverb is native-only. Music uses stream playback on the web (`music_stream_on_web`). That keeps the night filter working and avoids decoding a whole 3-minute track into a PCM buffer. Godot resumes the browser's AudioContext on the first input event. Nothing here plays before the countdown except music, which the browser holds until that gesture (WP9.2 polishes the unlock).

## Settings

The in-run settings panel (`src/ui/screens/settings_panel.gd`) has two pages, **GAME** (the rows it had before) and **AUDIO**. The two tabs sit in the header row between the title and ACCOUNT / DONE. The AUDIO page has a row per bus (MASTER, MUSIC, EFFECTS, ENGINE, INTERFACE) with the `volume_steps` choices (OFF, 50%, 75%, 100%), plus SOUND (ON / MUTED). The panel was already full at a 88 px touch target, which is why it needed a second page.

## Engine and wind

- `engine_step_rpm = [900, 1575, 2450, 3500, 4900, 7000]`. Each step is exact: 22050 × 120 / rpm is a whole number of samples per 4-stroke cycle, so the synthesized loops are seamless.
- **Weights.** An equal-power crossfade (cos and sin) runs between the two steps around the smoothed rpm. A second equal-power blend over the smoothed throttle (`throttle − brake`, with a dead band) splits on-throttle from off-throttle. The level ramps by `engine_idle_db` from idle to redline. Each loop's pitch is rpm / step rpm, clamped to 0.5–2. Voices with no gain are paused, so at most 4 engine loops mix at once.
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

`AudioTuning.music_tracks` play in order and loop around the list, with a `music_gap_s` gap and a `music_fade_in_s` fade-in. Only the playing track is loaded. The playlist starts when the audio starts and moves on at each track's end. The night filter is on the Music bus (see Buses).

## Voice budget

| Kind | Count | Notes |
| --- | --- | --- |
| Flat one-shots (`AudioStreamPlayer`) | 10 | stingers, chimes, impacts, zip, thump, boost whoosh |
| Positional one-shots (`AudioStreamPlayer3D`) | 6 | whooshes, horns, hiss, scrape |
| Cap across one-shots | 16 (`max_voices`) | A new sound steals the lowest-priority, oldest voice at or below its own priority; otherwise it drops. Priorities: hit 10 > stinger 9 > whoosh / thump 8 > zip 7 > chime 6 > boost / scrape 5 > horn 4 > hiss 3 |
| Engine loops | 12 players, ≤ 4 audible | Zero-gain loops are paused |
| Intake, wind | 2 | Paused when silent |
| Tire hum (3D loops) | 3 | Paused when silent |
| Music | 1 | |

Worst case: 16 one-shots + 4 engine + 2 + 3 + 1 = **26 mixing voices**; typical is about 10. Every player is created once in `setup()`, and no node is created per event or per frame (a test checks the node count over 200 event bursts). Per-frame code allocates nothing: the traffic scan and nearest-car insertion use fixed arrays. Godot itself creates a short-lived stream-playback object per `play()`; it is freed when the sound ends.

## Assets

All sounds are mono OGG Vorbis at 22.05 kHz except music (32 kHz stereo). Total: **about 4.0 MB** (music 3.7 MB, effects about 0.35 MB). Everything is logged in `assets/LICENSES.md`.

- **Synthesized in-house** (`tools/audio/gen_audio.py synth`, numpy + soundfile, deterministic seeds). The engine loops are an 8-cylinder pulse train with slightly uneven firing (the V8 burble), convolved with an exhaust resonance, plus firing-modulated combustion noise and a half-order rumble; the off-throttle loops are softer and low-passed. Also wind, tire hum, intake, the whoosh (a band-pass sweep up then down, like a doppler pass-by), zip, thump, horn, air brake, boost whoosh, and the musical stingers and chimes (additive plucks and bells in C major pentatonic).
- **Kenney CC0 packs** (`tools/audio/gen_audio.py cc0` downloads and converts them): the hit impact, crash metal and glass, the scrape, a UI click.
- **Music, CC0 from OpenGameArt**: "Midnight Drive" (congusbongus), "Cyber Runner" (ansimuz), "Slampe" (fupi). They are re-encoded to 32 kHz stereo at about 55 kbps.
- **Not used: the cool_drive MP3s.** They are Suno generations (the ID3 tags link to suno.com) with no licence note in the repo, their rights depend on the owner's Suno plan, and they are 4–5.5 MB each. The owner can drop them in later (see below).

Regenerate with `pip install numpy soundfile`, then `python3 tools/audio/gen_audio.py all`, then `tools/godot.sh --headless --path . --import`. Loop files have `loop=true` in their `.import`: `engine_*`, `wind_loop`, `tire_hum_loop`, `intake_loop`. Rebuild the bus layout with `tools/godot.sh --headless --path . --script res://tools/audio/build_bus_layout.gd`.

## Swapping in licensed audio

1. **Same name, same path.** Replace `assets/audio/<name>.ogg` with the new file, keeping the name; for a loop, keep `loop=true` in its `.import` (or tick Loop in the import dock). Record the source and licence in `assets/LICENSES.md`.
2. **Engine recordings.** Record or buy loops at a few steady rpm values, on and off throttle. Name them `engine_on_<rpm>.ogg` / `engine_off_<rpm>.ogg` and set `engine_step_rpm` in `data/tuning/audio.tres` to those rpm values. Any count of steps works (at least 2 recommended).
3. **Music.** Edit `music_tracks` (and `music_bpm` if the tempo is known, which starts the music clock) in `data/tuning/audio.tres`. Keep tracks at 128 kbps or less for the web pack; 32–44.1 kHz OGG is fine.
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
- the music playlist and the clock;
- loop import flags;
- the voice cap and priority stealing;
- no new nodes or leftover objects per event;
- the run attaching the audio.

`tests/audio/test_audio_settings.gd` covers the AUDIO page of the in-run settings: the tabs, the rows, taps writing Settings, and text fit at both text sizes on the plain and the notched canvas.

Review scene: `tools/snap.sh src/audio/dev/audio_settings_preview.tscn --sweep=page:game,audio`.
