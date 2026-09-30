class_name DetMath
extends RefCounted
## Deterministic transcendental functions: the same bits on every platform (native glibc,
## Emscripten's musl in the web build, iOS / Android libm, and the Rust server's port in
## westbound-server/crates/sim/src/detmath.rs). Spec: Architecture rule 2 (deterministic
## by seed: "This powers Daily Drive, ghosts and reproducible bug reports"); multiplayer
## handoff → N8 (determinism audit: no pow/sin/cos/exp in sim paths). WP N8.2;
## docs/DETERMINISM.md.
##
## The platform math libraries round sin, cos, tan, asin, atan, atan2, exp and pow
## differently in the last bit (WP8.4: glibc vs musl), and a closed loop (a player, the
## director) amplifies a 1-ulp difference into another run within seconds. These are
## built only from IEEE-754 correctly rounded operations (+ - * /, sqrt, floor, trunc,
## comparisons), with fixed range reductions and fixed polynomial coefficients: the
## algorithms and coefficients of fdlibm (Sun Microsystems, "Permission to use, copy,
## modify, and distribute this software is freely granted, provided that this notice is
## preserved"; the musl versions of the kernels), with the bit-level tricks replaced by
## comparisons against constants. Every simulation file calls these instead of the
## global sin / cos / tan / asin / atan / atan2 / exp / log / pow (tools/lint WB105).
##
## Accuracy against the correctly rounded result (tests/unit/test_det_math.gd): sin, cos,
## atan, atan2, exp, log within 1 ulp; tan, asin within 2 ulp; pow ~1 ulp per unit of
## |y log x| (16 ulp over x in 0.05..3, y in -4..4; integer exponents: ~1 ulp per
## squaring). pow runs at load time only (VehicleParams). Range: sin / cos / tan are accurate for |x| < 2^20 pi/2 (~1.6e6; beyond
## it the reduction loses bits, still deterministic). Signed zero: a negative zero is
## treated as zero (atan2(-0.0, -1.0) = +pi, sin(-0.0) = -0.0 passes through).
##
## Keep this file and detmath.rs in lockstep: the same constants, the same operation
## order, the same branches. westbound-server/crates/sim/vectors/detmath.json (written by
## tools/server_data/export_sim_data.gd) pins both, bit for bit.
##
## Inside this class, call the other functions as DetMath.atan(...): an unqualified
## atan(...) here resolves to Godot's global (libm) function, not this one.
##
## Cost (GDScript, one call): ~0.5-1 us. sin_cos() gives both of a heading for one
## reduction (the cosine in `cos_out`).

## Every constant below is written as an integer mantissa times exact powers of two:
## Godot's float literal parser is not correctly rounded (1 ulp off on about a fifth of
## these), integers and products with powers of two are exact. The comment carries the
## decimal value and the IEEE-754 bits (detmath.rs uses the bits).
const TWO_M52 := 1.0 / 4503599627370496   # 2^-52

# fdlibm's pi/2 split in three 33-bit parts (and their tails) for the Cody-Waite reduction.
const PIO2_1 := 7074237751754752 * TWO_M52   # 1.5707963267341256 (0x3FF921FB54400000)
const PIO2_1T := 4701928774853425 * TWO_M52 / 17179869184   # 6.077100506506192e-11 (0x3DD0B4611A626331)
const PIO2_2 := 4701928774696960 * TWO_M52 / 17179869184   # 6.077100506303966e-11 (0x3DD0B4611A600000)
const PIO2_2T := 5376105825661043 * TWO_M52 * TWO_M52 / 131072   # 2.0222662487959506e-21 (0x3BA3198A2E037073)
const PIO2_3 := 5376105825435648 * TWO_M52 * TWO_M52 / 131072   # 2.0222662487111665e-21 (0x3BA3198A2E000000)
const PIO2_3T := 7744522442262977 * TWO_M52 * TWO_M52 / 4503599627370496   # 8.4784276603689e-32 (0x397B839A252049C1)
const INVPIO2 := 5734161139222659 * TWO_M52 / 2   # 0.6366197723675814 (0x3FE45F306DC9C883)
const PIO4 := 7074237752028440 * TWO_M52 / 2   # 0.7853981633974483 (0x3FE921FB54442D18)
const PIO4_LO := 4967757600021511 * TWO_M52 * TWO_M52 / 8   # 3.061616997868383e-17 (0x3C81A62633145C07)
const PIO2_HI := 7074237752028440 * TWO_M52   # 1.5707963267948966 (0x3FF921FB54442D18)
const PIO2_LO := 4967757600021511 * TWO_M52 * TWO_M52 / 4   # 6.123233995736766e-17 (0x3C91A62633145C07)
const PI_HI := 7074237752028440 * TWO_M52 * 2   # 3.141592653589793 (0x400921FB54442D18)
const PI_LO := 4967757600021511 * TWO_M52 * TWO_M52 / 2   # 1.2246467991473532e-16 (0x3CA1A62633145C07)
const HALF := 0.5

