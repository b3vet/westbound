#!/usr/bin/env python3
"""Westbound audio assets: offline synthesis and CC0 imports (WP7A). docs/AUDIO.md.

    pip install numpy soundfile          # soundfile's wheel bundles libsndfile + Vorbis
    python3 tools/audio/gen_audio.py synth          # in-house synthesized SFX -> assets/audio/
    python3 tools/audio/gen_audio.py cc0            # download + convert the CC0 files
    python3 tools/audio/gen_audio.py all

Everything is deterministic (fixed numpy seeds), mono OGG Vorbis at 22.05 kHz for the
effects, and 32 kHz stereo for music, to keep the web pack small. Loops are built
periodic (FFT noise with integer bins, whole engine cycles), so they loop seamlessly.

Engine loops: one file per RPM step, on and off throttle. The step rpm values are
exact (22050 * 120 / rpm is a whole number of samples per engine cycle); they are
mirrored in data/tuning/audio.tres (engine_step_rpm) and printed by `synth`.
"""
import io
import os
import sys
import urllib.request
import zipfile

import numpy as np
import soundfile as sf

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "assets", "audio")
CACHE = os.path.join(os.path.expanduser("~"), ".cache", "westbound", "audio_src")
SR = 22050
MUSIC_SR = 32000
TAU = 2.0 * np.pi

# Engine rpm steps: 22050 * 120 / rpm samples per 4-stroke cycle, all whole numbers.
ENGINE_STEPS = [900, 1575, 2450, 3500, 4900, 7000]
CYLINDERS = 8
ENGINE_LOOP_S = 2.0

# ------------------------------------------------------------------ CC0 sources
KENNEY = {
    "impact-sounds": "https://kenney.nl/media/pages/assets/impact-sounds/87b4ddecda-1677589768/kenney_impact-sounds.zip",
    "interface-sounds": "https://kenney.nl/media/pages/assets/interface-sounds/fa43c1dd4d-1677589452/kenney_interface-sounds.zip",
}
# (out name, pack, file inside Audio/, gain)
KENNEY_FILES = [
    ("hit_impact", "impact-sounds", "impactMetal_heavy_001.ogg", 1.0),
    ("crash_metal", "impact-sounds", "impactPlate_heavy_000.ogg", 1.0),
    ("crash_glass", "impact-sounds", "impactGlass_heavy_000.ogg", 1.0),
    ("scrape", "impact-sounds", "impactMetal_light_002.ogg", 1.0),
    ("ui_click", "interface-sounds", "click_002.ogg", 1.0),
]
# (out name, url) OpenGameArt, CC0
MUSIC = [
    ("music_midnight_drive", "https://opengameart.org/sites/default/files/midnight_drive.ogg"),
    ("music_cyber_runner", "https://opengameart.org/sites/default/files/cyber_runner.ogg"),
    ("music_slampe", "https://opengameart.org/sites/default/files/slampe_0.ogg"),
]
MUSIC_QUALITY = 0.9   # libsndfile Vorbis compression level (0 best .. 1 smallest)
SFX_QUALITY = 0.6


# ------------------------------------------------------------------ helpers

def write(name, x, sr=SR, quality=SFX_QUALITY):
    x = np.asarray(x, dtype=np.float32)
    path = os.path.join(OUT, name + ".ogg")
    ch = 1 if x.ndim == 1 else x.shape[1]
    # libsndfile's Vorbis encoder crashes on very large single writes: write in blocks.
    with sf.SoundFile(path, "w", sr, ch, format="OGG", subtype="VORBIS", compression_level=quality) as f:
        for i in range(0, len(x), 8192):
            f.write(x[i:i + 8192])
    print("  %-26s %6.2f s  %7d bytes" % (name + ".ogg", len(x) / sr, os.path.getsize(path)))


def norm(x, peak=0.89):
    m = np.max(np.abs(x))
    return x if m == 0 else x * (peak / m)


def norm_rms(x, rms=0.2, peak=0.95):
    r = np.sqrt(np.mean(x * x))
    y = x * (rms / r) if r > 0 else x
    m = np.max(np.abs(y))
    return y * (peak / m) if m > peak else y


def periodic_noise(n, rng, shape):
    """Noise that loops seamlessly over n samples: random phases, |X(f)| = shape(f)."""
    f = np.fft.rfftfreq(n, 1.0 / SR)
    mag = shape(np.maximum(f, 1e-3))
    mag[0] = 0.0
    ph = rng.uniform(0, TAU, len(f))
    return np.fft.irfft(mag * np.exp(1j * ph), n)


