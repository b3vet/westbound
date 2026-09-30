//! Deterministic transcendentals, bit for bit the same as the client's `DetMath`
//! (`src/core/det_math.gd`, WP N8.2; docs/DETERMINISM.md). The platform math libraries
//! round sin, cos, tan, asin, atan, atan2, exp and pow differently in the last bit (glibc
//! vs Emscripten's musl vs Rust's own), so the simulation uses these instead: built only
//! from IEEE-754 correctly rounded operations (+ - * /, sqrt, floor, comparisons) with the
//! algorithms and coefficients of fdlibm (Sun Microsystems: "Permission to use, copy,
//! modify, and distribute this software is freely granted, provided that this notice is
//! preserved"; the musl kernels), the bit tricks replaced by comparisons.
//!
//! Keep this file and det_math.gd in lockstep: the same constants (bits), the same
//! operation order, the same branches. `tests/detmath.rs` checks every case of
//! `vectors/detmath.json` (written by tools/server_data/export_sim_data.gd) bit for bit.
//! No `mul_add` (FMA) anywhere: GDScript has none and the rounding differs.

#![allow(clippy::excessive_precision, clippy::unreadable_literal)]

pub const PIO2_1: f64 = f64::from_bits(0x3FF921FB_54400000); // 1.5707963267341256
pub const PIO2_1T: f64 = f64::from_bits(0x3DD0B461_1A626331); // 6.077100506506192e-11
pub const PIO2_2: f64 = f64::from_bits(0x3DD0B461_1A600000); // 6.077100506303966e-11
pub const PIO2_2T: f64 = f64::from_bits(0x3BA3198A_2E037073); // 2.0222662487959506e-21
pub const PIO2_3: f64 = f64::from_bits(0x3BA3198A_2E000000); // 2.0222662487111665e-21
pub const PIO2_3T: f64 = f64::from_bits(0x397B839A_252049C1); // 8.4784276603689e-32
pub const INVPIO2: f64 = f64::from_bits(0x3FE45F30_6DC9C883); // 0.6366197723675814
pub const PIO4: f64 = f64::from_bits(0x3FE921FB_54442D18); // 0.7853981633974483
pub const PIO4_LO: f64 = f64::from_bits(0x3C81A626_33145C07); // 3.061616997868383e-17
pub const PIO2_HI: f64 = f64::from_bits(0x3FF921FB_54442D18); // 1.5707963267948966
pub const PIO2_LO: f64 = f64::from_bits(0x3C91A626_33145C07); // 6.123233995736766e-17
pub const PI_HI: f64 = f64::from_bits(0x400921FB_54442D18); // 3.141592653589793
pub const PI_LO: f64 = f64::from_bits(0x3CA1A626_33145C07); // 1.2246467991473532e-16
pub const S1: f64 = f64::from_bits(0xBFC55555_55555549); // -0.16666666666666632
pub const S2: f64 = f64::from_bits(0x3F811111_1110F8A6); // 0.00833333333332249
pub const S3: f64 = f64::from_bits(0xBF2A01A0_19C161D5); // -0.0001984126982985795
pub const S4: f64 = f64::from_bits(0x3EC71DE3_57B1FE7D); // 2.7557313707070068e-06
pub const S5: f64 = f64::from_bits(0xBE5AE5E6_8A2B9CEB); // -2.5050760253406863e-08
pub const S6: f64 = f64::from_bits(0x3DE5D93A_5ACFD57C); // 1.58969099521155e-10
pub const C1: f64 = f64::from_bits(0x3FA55555_5555554C); // 0.0416666666666666
pub const C2: f64 = f64::from_bits(0xBF56C16C_16C15177); // -0.001388888888887411
pub const C3: f64 = f64::from_bits(0x3EFA01A0_19CB1590); // 2.480158728947673e-05
pub const C4: f64 = f64::from_bits(0xBE927E4F_809C52AD); // -2.7557314351390663e-07
pub const C5: f64 = f64::from_bits(0x3E21EE9E_BDB4B1C4); // 2.087572321298175e-09
pub const C6: f64 = f64::from_bits(0xBDA8FAE9_BE8838D4); // -1.1359647557788195e-11
pub const T0: f64 = f64::from_bits(0x3FD55555_55555563); // 0.3333333333333341
pub const T1: f64 = f64::from_bits(0x3FC11111_1110FE7A); // 0.13333333333320124
pub const T2: f64 = f64::from_bits(0x3FABA1BA_1BB341FE); // 0.05396825397622605
pub const T3: f64 = f64::from_bits(0x3F9664F4_8406D637); // 0.021869488294859542
pub const T4: f64 = f64::from_bits(0x3F8226E3_E96E8493); // 0.0088632398235993
pub const T5: f64 = f64::from_bits(0x3F6D6D22_C9560328); // 0.0035920791075913124
pub const T6: f64 = f64::from_bits(0x3F57DBC8_FEE08315); // 0.0014562094543252903
pub const T7: f64 = f64::from_bits(0x3F4344D8_F2F26501); // 0.0005880412408202641
pub const T8: f64 = f64::from_bits(0x3F3026F7_1A8D1068); // 0.0002464631348184699
pub const T9: f64 = f64::from_bits(0x3F147E88_A03792A6); // 7.817944429395571e-05
pub const T10: f64 = f64::from_bits(0x3F12B80F_32F0A7E9); // 7.140724913826082e-05
pub const T11: f64 = f64::from_bits(0xBEF375CB_DB605373); // -1.8558637485527546e-05
pub const T12: f64 = f64::from_bits(0x3EFB2A70_74BF7AD4); // 2.590730518636337e-05
pub const TAN_BIG: f64 = f64::from_bits(0x3FE594AF_4F0D844D); // 0.6744
pub const ATAN_HI_0: f64 = f64::from_bits(0x3FDDAC67_0561BB4F); // 0.4636476090008061
pub const ATAN_HI_1: f64 = f64::from_bits(0x3FE921FB_54442D18); // 0.7853981633974483
pub const ATAN_HI_2: f64 = f64::from_bits(0x3FEF730B_D281F69B); // 0.982793723247329
pub const ATAN_HI_3: f64 = f64::from_bits(0x3FF921FB_54442D18); // 1.5707963267948966
pub const ATAN_LO_0: f64 = f64::from_bits(0x3C7A2B7F_222F65E2); // 2.2698777452961687e-17
pub const ATAN_LO_1: f64 = f64::from_bits(0x3C81A626_33145C07); // 3.061616997868383e-17
pub const ATAN_LO_2: f64 = f64::from_bits(0x3C700788_7AF0CBBD); // 1.3903311031230998e-17
pub const ATAN_LO_3: f64 = f64::from_bits(0x3C91A626_33145C07); // 6.123233995736766e-17
pub const AT0: f64 = f64::from_bits(0x3FD55555_5555550D); // 0.3333333333333293
pub const AT1: f64 = f64::from_bits(0xBFC99999_9998EBC4); // -0.19999999999876483
pub const AT2: f64 = f64::from_bits(0x3FC24924_920083FF); // 0.14285714272503466
pub const AT3: f64 = f64::from_bits(0xBFBC71C6_FE231671); // -0.11111110405462356
pub const AT4: f64 = f64::from_bits(0x3FB745CD_C54C206E); // 0.09090887133436507
pub const AT5: f64 = f64::from_bits(0xBFB3B0F2_AF749A6D); // -0.0769187620504483
pub const AT6: f64 = f64::from_bits(0x3FB10D66_A0D03D51); // 0.06661073137387531
pub const AT7: f64 = f64::from_bits(0xBFADDE2D_52DEFD9A); // -0.058335701337905735
pub const AT8: f64 = f64::from_bits(0x3FA97B4B_24760DEB); // 0.049768779946159324
pub const AT9: f64 = f64::from_bits(0xBFA2B444_2C6A6C2F); // -0.036531572744216916
pub const AT10: f64 = f64::from_bits(0x3F90AD3A_E322DA11); // 0.016285820115365782
pub const TWO_66: f64 = f64::from_bits(0x44100000_00000000); // 7.378697629483821e+19
pub const LN2_HI: f64 = f64::from_bits(0x3FE62E42_FEE00000); // 0.6931471803691238
pub const LN2_LO: f64 = f64::from_bits(0x3DEA39EF_35793C76); // 1.9082149292705877e-10
pub const INVLN2: f64 = f64::from_bits(0x3FF71547_652B82FE); // 1.4426950408889634
pub const HALF_LN2: f64 = f64::from_bits(0x3FD62E42_FEFA39EF); // 0.34657359027997264
pub const THREE_HALF_LN2: f64 = f64::from_bits(0x3FF0A2B2_3F3BAB73); // 1.0397207708399179
pub const EXP_OVERFLOW: f64 = f64::from_bits(0x40862E42_FEFA39EF); // 709.782712893384
pub const EXP_UNDERFLOW: f64 = f64::from_bits(0xC0874910_D52D3051); // -745.1332191019411
pub const EXP_TINY: f64 = f64::from_bits(0x3E300000_00000000); // 3.725290298461914e-09
pub const P1: f64 = f64::from_bits(0x3FC55555_5555553E); // 0.16666666666666602
pub const P2: f64 = f64::from_bits(0xBF66C16C_16BEBD93); // -0.0027777777777015593
pub const P3: f64 = f64::from_bits(0x3F11566A_AF25DE2C); // 6.613756321437934e-05
pub const P4: f64 = f64::from_bits(0xBEBBBD41_C5D26BF1); // -1.6533902205465252e-06
pub const P5: f64 = f64::from_bits(0x3E663769_72BEA4D0); // 4.1381367970572385e-08
pub const LG1: f64 = f64::from_bits(0x3FE55555_55555593); // 0.6666666666666735
pub const LG2: f64 = f64::from_bits(0x3FD99999_9997FA04); // 0.3999999999940942
pub const LG3: f64 = f64::from_bits(0x3FD24924_94229359); // 0.2857142874366239
pub const LG4: f64 = f64::from_bits(0x3FCC71C5_1D8E78AF); // 0.22222198432149784
pub const LG5: f64 = f64::from_bits(0x3FC74664_96CB03DE); // 0.1818357216161805
pub const LG6: f64 = f64::from_bits(0x3FC39A09_D078C69F); // 0.15313837699209373
pub const LG7: f64 = f64::from_bits(0x3FC2F112_DF3E5244); // 0.14798198605116586
pub const SQRT2: f64 = f64::from_bits(0x3FF6A09E_667F3BCD); // 1.4142135623730951
pub const HALF: f64 = 0.5;
pub const ATAN_7_16: f64 = 0.4375;
pub const ATAN_11_16: f64 = 0.6875;
pub const ATAN_19_16: f64 = 1.1875;
pub const ATAN_39_16: f64 = 2.4375;
pub const ATAN_1_5: f64 = 1.5;
/// Integer exponents up to this use repeated squaring in `pow`.
pub const POW_INT_MAX: f64 = 1024.0;
pub const EXP_MIN: i32 = -1022;
pub const EXP_MAX: i32 = 1023;
const SUBNORMAL_SCALE_BITS: i32 = 54;
/// 1022 - 53: musl scalbn's underflow step.
const SCALBN_STEP: i32 = 969;

