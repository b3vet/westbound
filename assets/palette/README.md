# Westbound palette (style guide, ART1 start)

The spec's art pipeline asks for "one style guide sheet: a palette of about 30 colors, flat shading, no photo textures". This folder is that sheet.

- `palette.tres` (`WBPalette`): 34 named sRGB colors, the source of truth. Edit colors here.
- `palette.png`: the swatch sheet, 8 per row in the order of `palette.tres`. It is generated; don't edit it.
- `wb_palette.gd`: the resource class. `WBPalette.load_default().color(&"wheat_gold")`.

## Rules

- World meshes carry their colors as vertex colors (`COLOR.rgb`, sRGB), picked **by name** from this palette. See docs/CONTRACTS.md §13 for the other vertex channels (`UV2.x` emissive class, `UV2.y` tint class).
- Use flat shading with one normal per face. There are no textures, gradients or photo detail. Light and fog come from the world shader and the color script.
- Mood comes from the color script (sky_t), not from the palette. Biomes shift it with `BiomeDef.world_tint_offset`. Keep palette colors mid-value so they read at noon and at dusk.
- New colors: add a name and a color to `palette.tres`, then rerun the prop builder (below) to refresh `palette.png`. Keep the total near 30.

| Group | Names |
| --- | --- |
| Neutrals and road furniture | ink, asphalt, concrete, concrete_shade, steel, steel_dark, white, cream, sign_green, sign_blue, hazard_yellow, reflector_amber, reflector_red, lamp_warm |
| Land and crops | wheat_gold, wheat_light, wheat_shade, straw, soil, soil_dark, grass, grass_dry, crop_green, leaf, leaf_dark, bark |
| Buildings | barn_red, roof_slate, silo_metal, sky_pale |
| Invented-brand accents (billboards) | brand_orange, brand_teal, brand_navy, brand_pink |

## Regenerating props and the sheet

```
tools/godot.sh --headless --path . --script res://tools/props/build_props.gd
```

This rebuilds `assets/props/common/*.res`, `assets/props/farmland/*.res` and `palette.png` from the recipes in `tools/props/build_props.gd` (helper: `tools/props/prop_mesh_builder.gd`). The output is deterministic.