def fft_filter(x, shape):
    """Zero-phase filter by an FFT magnitude mask (circular: fine for loops, pad one-shots)."""
    n = len(x)
    f = np.fft.rfftfreq(n, 1.0 / SR)
    return np.fft.irfft(np.fft.rfft(x) * shape(np.maximum(f, 1e-3)), n)


def bandpass_shape(lo, hi, slope=2.0):
    return lambda f: 1.0 / (1.0 + (lo / f) ** (2 * slope)) / (1.0 + (f / hi) ** (2 * slope))


def svf(x, cutoff, q=0.7, mode="bp"):
    """Chamberlin state-variable filter with a per-sample cutoff (Hz) array."""
    cutoff = np.broadcast_to(np.asarray(cutoff, dtype=np.float64), x.shape)
    low = band = 0.0
    out = np.empty_like(x)
    damp = 1.0 / q
    for i in range(len(x)):
        fc = min(cutoff[i], SR * 0.22)
        k = 2.0 * np.sin(np.pi * fc / SR)
        low += k * band
        high = x[i] - low - damp * band
        band += k * high
        out[i] = band if mode == "bp" else (low if mode == "lp" else high)
    return out


def env_ar(n, attack_s, release_s, peak_s=None, curve=3.0):
    t = np.arange(n) / SR
    peak_s = attack_s if peak_s is None else peak_s
    a = np.clip(t / max(attack_s, 1e-4), 0, 1) ** 1.5
    r = np.exp(-np.maximum(t - peak_s, 0) / max(release_s, 1e-4) * curve / 3.0)
    return a * r


def fade(x, fin_s=0.002, fout_s=0.02):
    n = len(x)
    a = min(n, int(fin_s * SR))
    b = min(n, int(fout_s * SR))
    y = x.copy()
    if a > 0:
        y[:a] *= np.linspace(0, 1, a)
    if b > 0:
        y[-b:] *= np.linspace(1, 0, b)
    return y


def tone(freq, n, harmonics=((1, 1.0),), phase=0.0):
    t = np.arange(n) / SR
    y = np.zeros(n)
    for h, a in harmonics:
        y += a * np.sin(TAU * freq * h * t + phase * h)
    return y


def sweep_tone(f0, f1, n, harmonics=((1, 1.0),), curve="exp"):
    if curve == "exp":
        f = f0 * (f1 / f0) ** np.linspace(0, 1, n)
    else:
        f = np.linspace(f0, f1, n)
    ph = np.cumsum(TAU * f / SR)
    y = np.zeros(n)
    for h, a in harmonics:
        y += a * np.sin(ph * h)
    return y