/// 2^n for n in EXP_MIN..=EXP_MAX (a normal number: exact from the bits).
#[inline]
fn two_pow(n: i32) -> f64 {
    debug_assert!((EXP_MIN..=EXP_MAX).contains(&n));
    f64::from_bits(((n + 1023) as u64) << 52)
}

// ---------------------------------------------------------------- sin, cos, tan

pub fn sin(x: f64) -> f64 {
    if x.abs() <= PIO4 {
        return ksin0(x);
    }
    if !x.is_finite() {
        return f64::NAN;
    }
    let (n, y0, y1) = rem_pio2(x);
    match n & 3 {
        0 => ksin(y0, y1),
        1 => kcos(y0, y1),
        2 => -ksin(y0, y1),
        _ => -kcos(y0, y1),
    }
}

pub fn cos(x: f64) -> f64 {
    if x.abs() <= PIO4 {
        return kcos(x, 0.0);
    }
    if !x.is_finite() {
        return f64::NAN;
    }
    let (n, y0, y1) = rem_pio2(x);
    match n & 3 {
        0 => kcos(y0, y1),
        1 => -ksin(y0, y1),
        2 => -kcos(y0, y1),
        _ => ksin(y0, y1),
    }
}

/// (sin x, cos x) with one reduction: the same bits as `sin` and `cos`.
pub fn sin_cos(x: f64) -> (f64, f64) {
    if x.abs() <= PIO4 {
        return (ksin0(x), kcos(x, 0.0));
    }
    if !x.is_finite() {
        return (f64::NAN, f64::NAN);
    }
    let (n, y0, y1) = rem_pio2(x);
    let s = ksin(y0, y1);
    let c = kcos(y0, y1);
    match n & 3 {
        0 => (s, c),
        1 => (c, -s),
        2 => (-s, -c),
        _ => (-c, s),
    }
}