# __kernel_sin
const S1 := -6004799503160649 * TWO_M52 / 8   # -0.16666666666666632 (0xBFC5555555555549)
const S2 := 4803839602522278 * TWO_M52 / 128   # 0.00833333333332249 (0x3F8111111110F8A6)
const S3 := -7320136532976085 * TWO_M52 / 8192   # -0.0001984126982985795 (0xBF2A01A019C161D5)
const S4 := 6506786730409597 * TWO_M52 / 524288   # 2.7557313707070068e-06 (0x3EC71DE357B1FE7D)
const S5 := -7571127717829867 * TWO_M52 / 67108864   # -2.5050760253406863e-08 (0xBE5AE5E68A2B9CEB)
const S6 := 6149819165824380 * TWO_M52 / 8589934592   # 1.58969099521155e-10 (0x3DE5D93A5ACFD57C)
# __kernel_cos
const C1 := 6004799503160652 * TWO_M52 / 32   # 0.0416666666666666 (0x3FA555555555554C)
const C2 := -6405119470031223 * TWO_M52 / 1024   # -0.001388888888887411 (0xBF56C16C16C15177)
const C3 := 7320136533611920 * TWO_M52 / 65536   # 2.480158728947673e-05 (0x3EFA01A019CB1590)
const C4 := -5205429506036397 * TWO_M52 / 4194304   # -2.7557314351390663e-07 (0xBE927E4F809C52AD)
const C5 := 5047440159060420 * TWO_M52 / 536870912   # 2.087572321298175e-09 (0x3E21EE9EBDB4B1C4)
const C6 := -7031281271978196 * TWO_M52 / 137438953472   # -1.1359647557788195e-11 (0xBDA8FAE9BE8838D4)
# __kernel_tan
const T0 := 6004799503160675 * TWO_M52 / 4   # 0.3333333333333341 (0x3FD5555555555563)
const T1 := 4803839602523770 * TWO_M52 / 8   # 0.13333333333320124 (0x3FC111111110FE7A)
const T2 := 7777645071909374 * TWO_M52 / 32   # 0.05396825397622605 (0x3FABA1BA1BB341FE)
const T3 := 6303450837472823 * TWO_M52 / 64   # 0.021869488294859542 (0x3F9664F48406D637)
const T4 := 5109309896557715 * TWO_M52 / 128   # 0.0088632398235993 (0x3F8226E3E96E8493)
const T5 := 8282770498781992 * TWO_M52 / 512   # 0.0035920791075913124 (0x3F6D6D22C9560328)
const T6 := 6715580780413717 * TWO_M52 / 1024   # 0.0014562094543252903 (0x3F57DBC8FEE08315)
const T7 := 5423723137099009 * TWO_M52 / 2048   # 0.0005880412408202641 (0x3F4344D8F2F26501)
const T8 := 4546442371600488 * TWO_M52 / 4096   # 0.0002464631348184699 (0x3F3026F71A8D1068)
const T9 := 5768624802861734 * TWO_M52 / 16384   # 7.817944429395571e-05 (0x3F147E88A03792A6)
const T10 := 5268924999444457 * TWO_M52 / 16384   # 7.140724913826082e-05 (0x3F12B80F32F0A7E9)
const T11 := -5477542976836467 * TWO_M52 / 65536   # -1.8558637485527546e-05 (0xBEF375CBDB605373)
const T12 := 7646486854597332 * TWO_M52 / 65536   # 2.590730518636337e-05 (0x3EFB2A7074BF7AD4)
const TAN_BIG := 6074455177397325 * TWO_M52 / 2   # 0.6744 (0x3FE594AF4F0D844D); fdlibm: |x| >= 0x3FE59428 uses the pi/4 - x reflection

