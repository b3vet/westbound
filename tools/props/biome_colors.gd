class_name BiomeColors
extends RefCounted
## Named sRGB colours of the desert and canyon props (WP6.4a), used by
## tools/props/build_props_desert_canyon.gd through PropMeshBuilder.extra_colors.
## Spec: Art pipeline (a palette of about 30 colours, flat shading); World → Biomes
## (desert mesas: red rock, cacti; canyon pass: cliffs, pines). Kept apart from
## assets/palette/palette.tres so parallel biome work does not collide there; the
## style-guide sheet can absorb them later (docs/BIOMES.md). Mid values, like the
## palette, so they read at noon and at dusk.

const COLORS := {
	&"red_rock": Color(0.70, 0.35, 0.22),
	&"red_rock_light": Color(0.82, 0.50, 0.32),
	&"red_rock_dark": Color(0.50, 0.24, 0.16),
	&"rock_band_pale": Color(0.86, 0.68, 0.49),
	&"mesa_top": Color(0.76, 0.54, 0.36),
	&"sand": Color(0.88, 0.74, 0.54),
	&"sand_dark": Color(0.74, 0.57, 0.39),
	&"cactus": Color(0.35, 0.50, 0.30),
	&"cactus_dark": Color(0.24, 0.38, 0.23),
	&"cactus_flower": Color(0.93, 0.42, 0.52),
	&"sage": Color(0.57, 0.61, 0.45),
	&"scrub": Color(0.47, 0.48, 0.30),
	&"dead_wood": Color(0.55, 0.45, 0.35),
	&"canyon_rock": Color(0.62, 0.40, 0.29),
	&"canyon_rock_dark": Color(0.44, 0.28, 0.21),
	&"canyon_rock_pale": Color(0.78, 0.60, 0.45),
	&"pine": Color(0.20, 0.34, 0.24),
	&"pine_dark": Color(0.13, 0.25, 0.18),
}