pub fn tan(x: f64) -> f64 {
    if x.abs() <= PIO4 {
        return ktan(x, 0.0, 0);
    }
    if !x.is_finite() {
        return f64::NAN;
    }
    let (n, y0, y1) = rem_pio2(x);
    ktan(y0, y1, n & 1)
}

/// x - n pi/2 = y0 + y1; returns (n mod 4, negated for x < 0; y0; y1). fdlibm's medium
/// Cody-Waite reduction with all three rounds taken.
fn rem_pio2(x: f64) -> (i64, f64, f64) {
    let ax = x.abs();
    let fn_ = (ax * INVPIO2 + HALF).floor();
    let mut r = ax - fn_ * PIO2_1;
    let mut t = r;
    let mut w = fn_ * PIO2_2;
    r = t - w;
    w = fn_ * PIO2_2T - ((t - r) - w);
    t = r;
    w = fn_ * PIO2_3;
    r = t - w;
    w = fn_ * PIO2_3T - ((t - r) - w);
    let y0 = r - w;
    let y1 = (r - y0) - w;
    let n = (fn_ - 4.0 * (fn_ * 0.25).floor()) as i64;
    if x < 0.0 {
        (-n, -y0, -y1)
    } else {
        (n, y0, y1)
    }
}

/// __kernel_sin(x, 0, 0).
#[inline]
fn ksin0(x: f64) -> f64 {
    let z = x * x;
    let v = z * x;
    let r = S2 + z * (S3 + z * (S4 + z * (S5 + z * S6)));
    x + v * (S1 + z * r)
}