# atan
const ATAN_HI_0 := 8352332796509007 * TWO_M52 / 4   # 0.4636476090008061 (0x3FDDAC670561BB4F)
const ATAN_HI_1 := 7074237752028440 * TWO_M52 / 2   # 0.7853981633974483 (0x3FE921FB54442D18)
const ATAN_HI_2 := 8852218891597467 * TWO_M52 / 2   # 0.982793723247329 (0x3FEF730BD281F69B)
const ATAN_HI_3 := 7074237752028440 * TWO_M52   # 1.5707963267948966 (0x3FF921FB54442D18)
const ATAN_LO_0 := 7366174428849634 * TWO_M52 * TWO_M52 / 16   # 2.2698777452961687e-17 (0x3C7A2B7F222F65E2)
const ATAN_LO_1 := 4967757600021511 * TWO_M52 * TWO_M52 / 8   # 3.061616997868383e-17 (0x3C81A62633145C07)
const ATAN_LO_2 := 4511882386918333 * TWO_M52 * TWO_M52 / 16   # 1.3903311031230998e-17 (0x3C7007887AF0CBBD)
const ATAN_LO_3 := 4967757600021511 * TWO_M52 * TWO_M52 / 4   # 6.123233995736766e-17 (0x3C91A62633145C07)
const AT0 := 6004799503160589 * TWO_M52 / 4   # 0.3333333333333293 (0x3FD555555555550D)
const AT1 := -7205759403748292 * TWO_M52 / 8   # -0.19999999999876483 (0xBFC999999998EBC4)
const AT2 := 5146970997949439 * TWO_M52 / 8   # 0.14285714272503466 (0x3FC24924920083FF)
const AT3 := -8006398829074033 * TWO_M52 / 16   # -0.11111110405462356 (0xBFBC71C6FE231671)
const AT4 := 6550674545057902 * TWO_M52 / 16   # 0.09090887133436507 (0x3FB745CDC54C206E)
const AT5 := -5542580929731181 * TWO_M52 / 16   # -0.0769187620504483 (0xBFB3B0F2AF749A6D)
const AT6 := 4799809039908177 * TWO_M52 / 16   # 0.06661073137387531 (0x3FB10D66A0D03D51)
const AT7 := -8407060569849242 * TWO_M52 / 32   # -0.058335701337905735 (0xBFADDE2D52DEFD9A)
const AT8 := 7172437082246635 * TWO_M52 / 32   # 0.049768779946159324 (0x3FA97B4B24760DEB)
const AT9 := -5264754476739631 * TWO_M52 / 32   # -0.036531572744216916 (0xBFA2B4442C6A6C2F)
const AT10 := 4694068057790993 * TWO_M52 / 64   # 0.016285820115365782 (0x3F90AD3AE322DA11)
const ATAN_7_16 := 0.4375
const ATAN_11_16 := 0.6875
const ATAN_19_16 := 1.1875
const ATAN_39_16 := 2.4375
const ATAN_1_5 := 1.5
const TWO_66 := 1.0 * 4294967296 * 4294967296 * 4   # 7.378697629483821e+19 (0x4410000000000000); 2^66