def pluck(freq, dur, bright=0.5, decay=6.0):
    """Additive pluck: harmonics decaying faster the higher they are."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    y = np.zeros(n)
    for h in range(1, 9):
        a = (bright ** (h - 1)) / h
        y += a * np.sin(TAU * freq * h * t) * np.exp(-t * decay * (1 + 0.35 * (h - 1)))
    return fade(y, 0.001, 0.01)


def bell(freq, dur, decay=3.5):
    n = int(dur * SR)
    t = np.arange(n) / SR
    partials = ((1.0, 1.0), (2.0, 0.5), (2.76, 0.35), (5.4, 0.18), (8.93, 0.08))
    y = np.zeros(n)
    for r, a in partials:
        y += a * np.sin(TAU * freq * r * t) * np.exp(-t * decay * (0.6 + 0.4 * r))
    return fade(y, 0.001, 0.02)


def note(semi, base=523.25):
    return base * 2.0 ** (semi / 12.0)


def place(dst, src, at_s, gain=1.0):
    i = int(at_s * SR)
    j = min(len(dst), i + len(src))
    dst[i:j] += src[: j - i] * gain


# ------------------------------------------------------------------ engine

def engine_loop(rpm, on, rng):
    cycle = SR * 120 // rpm            # samples per 4-stroke cycle (exact for ENGINE_STEPS)
    assert cycle * rpm == SR * 120, rpm
    cycles = max(1, int(round(ENGINE_LOOP_S * SR / cycle)))
    n = cycle * cycles
    # One engine cycle: a pressure pulse per firing, slightly uneven (the V8 burble).
    offs = np.array([0.0, 0.07, -0.04, 0.05, -0.06, 0.03, -0.02, 0.04])
    amps = np.array([1.0, 0.82, 0.93, 0.78, 1.05, 0.86, 0.95, 0.8])
    pulses = np.zeros(cycle)
    for c in range(CYLINDERS):
        pos = int(((c + offs[c]) / CYLINDERS) % 1.0 * cycle)
        pulses[pos] += amps[c] * (1.0 if on else 0.55)
    # Exhaust response (circular within one cycle, so the loop stays exact).
    t = np.arange(cycle) / SR
    rel = 0.7 if on else 1.0
    ir = (np.exp(-t / (0.006 * rel)) * np.sin(TAU * 120 * t) * 1.0
          + np.exp(-t / (0.003 * rel)) * np.sin(TAU * 420 * t) * (0.7 if on else 0.3)
          + np.exp(-t / (0.0012)) * np.sin(TAU * 1500 * t) * (0.35 if on else 0.08))
    one = np.real(np.fft.ifft(np.fft.fft(pulses) * np.fft.fft(ir)))
    y = np.tile(one, cycles)
    # Firing-modulated combustion / intake noise (periodic over the loop).
    fire = np.tile(np.real(np.fft.ifft(np.fft.fft(pulses) * np.fft.fft(np.exp(-t / 0.004)))), cycles)
    fire = np.maximum(fire, 0)
    noise = periodic_noise(n, rng, bandpass_shape(300, 3500 if on else 1400, 1.5))
    noise /= np.std(noise) + 1e-9
    y = y / (np.std(y) + 1e-9)
    y = y + noise * fire / (np.max(fire) + 1e-9) * (0.55 if on else 0.25)
    # Low rumble at the cycle (half-order) frequency.
    k = np.arange(n)
    y += 0.35 * np.sin(TAU * k * cycles / n) + 0.25 * np.sin(TAU * k * cycles * 2 / n)
    if not on:
        y = fft_filter(y, lambda f: 1.0 / (1.0 + (f / 900.0) ** 2))
    # Soft saturation for grit, then loudness normalized (tuning sets the mix).
    y = np.tanh(y * (1.4 if on else 0.9))
    return norm_rms(y - np.mean(y), 0.22)


# ------------------------------------------------------------------ SFX

def wind_loop(rng):
    n = int(4.0 * SR)
    x = periodic_noise(n, rng, lambda f: (1.0 / np.sqrt(f)) / (1.0 + (f / 1800.0) ** 2) / (1.0 + (60.0 / f) ** 2))
    x /= np.std(x)
    whistle = periodic_noise(n, rng, bandpass_shape(650, 900, 4.0))
    whistle /= np.std(whistle)
    k = np.arange(n) / n
    gust = 0.75 + 0.15 * np.sin(TAU * 1 * k) + 0.1 * np.sin(TAU * 3 * k + 1.3)
    y = x * gust + 0.25 * whistle * (0.6 + 0.4 * np.sin(TAU * 2 * k + 0.4))
    return norm_rms(y, 0.2)


def tire_hum_loop(rng):
    n = int(2.0 * SR)
    rumble = periodic_noise(n, rng, lambda f: 1.0 / f / (1.0 + (f / 350.0) ** 4) / (1.0 + (30.0 / f) ** 4))
    rumble /= np.std(rumble)
    k = np.arange(n)
    # Tread whine: tonal, locked to whole cycles of the loop.
    whine = sum(a * np.sin(TAU * k * h * 360 / n) for h, a in ((1, 1.0), (2, 0.4), (3, 0.2)))
    whine *= 0.8 + 0.2 * np.sin(TAU * k * 3 / n)
    hiss = periodic_noise(n, rng, bandpass_shape(1500, 4000, 2.0))
    hiss /= np.std(hiss)
    y = rumble + 0.35 * whine + 0.12 * hiss
    return norm_rms(y, 0.2)


def intake_loop(rng):
    n = int(2.0 * SR)
    x = periodic_noise(n, rng, bandpass_shape(180, 1600, 1.5))
    x /= np.std(x)
    k = np.arange(n)
    pulse = 0.7 + 0.3 * np.sin(TAU * k * 60 / n)   # 30 Hz growl
    y = np.tanh(1.5 * x * pulse) + 0.3 * np.sin(TAU * k * 110 / n)
    return norm_rms(y, 0.2)


def whoosh(rng, dur=1.1):
    n = int(dur * SR)
    t = np.arange(n) / SR
    peak = 0.28 * dur
    x = rng.standard_normal(n)
    # Passing car: the band rises on approach and falls after (doppler), loudest at the peak.
    fc = np.where(t < peak, 700 + 1900 * (t / peak) ** 2, 2600 * np.exp(-(t - peak) / (0.25 * dur)) + 450)
    y = svf(x, fc, q=1.2, mode="bp")
    body = svf(x, 180 + 250 * np.exp(-np.abs(t - peak) / 0.12), q=0.8, mode="lp")
    env = np.exp(-((t - peak) / np.where(t < peak, 0.13 * dur, 0.28 * dur)) ** 2)
    y = (y + 0.6 * body) * env
    return norm(fade(y, 0.005, 0.05))


def zip_sfx(rng):
    n = int(0.32 * SR)
    t = np.arange(n) / SR
    x = rng.standard_normal(n)
    fc = 7000 * np.exp(-t / 0.09) + 1400
    y = svf(x, fc, q=3.0, mode="bp")
    buzz = sweep_tone(220, 120, n, ((1, 1.0), (2, 0.5), (3, 0.33), (4, 0.25)))
    y = (y + 0.25 * buzz) * env_ar(n, 0.004, 0.08)
    return norm(fade(y, 0.001, 0.02))


def thump(rng):
    n = int(0.5 * SR)
    t = np.arange(n) / SR
    body = sweep_tone(95, 38, n) * np.exp(-t / 0.13)
    click = svf(rng.standard_normal(n), 1200, q=0.7, mode="lp") * np.exp(-t / 0.012)
    y = np.tanh(1.8 * (body + 0.4 * click))
    return norm(fade(y, 0.001, 0.03))


def horn(rng):
    n = int(0.75 * SR)
    t = np.arange(n) / SR
    y = np.zeros(n)
    for f in (415.0, 523.0):
        y += np.sign(np.sin(TAU * f * t)) * 0.5 + np.sin(TAU * f * t)
    y = fft_filter(y, lambda f: 1.0 / (1.0 + (f / 2500.0) ** 2) / (1.0 + (250.0 / f) ** 2))
    y *= np.clip(t / 0.02, 0, 1) * np.clip((0.75 - t) / 0.06, 0, 1)
    return norm(np.tanh(1.3 * y) * 0.9)


def air_brake(rng):
    n = int(1.1 * SR)
    t = np.arange(n) / SR
    x = rng.standard_normal(n)
    hiss = fft_filter(np.concatenate([x, np.zeros(2048)]), lambda f: 1.0 / (1.0 + (2500.0 / f) ** 4))[:n]
    env = np.clip(t / 0.015, 0, 1) * np.exp(-t / 0.35)
    chuff = svf(rng.standard_normal(n), 300, q=0.8, mode="lp") * np.exp(-t / 0.03)
    return norm(fade(hiss * env + 0.8 * chuff, 0.001, 0.05))


def boost_whoosh(rng):
    n = int(1.3 * SR)
    t = np.arange(n) / SR
    x = rng.standard_normal(n)
    y = svf(x, 400 + 3200 * (t / t[-1]) ** 1.5, q=1.5, mode="bp")
    boom = sweep_tone(60, 110, n) * np.exp(-t / 0.35)
    env = np.clip(t / 0.35, 0, 1) ** 2 * np.exp(-np.maximum(t - 0.5, 0) / 0.3)
    return norm(fade(y * env + 0.5 * boom * np.clip(t / 0.05, 0, 1), 0.002, 0.08))


# ------------------------------------------------------------------ stingers (musical)

def sting_pass():
    return norm(pluck(note(0), 0.35, 0.45, 9.0), 0.7)


def sting_close():
    n = int(0.45 * SR)
    y = np.zeros(n)
    place(y, pluck(note(0), 0.3, 0.6, 8.0), 0.0)
    place(y, pluck(note(7), 0.35, 0.65, 7.0), 0.06)
    return norm(y, 0.75)


def sting_cut():
    n = int(0.16 * SR)
    t = np.arange(n) / SR
    y = np.sign(np.sin(TAU * note(12) * t)) * np.exp(-t / 0.04) * 0.5 + tone(note(12), n) * np.exp(-t / 0.05)
    y = fft_filter(y, lambda f: 1.0 / (1.0 + (f / 4000.0) ** 2))
    return norm(fade(y, 0.001, 0.01), 0.6)


def sting_thread():
    n = int(0.7 * SR)
    y = np.zeros(n)
    for i, s in enumerate((0, 4, 7, 12)):
        place(y, pluck(note(s), 0.45, 0.7, 6.0), i * 0.055)
    return norm(y, 0.8)


def chime_tick():
    return norm(bell(note(12), 0.14, 14.0), 0.5)


def chime_bank():
    n = int(1.2 * SR)
    y = np.zeros(n)
    for i, s in enumerate((12, 16, 19, 24)):
        place(y, bell(note(s), 1.0, 3.0), i * 0.04, 1.0 / (1 + 0.3 * i))
    return norm(y, 0.8)


def sting_hesitated():
    n = int(0.7 * SR)
    t = np.arange(n) / SR
    y = np.zeros(n)
    for f0, f1, at in ((note(-5), note(-6), 0.0), (note(-8), note(-11), 0.22)):
        m = int(0.42 * SR)
        tt = np.arange(m) / SR
        vib = 1.0 + 0.012 * np.sin(TAU * 6.0 * tt)
        seg = sweep_tone(f0, f1, m, ((1, 1.0), (2, 0.5), (3, 0.33), (4, 0.2)), "lin") * vib
        seg *= np.clip(tt / 0.01, 0, 1) * np.exp(-tt / 0.25)
        place(y, seg, at)
    y = fft_filter(y, lambda f: 1.0 / (1.0 + (f / 1800.0) ** 2))
    return norm(fade(y, 0.001, 0.03), 0.75)


def sting_hit(rng):
    n = int(0.6 * SR)
    t = np.arange(n) / SR
    y = np.zeros(n)
    for s in (-24, -23, -18):
        y += sweep_tone(note(s), note(s) * 0.94, n, ((1, 1.0), (2, 0.5), (3, 0.33), (5, 0.2)))
    y *= np.exp(-t / 0.18)
    y += 0.5 * svf(rng.standard_normal(n), 900, q=0.7, mode="lp") * np.exp(-t / 0.04)
    return norm(np.tanh(1.5 * y), 0.85)


def synth():
    os.makedirs(OUT, exist_ok=True)
    print("synth -> assets/audio/")
    for rpm in ENGINE_STEPS:
        write("engine_on_%d" % rpm, engine_loop(rpm, True, np.random.default_rng(rpm)))
        write("engine_off_%d" % rpm, engine_loop(rpm, False, np.random.default_rng(rpm + 1)))
    write("wind_loop", wind_loop(np.random.default_rng(11)))
    write("tire_hum_loop", tire_hum_loop(np.random.default_rng(12)))
    write("intake_loop", intake_loop(np.random.default_rng(13)))
    write("whoosh", whoosh(np.random.default_rng(21)))
    write("zip", zip_sfx(np.random.default_rng(22)))
    write("thump", thump(np.random.default_rng(23)))
    write("horn", horn(np.random.default_rng(24)))
    write("air_brake", air_brake(np.random.default_rng(25)))
    write("boost_whoosh", boost_whoosh(np.random.default_rng(26)))
    write("sting_pass", sting_pass())
    write("sting_close", sting_close())
    write("sting_cut", sting_cut())
    write("sting_thread", sting_thread())
    write("chime_tick", chime_tick())
    write("chime_bank", chime_bank())
    write("sting_hesitated", sting_hesitated())
    write("sting_hit", sting_hit(np.random.default_rng(31)))
    print("engine_step_rpm =", ENGINE_STEPS)


# ------------------------------------------------------------------ CC0 imports

def fetch(url):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, url.rsplit("/", 1)[-1])
    if not os.path.exists(path):
        print("  download", url)
        with urllib.request.urlopen(url, timeout=120) as r, open(path, "wb") as f:
            f.write(r.read())
    return path


def resample(x, sr_from, sr_to):
    if sr_from == sr_to:
        return x
    n_out = int(round(len(x) * sr_to / sr_from))
    if x.ndim == 1:
        return np.fft.irfft(np.fft.rfft(x)[: n_out // 2 + 1], n_out) * (n_out / len(x))
    return np.stack([resample(x[:, c], sr_from, sr_to) for c in range(x.shape[1])], axis=1)


def cc0():
    os.makedirs(OUT, exist_ok=True)
    print("cc0 -> assets/audio/")
    for name, pack, fname, gain in KENNEY_FILES:
        z = zipfile.ZipFile(fetch(KENNEY[pack]))
        member = next(m for m in z.namelist() if m.endswith("/" + fname) or m == fname)
        x, sr = sf.read(io.BytesIO(z.read(member)), dtype="float64")
        if x.ndim == 2:
            x = x.mean(axis=1)
        write(name, norm(resample(x, sr, SR)) * gain)
    for name, url in MUSIC:
        x, sr = sf.read(fetch(url), dtype="float64")
        write(name, norm(resample(x, sr, MUSIC_SR), 0.95), MUSIC_SR, MUSIC_QUALITY)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "all"
    if cmd in ("synth", "all"):
        synth()
    if cmd in ("cc0", "all"):
        cc0()
    if cmd not in ("synth", "cc0", "all"):
        print(__doc__)
        sys.exit(2)