/// __kernel_sin(x, y, 1).
#[inline]
fn ksin(x: f64, y: f64) -> f64 {
    let z = x * x;
    let v = z * x;
    let r = S2 + z * (S3 + z * (S4 + z * (S5 + z * S6)));
    x - ((z * (HALF * y - v * r) - y) - v * S1)
}

/// __kernel_cos(x, y) (musl).
#[inline]
fn kcos(x: f64, y: f64) -> f64 {
    let z = x * x;
    let mut w = z * z;
    let r = z * (C1 + z * (C2 + z * C3)) + w * w * (C4 + z * (C5 + z * C6));
    let hz = HALF * z;
    w = 1.0 - hz;
    w + (((1.0 - w) - hz) + (z * r - x * y))
}

/// __kernel_tan(x, y, odd) (musl); odd: -1 / (x + r) directly.
fn ktan(mut x: f64, mut y: f64, odd: i64) -> f64 {
    let big = x.abs() >= TAN_BIG;
    let neg = x < 0.0;
    if big {
        if neg {
            x = -x;
            y = -y;
        }
        x = (PIO4 - x) + (PIO4_LO - y);
        y = 0.0;
    }
    let z = x * x;
    let mut w = z * z;
    let mut r = T1 + w * (T3 + w * (T5 + w * (T7 + w * (T9 + w * T11))));
    let mut v = z * (T2 + w * (T4 + w * (T6 + w * (T8 + w * (T10 + w * T12)))));
    let s = z * x;
    r = y + z * (s * (r + v) + y) + s * T0;
    w = x + r;
    if big {
        let sg = (1 - 2 * odd) as f64;
        v = sg - 2.0 * (x - (w * w / (w + sg) - r));
        return if neg { -v } else { v };
    }
    if odd == 0 {
        return w;
    }
    -1.0 / w
}

// ---------------------------------------------------------------- atan, atan2, asin