# exp / log
const LN2_HI := 6243314766446592 * TWO_M52 / 2   # 0.6931471803691238 (0x3FE62E42FEE00000)
const LN2_LO := 7382048951581814 * TWO_M52 / 8589934592   # 1.9082149292705877e-10 (0x3DEA39EF35793C76)
const INVLN2 := 6497320848556798 * TWO_M52   # 1.4426950408889634 (0x3FF71547652B82FE)
const HALF_LN2 := 6243314768165359 * TWO_M52 / 4   # 0.34657359027997264 (0x3FD62E42FEFA39EF); exp: |x| > 0.5 ln2 reduces
const THREE_HALF_LN2 := 4682486076124019 * TWO_M52   # 1.0397207708399179 (0x3FF0A2B23F3BAB73)
const EXP_OVERFLOW := 6243314768165359 * TWO_M52 * 512   # 709.782712893384 (0x40862E42FEFA39EF)
const EXP_UNDERFLOW := -6554261109157969 * TWO_M52 * 512   # -745.1332191019411 (0xC0874910D52D3051)
const EXP_TINY := 4503599627370496 * TWO_M52 / 268435456   # 3.725290298461914e-09 (0x3E30000000000000); 2^-28
const P1 := 6004799503160638 * TWO_M52 / 8   # 0.16666666666666602 (0x3FC555555555553E)
const P2 := -6405119469862291 * TWO_M52 / 512   # -0.0027777777777015593 (0xBF66C16C16BEBD93)
const P3 := 4880090809097772 * TWO_M52 / 16384   # 6.613756321437934e-05 (0x3F11566AAF25DE2C)
const P4 := -7807914560613361 * TWO_M52 / 1048576   # -1.6533902205465252e-06 (0xBEBBBD41C5D26BF1)
const P5 := 6253375523824848 * TWO_M52 / 33554432   # 4.1381367970572385e-08 (0x3E66376972BEA4D0)
const LG1 := 6004799503160723 * TWO_M52 / 2   # 0.6666666666666735 (0x3FE5555555555593)
const LG2 := 7205759403686404 * TWO_M52 / 4   # 0.3999999999940942 (0x3FD999999997FA04)
const LG3 := 5146971033736025 * TWO_M52 / 4   # 0.2857142874366239 (0x3FD2492494229359)
const LG4 := 8006390766270639 * TWO_M52 / 8   # 0.22222198432149784 (0x3FCC71C51D8E78AF)
const LG5 := 6551322304906206 * TWO_M52 / 8   # 0.1818357216161805 (0x3FC7466496CB03DE)
const LG6 := 5517391500461727 * TWO_M52 / 8   # 0.15313837699209373 (0x3FC39A09D078C69F)
const LG7 := 5331612937900612 * TWO_M52 / 8   # 0.14798198605116586 (0x3FC2F112DF3E5244)
const SQRT2 := 6369051672525773 * TWO_M52   # 1.4142135623730951 (0x3FF6A09E667F3BCD)
## Integer exponents up to this use repeated squaring in pow().
const POW_INT_MAX := 1024.0

const EXP_MIN := -1022
const EXP_MAX := 1023
const SUBNORMAL_SCALE_BITS := 54
const SCALBN_STEP := 969   # 1022 - 53: musl scalbn's underflow step

## sin_cos() writes the cosine here.
static var cos_out: float = 0.0
## The reduction's result (x - n pi/2 as y0 + y1); _rem_pio2 returns n.
static var _y0: float = 0.0
static var _y1: float = 0.0
## 2^k for k in EXP_MIN..EXP_MAX (index k - EXP_MIN), built by exact doubling / halving.
static var _pow2: PackedFloat64Array = _make_pow2()


# ---------------------------------------------------------------- sin, cos, tan

static func sin(x: float) -> float:
	if absf(x) <= PIO4:
		return _ksin0(x)
	if not is_finite(x):
		return NAN
	var n := _rem_pio2(x)
	match n & 3:
		0:
			return _ksin(_y0, _y1)
		1:
			return _kcos(_y0, _y1)
		2:
			return -_ksin(_y0, _y1)
		_:
			return -_kcos(_y0, _y1)


