# Asset licenses

Every third-party file in the repo is listed here with its source URL and license. Only **CC0** is accepted (OFL for fonts); see CLAUDE.md and the plan's decision D2 (CC0 packs are interim placeholders).

## Third-party assets

| Asset | Files | Source | License | Added by |
| --- | --- | --- | --- | --- |
| Chakra Petch SemiBold (600) and Bold (700), the HUD and UI display font | `assets/fonts/ChakraPetch-SemiBold.ttf`, `assets/fonts/ChakraPetch-Bold.ttf`, license text `assets/fonts/OFL.txt` | [google/fonts `ofl/chakrapetch`](https://github.com/google/fonts/tree/main/ofl/chakrapetch) (Copyright 2018 The Chakra Petch Project Authors, https://github.com/m4rc1e/Chakra-Petch) | SIL Open Font License 1.1 (OFL), no Reserved Font Name | WP4.3 |
| Chakra Petch Bold subset (A–Z, 0–9, a few signs) for the web loading screen | `platform/web/wordmark.woff` (built by `platform/web/make_font.py` from `assets/fonts/ChakraPetch-Bold.ttf`; name table incl. copyright/OFL notice kept) | google/fonts `ofl/chakrapetch` (as above) | SIL OFL 1.1, no Reserved Font Name | WP9.2 |
| Hit impact, crash metal and glass, barrier scrape (converted to mono 22.05 kHz 16-bit WAV by `tools/audio/gen_audio.py cc0`; Godot imports them with QOA compression) | `assets/audio/hit_impact.wav` (impactMetal_heavy_001), `assets/audio/crash_metal.wav` (impactPlate_heavy_000), `assets/audio/crash_glass.wav` (impactGlass_heavy_000), `assets/audio/scrape.wav` (impactMetal_light_002) | Kenney [Impact Sounds](https://kenney.nl/assets/impact-sounds) | CC0 1.0 | WP7A |
| UI click (converted, as above) | `assets/audio/ui_click.wav` (click_002) | Kenney [Interface Sounds](https://kenney.nl/assets/interface-sounds) | CC0 1.0 | WP7A |
| Music: "Midnight Drive" by congusbongus (re-encoded 32 kHz stereo OGG by `tools/audio/gen_audio.py cc0`) | `assets/audio/music_midnight_drive.ogg` | [OpenGameArt: Midnight Drive](https://opengameart.org/content/midnight-drive) | CC0 1.0 | WP7A |
| Music: "Cyber Runner" by ansimuz (re-encoded, as above) | `assets/audio/music_cyber_runner.ogg` | [OpenGameArt: Cyber Runner Music](https://opengameart.org/content/cyber-runner-music) | CC0 1.0 | WP7A |
| Music: "Slampe" (synthwave house) by fupi (re-encoded, as above) | `assets/audio/music_slampe.ogg` | [OpenGameArt: Slampe (synthwave house)](https://opengameart.org/content/slampe-synthwave-house) | CC0 1.0 | WP7A |

## In-house generated assets (no third-party content)

| Asset | Files | Generator |
| --- | --- | --- |
| Roadside furniture: light pole, reflector post, guardrail post, sign gantry, billboards (invented brands: Sundog Diner, Mesa Cola, Coyote Motel) | `assets/props/common/*.res` | `tools/props/build_props.gd` (WP1.4) |
| Farmland props: crop tiles, fence, trees, farmstead, grain bins, windpump, water tower, wind turbine | `assets/props/farmland/*.res` | `tools/props/build_props.gd` (WP1.4) |
| Style-guide palette sheet | `assets/palette/palette.png` | `tools/props/build_props.gd` from `assets/palette/palette.tres` (WP1.4) |
| Traffic vehicles (17 models: 3 sedans, 2 hatchbacks, 2 SUVs, pickup, delivery van, semi with box and tank trailers, coach, 2 motorbikes with riders, 2 sports cars, coupe; the coach livery and motorcycle brands are invented or absent) | `assets/traffic/*.res`, `assets/traffic/*.tscn` | `tools/traffic_models/build_traffic_models.gd` (WP3.1) |
| Audio (synthesized placeholders): engine loops at 6 rpm steps on and off throttle, wind, tire hum, intake roar, pass whoosh, close-pass zip, thread thump, horn, air-brake hiss, boost whoosh, scoring stingers, banking tick and chime, HESITATED and hit stings | Loops as OGG: `assets/audio/engine_on_*.ogg`, `assets/audio/engine_off_*.ogg`, `wind_loop.ogg`, `tire_hum_loop.ogg`, `intake_loop.ogg`. One-shots as WAV (QOA on import): `whoosh`, `zip`, `thump`, `horn`, `air_brake`, `boost_whoosh`, `sting_*`, `chime_*` (`.wav`, under `assets/audio/`) | `tools/audio/gen_audio.py synth` (WP7A; numpy, deterministic) |

## Owner-supplied placeholders

| Asset | Files | Source | Rights | Notes |
| --- | --- | --- | --- | --- |
| Placeholder player cars: Falcon GT, Night Viper, Brute V8 | `assets/cars/placeholder/*.glb` (+ `*.car.json` import hints) | The owner's own project [cool_drive](https://github.com/b3vet/cool_drive) `models/`, generated with Tripo AI | Owner's own assets | Placeholders only (spec: replaced by in-house modular models) |