pub fn atan(x: f64) -> f64 {
    if x.is_nan() {
        return x;
    }
    let ax = x.abs();
    if ax >= TWO_66 {
        return if x < 0.0 {
            -(ATAN_HI_3 + ATAN_LO_3)
        } else {
            ATAN_HI_3 + ATAN_LO_3
        };
    }
    let mut id: i32 = -1;
    let mut t = x;
    if ax >= ATAN_7_16 {
        if ax < ATAN_19_16 {
            if ax < ATAN_11_16 {
                id = 0;
                t = (2.0 * ax - 1.0) / (2.0 + ax);
            } else {
                id = 1;
                t = (ax - 1.0) / (ax + 1.0);
            }
        } else if ax < ATAN_39_16 {
            id = 2;
            t = (ax - ATAN_1_5) / (1.0 + ATAN_1_5 * ax);
        } else {
            id = 3;
            t = -1.0 / ax;
        }
    }
    let z = t * t;
    let w = z * z;
    let s1 = z * (AT0 + w * (AT2 + w * (AT4 + w * (AT6 + w * (AT8 + w * AT10)))));
    let s2 = w * (AT1 + w * (AT3 + w * (AT5 + w * (AT7 + w * AT9))));
    if id < 0 {
        return t - t * (s1 + s2);
    }
    let (hi, lo) = match id {
        0 => (ATAN_HI_0, ATAN_LO_0),
        1 => (ATAN_HI_1, ATAN_LO_1),
        2 => (ATAN_HI_2, ATAN_LO_2),
        _ => (ATAN_HI_3, ATAN_LO_3),
    };
    let r = hi - ((t * (s1 + s2) - lo) - t);
    if x < 0.0 {
        -r
    } else {
        r
    }
}

/// atan2(y, x) in (-pi, pi]. A negative zero counts as zero.
pub fn atan2(y: f64, x: f64) -> f64 {
    if x.is_nan() || y.is_nan() {
        return x + y;
    }
    if x == 1.0 {
        return atan(y);
    }
    let neg_y = y < 0.0;
    let neg_x = x < 0.0;
    if y == 0.0 {
        return if neg_x { PI_HI } else { 0.0 };
    }
    if x == 0.0 {
        return if neg_y {
            -(PIO2_HI + PIO2_LO)
        } else {
            PIO2_HI + PIO2_LO
        };
    }
    if x.is_infinite() {
        let mut a = if neg_x { PI_HI } else { 0.0 };
        if y.is_infinite() {
            a = if neg_x { 3.0 * PIO4 } else { PIO4 };
        }
        return if neg_y { -a } else { a };
    }
    if y.is_infinite() {
        return if neg_y {
            -(PIO2_HI + PIO2_LO)
        } else {
            PIO2_HI + PIO2_LO
        };
    }
    let z = atan((y / x).abs());
    if !neg_x {
        return if neg_y { -z } else { z };
    }
    if neg_y {
        return (z - PI_LO) - PI_HI;
    }
    PI_HI - (z - PI_LO)
}

/// asin(x) = atan2(x, sqrt((1 - x)(1 + x))); NaN outside [-1, 1].
pub fn asin(x: f64) -> f64 {
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    if !(x.abs() <= 1.0) {
        return f64::NAN;
    }
    atan2(x, ((1.0 - x) * (1.0 + x)).sqrt())
}

// ---------------------------------------------------------------- exp, log, pow

pub fn exp(x: f64) -> f64 {
    if x.is_nan() {
        return x;
    }
    if x > EXP_OVERFLOW {
        return f64::INFINITY;
    }
    if x < EXP_UNDERFLOW {
        return 0.0;
    }
    let ax = x.abs();
    let mut k: i32 = 0;
    let mut hi = x;
    let mut lo = 0.0;
    if ax > HALF_LN2 {
        if ax >= THREE_HALF_LN2 {
            k = (INVLN2 * x + if x < 0.0 { -HALF } else { HALF }) as i32;
        } else {
            k = if x < 0.0 { -1 } else { 1 };
        }
        let fk = k as f64;
        hi = x - fk * LN2_HI;
        lo = fk * LN2_LO;
    } else if ax <= EXP_TINY {
        return 1.0 + x;
    }
    let r = hi - lo;
    let xx = r * r;
    let c = r - xx * (P1 + xx * (P2 + xx * (P3 + xx * (P4 + xx * P5))));
    let y = 1.0 + (r * c / (2.0 - c) - lo + hi);
    if k == 0 {
        return y;
    }
    scalbn(y, k)
}