static func cos(x: float) -> float:
	if absf(x) <= PIO4:
		return _kcos(x, 0.0)
	if not is_finite(x):
		return NAN
	var n := _rem_pio2(x)
	match n & 3:
		0:
			return _kcos(_y0, _y1)
		1:
			return -_ksin(_y0, _y1)
		2:
			return -_kcos(_y0, _y1)
		_:
			return _ksin(_y0, _y1)


## sin(x), with cos(x) in DetMath.cos_out: the same bits as sin() and cos(), one reduction.
static func sin_cos(x: float) -> float:
	if absf(x) <= PIO4:
		cos_out = _kcos(x, 0.0)
		return _ksin0(x)
	if not is_finite(x):
		cos_out = NAN
		return NAN
	var n := _rem_pio2(x)
	var s := _ksin(_y0, _y1)
	var c := _kcos(_y0, _y1)
	match n & 3:
		0:
			cos_out = c
			return s
		1:
			cos_out = -s
			return c
		2:
			cos_out = -c
			return -s
		_:
			cos_out = s
			return -c


static func tan(x: float) -> float:
	if absf(x) <= PIO4:
		return _ktan(x, 0.0, 0)
	if not is_finite(x):
		return NAN
	var n := _rem_pio2(x)
	return _ktan(_y0, _y1, n & 1)


## x - n pi/2 = _y0 + _y1 (|_y0| <= ~pi/4); returns n mod 4 (negated for x < 0). fdlibm's medium-size Cody-Waite
## reduction with all three rounds taken (fdlibm takes the later ones only when the first
## cancels; taking them always only adds accuracy).
static func _rem_pio2(x: float) -> int:
	var ax := absf(x)
	var fn := floorf(ax * INVPIO2 + HALF)
	var r := ax - fn * PIO2_1
	var t := r
	var w := fn * PIO2_2
	r = t - w
	w = fn * PIO2_2T - ((t - r) - w)
	t = r
	w = fn * PIO2_3
	r = t - w
	w = fn * PIO2_3T - ((t - r) - w)
	var y0 := r - w
	var y1 := (r - y0) - w
	# n mod 4 (all the callers use), exact and without an int conversion of a huge fn.
	var n := int(fn - 4.0 * floorf(fn * 0.25))
	if x < 0.0:
		_y0 = -y0
		_y1 = -y1
		return -n
	_y0 = y0
	_y1 = y1
	return n


## __kernel_sin(x, 0, 0).
static func _ksin0(x: float) -> float:
	var z := x * x
	var v := z * x
	var r := S2 + z * (S3 + z * (S4 + z * (S5 + z * S6)))
	return x + v * (S1 + z * r)


## __kernel_sin(x, y, 1).
static func _ksin(x: float, y: float) -> float:
	var z := x * x
	var v := z * x
	var r := S2 + z * (S3 + z * (S4 + z * (S5 + z * S6)))
	return x - ((z * (HALF * y - v * r) - y) - v * S1)


## __kernel_cos(x, y) (musl).
static func _kcos(x: float, y: float) -> float:
	var z := x * x
	var w := z * z
	var r := z * (C1 + z * (C2 + z * C3)) + w * w * (C4 + z * (C5 + z * C6))
	var hz := HALF * z
	w = 1.0 - hz
	return w + (((1.0 - w) - hz) + (z * r - x * y))


## __kernel_tan(x, y, odd) (musl); the odd case returns -1 / (x + r) directly (fdlibm
## splits the reciprocal with bit tricks; this is up to 2 ulp).
static func _ktan(x: float, y: float, odd: int) -> float:
	var big := absf(x) >= TAN_BIG
	var neg := x < 0.0
	if big:
		if neg:
			x = -x
			y = -y
		x = (PIO4 - x) + (PIO4_LO - y)
		y = 0.0
	var z := x * x
	var w := z * z
	var r := T1 + w * (T3 + w * (T5 + w * (T7 + w * (T9 + w * T11))))
	var v := z * (T2 + w * (T4 + w * (T6 + w * (T8 + w * (T10 + w * T12)))))
	var s := z * x
	r = y + z * (s * (r + v) + y) + s * T0
	w = x + r
	if big:
		var sg := float(1 - 2 * odd)
		v = sg - 2.0 * (x - (w * w / (w + sg) - r))
		return -v if neg else v
	if odd == 0:
		return w
	return -1.0 / w


