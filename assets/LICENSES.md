# Asset licenses

Every third-party file in the repo is listed here with its source URL and license. Only **CC0** is accepted (OFL for fonts); see CLAUDE.md and the plan's decision D2 (CC0 packs are interim placeholders).

## Third-party assets

| Asset | Files | Source | License | Added by |
| --- | --- | --- | --- | --- |
| — | — | — | — | — |

No third-party assets yet.

## In-house generated assets (no third-party content)

| Asset | Files | Generator |
| --- | --- | --- |
| Roadside furniture: light pole, reflector post, guardrail post, sign gantry, billboards (invented brands: Sundog Diner, Mesa Cola, Coyote Motel) | `assets/props/common/*.res` | `tools/props/build_props.gd` (WP1.4) |
| Farmland props: crop tiles, fence, trees, farmstead, grain bins, windpump, water tower, wind turbine | `assets/props/farmland/*.res` | `tools/props/build_props.gd` (WP1.4) |
| Style-guide palette sheet | `assets/palette/palette.png` | `tools/props/build_props.gd` from `assets/palette/palette.tres` (WP1.4) |

## Owner-supplied placeholders

| Asset | Files | Source | Rights | Notes |
| --- | --- | --- | --- | --- |
| Placeholder player cars: Falcon GT, Night Viper, Brute V8 | `assets/cars/placeholder/*.glb` (+ `*.car.json` import hints) | The owner's own project [cool_drive](https://github.com/b3vet/cool_drive) `models/`, generated with Tripo AI | Owner's own assets | Placeholders only (spec: replaced by in-house modular models) |