/// Natural logarithm. NaN below 0, -INF at 0.
pub fn log(mut x: f64) -> f64 {
    if x.is_nan() || x < 0.0 {
        return f64::NAN;
    }
    if x == 0.0 {
        return f64::NEG_INFINITY;
    }
    if x.is_infinite() {
        return x;
    }
    let mut k: i32 = 0;
    if x < two_pow(EXP_MIN) {
        x *= two_pow(SUBNORMAL_SCALE_BITS);
        k = -SUBNORMAL_SCALE_BITS;
    }
    let e = exponent(x);
    let mut m = if e == EXP_MAX {
        (x * HALF) * two_pow(1 - EXP_MAX)
    } else {
        x * two_pow(-e)
    };
    k += e;
    if m >= SQRT2 {
        m *= HALF;
        k += 1;
    }
    let f = m - 1.0;
    let s = f / (2.0 + f);
    let dk = k as f64;
    let z = s * s;
    let w = z * z;
    let t1 = w * (LG2 + w * (LG4 + w * LG6));
    let t2 = z * (LG1 + w * (LG3 + w * (LG5 + w * LG7)));
    let r = t2 + t1;
    let hfsq = HALF * f * f;
    dk * LN2_HI - ((hfsq - (s * (hfsq + r) + dk * LN2_LO)) - f)
}

/// x^y. Integer y (|y| <= 1024): repeated squaring (any sign of x); y = 0.5: sqrt;
/// otherwise exp(y log x) for x > 0, 0 or INF at x = 0, NaN for x < 0.
pub fn pow(x: f64, y: f64) -> f64 {
    if y == 0.0 {
        return 1.0;
    }
    if x.is_nan() || y.is_nan() {
        return f64::NAN;
    }
    if y == y.floor() && y.abs() <= POW_INT_MAX {
        let mut n = y.abs() as i64;
        let mut b = x;
        let mut acc = 1.0;
        while n > 0 {
            if (n & 1) == 1 {
                acc *= b;
            }
            n >>= 1;
            if n > 0 {
                b *= b;
            }
        }
        return if y < 0.0 { 1.0 / acc } else { acc };
    }
    if x < 0.0 {
        return f64::NAN;
    }
    if x == 0.0 {
        return if y > 0.0 { 0.0 } else { f64::INFINITY };
    }
    if x.is_infinite() {
        return if y > 0.0 { f64::INFINITY } else { 0.0 };
    }
    if y == HALF {
        return x.sqrt();
    }
    exp(y * log(x))
}

/// y × 2^n (musl scalbn's steps).
pub fn scalbn(mut y: f64, mut n: i32) -> f64 {
    if n > EXP_MAX {
        y *= two_pow(EXP_MAX);
        n -= EXP_MAX;
        if n > EXP_MAX {
            y *= two_pow(EXP_MAX);
            n -= EXP_MAX;
            n = n.min(EXP_MAX);
        }
    } else if n < EXP_MIN {
        y *= two_pow(-SCALBN_STEP);
        n += SCALBN_STEP;
        if n < EXP_MIN {
            y *= two_pow(-SCALBN_STEP);
            n += SCALBN_STEP;
            n = n.max(EXP_MIN);
        }
    }
    y * two_pow(n)
}

/// floor(log2(x)) for a normal positive finite x (the same binary search as the GDScript).
fn exponent(x: f64) -> i32 {
    let mut lo = EXP_MIN;
    let mut hi = EXP_MAX;
    while lo < hi {
        let mid = (lo + hi + 1) >> 1;
        if x >= two_pow(mid) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    lo
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn two_pow_is_exact() {
        let mut p = 1.0f64;
        for n in 0..=EXP_MAX {
            assert_eq!(two_pow(n), p);
            p *= 2.0;
        }
        let mut p = 1.0f64;
        for n in (EXP_MIN..=0).rev() {
            assert_eq!(two_pow(n), p);
            p *= 0.5;
        }
    }

    #[test]
    fn close_to_std() {
        for i in 0..2000 {
            let x = -6.0 + f64::from(i) * 0.006;
            assert!((sin(x) - x.sin()).abs() <= 2.3e-16);
            assert!((cos(x) - x.cos()).abs() <= 2.3e-16);
            assert!((atan(x) - x.atan()).abs() <= 4.5e-16);
            assert!((exp(x) - x.exp()).abs() <= 2.3e-16 * x.exp());
            let (s, c) = sin_cos(x);
            assert_eq!(s.to_bits(), sin(x).to_bits());
            assert_eq!(c.to_bits(), cos(x).to_bits());
        }
    }
}