# ---------------------------------------------------------------- atan, atan2, asin

static func atan(x: float) -> float:
	if is_nan(x):
		return x
	var ax := absf(x)
	if ax >= TWO_66:
		return -(ATAN_HI_3 + ATAN_LO_3) if x < 0.0 else ATAN_HI_3 + ATAN_LO_3
	var id := -1
	var t := x
	if ax >= ATAN_7_16:
		if ax < ATAN_19_16:
			if ax < ATAN_11_16:
				id = 0
				t = (2.0 * ax - 1.0) / (2.0 + ax)
			else:
				id = 1
				t = (ax - 1.0) / (ax + 1.0)
		elif ax < ATAN_39_16:
			id = 2
			t = (ax - ATAN_1_5) / (1.0 + ATAN_1_5 * ax)
		else:
			id = 3
			t = -1.0 / ax
	var z := t * t
	var w := z * z
	var s1 := z * (AT0 + w * (AT2 + w * (AT4 + w * (AT6 + w * (AT8 + w * AT10)))))
	var s2 := w * (AT1 + w * (AT3 + w * (AT5 + w * (AT7 + w * AT9))))
	if id < 0:
		return t - t * (s1 + s2)
	var hi := ATAN_HI_0
	var lo := ATAN_LO_0
	if id == 1:
		hi = ATAN_HI_1
		lo = ATAN_LO_1
	elif id == 2:
		hi = ATAN_HI_2
		lo = ATAN_LO_2
	elif id == 3:
		hi = ATAN_HI_3
		lo = ATAN_LO_3
	var r := hi - ((t * (s1 + s2) - lo) - t)
	return -r if x < 0.0 else r


## atan2(y, x) in (-pi, pi]. A negative zero counts as zero.
static func atan2(y: float, x: float) -> float:
	if is_nan(x) or is_nan(y):
		return x + y
	if x == 1.0:
		return DetMath.atan(y)
	var neg_y := y < 0.0
	var neg_x := x < 0.0
	if y == 0.0:
		return PI_HI if neg_x else 0.0
	if x == 0.0:
		return -(PIO2_HI + PIO2_LO) if neg_y else PIO2_HI + PIO2_LO
	if is_inf(x):
		var a := PI_HI if neg_x else 0.0
		if is_inf(y):
			a = 3.0 * PIO4 if neg_x else PIO4
		return -a if neg_y else a
	if is_inf(y):
		return -(PIO2_HI + PIO2_LO) if neg_y else PIO2_HI + PIO2_LO
	var z := DetMath.atan(absf(y / x))
	if not neg_x:
		return -z if neg_y else z
	if neg_y:
		return (z - PI_LO) - PI_HI
	return PI_HI - (z - PI_LO)


## asin(x) = atan2(x, sqrt((1 - x)(1 + x))); NaN outside [-1, 1].
static func asin(x: float) -> float:
	if not (absf(x) <= 1.0):
		return NAN
	return DetMath.atan2(x, sqrt((1.0 - x) * (1.0 + x)))


# ---------------------------------------------------------------- exp, log, pow

static func exp(x: float) -> float:
	if is_nan(x):
		return x
	if x > EXP_OVERFLOW:
		return INF
	if x < EXP_UNDERFLOW:
		return 0.0
	var ax := absf(x)
	var k := 0
	var hi := x
	var lo := 0.0
	if ax > HALF_LN2:
		if ax >= THREE_HALF_LN2:
			k = int(INVLN2 * x + (-HALF if x < 0.0 else HALF))
		else:
			k = -1 if x < 0.0 else 1
		var fk := float(k)
		hi = x - fk * LN2_HI
		lo = fk * LN2_LO
	elif ax <= EXP_TINY:
		return 1.0 + x
	var r := hi - lo
	var xx := r * r
	var c := r - xx * (P1 + xx * (P2 + xx * (P3 + xx * (P4 + xx * P5))))
	var y := 1.0 + (r * c / (2.0 - c) - lo + hi)
	if k == 0:
		return y
	return scalbn(y, k)


## Natural logarithm. NaN below 0, -INF at 0.
static func log(x: float) -> float:
	if is_nan(x) or x < 0.0:
		return NAN
	if x == 0.0:
		return -INF
	if is_inf(x):
		return x
	var k := 0
	if x < _pow2[0]:
		x *= _pow2[SUBNORMAL_SCALE_BITS - EXP_MIN]
		k = -SUBNORMAL_SCALE_BITS
	var e := _exponent(x)
	var m := 0.0
	if e == EXP_MAX:
		m = (x * HALF) * _pow2[1 - EXP_MAX - EXP_MIN]   # 2^-1023 is not in the table
	else:
		m = x * _pow2[-e - EXP_MIN]
	k += e
	if m >= SQRT2:
		m *= HALF
		k += 1
	var f := m - 1.0
	var s := f / (2.0 + f)
	var dk := float(k)
	var z := s * s
	var w := z * z
	var t1 := w * (LG2 + w * (LG4 + w * LG6))
	var t2 := z * (LG1 + w * (LG3 + w * (LG5 + w * LG7)))
	var r := t2 + t1
	var hfsq := HALF * f * f
	return dk * LN2_HI - ((hfsq - (s * (hfsq + r) + dk * LN2_LO)) - f)


## x^y. Integer y (|y| <= 1024): repeated squaring (any sign of x); y = 0.5: sqrt;
## otherwise exp(y log x) for x > 0, 0 or INF at x = 0, NaN for x < 0.
static func pow(x: float, y: float) -> float:
	if y == 0.0:
		return 1.0
	if is_nan(x) or is_nan(y):
		return NAN
	if y == floorf(y) and absf(y) <= POW_INT_MAX:
		var n := int(absf(y))
		var b := x
		var acc := 1.0
		while n > 0:
			if (n & 1) == 1:
				acc *= b
			n >>= 1
			if n > 0:
				b *= b
		return 1.0 / acc if y < 0.0 else acc
	if x < 0.0:
		return NAN
	if x == 0.0:
		return 0.0 if y > 0.0 else INF
	if is_inf(x):
		return INF if y > 0.0 else 0.0
	if y == HALF:
		return sqrt(x)
	return DetMath.exp(y * DetMath.log(x))


## y × 2^n (musl scalbn's steps, so huge and tiny n round the same way everywhere).
static func scalbn(y: float, n: int) -> float:
	if n > EXP_MAX:
		y *= _pow2[EXP_MAX - EXP_MIN]
		n -= EXP_MAX
		if n > EXP_MAX:
			y *= _pow2[EXP_MAX - EXP_MIN]
			n -= EXP_MAX
			n = mini(n, EXP_MAX)
	elif n < EXP_MIN:
		y *= _pow2[-SCALBN_STEP - EXP_MIN]
		n += SCALBN_STEP
		if n < EXP_MIN:
			y *= _pow2[-SCALBN_STEP - EXP_MIN]
			n += SCALBN_STEP
			n = maxi(n, EXP_MIN)
	return y * _pow2[n - EXP_MIN]


## floor(log2(x)) for a normal positive finite x (binary search in the table).
static func _exponent(x: float) -> int:
	var lo := EXP_MIN
	var hi := EXP_MAX
	while lo < hi:
		var mid := (lo + hi + 1) >> 1
		if x >= _pow2[mid - EXP_MIN]:
			lo = mid
		else:
			hi = mid - 1
	return lo


static func _make_pow2() -> PackedFloat64Array:
	var t := PackedFloat64Array()
	t.resize(EXP_MAX - EXP_MIN + 1)
	t[-EXP_MIN] = 1.0
	for i in range(-EXP_MIN + 1, t.size()):
		t[i] = t[i - 1] * 2.0
	for i in range(-EXP_MIN - 1, -1, -1):
		t[i] = t[i + 1] * HALF
	return t
