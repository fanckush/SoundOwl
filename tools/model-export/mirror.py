"""The native pipeline in NumPy + ONNX Runtime, checked against the golden fixtures.

    uv run python mirror.py

This is the executable spec for the Swift engine: every step here has a Swift twin, and when the
two disagree this file is the one that is known to match upstream.
"""

import json
import math
import sys
from pathlib import Path

import numpy as np
import onnxruntime as ort
import soundfile as sf

from make_fixtures import FIXTURES

PACKAGE = Path(__file__).parent / "build" / "lavasr-v2"


def hann(n):
    """Periodic Hann, as torch.hann_window(n)."""
    return (0.5 - 0.5 * np.cos(2 * np.pi * np.arange(n) / n)).astype(np.float32)


def resample_kernel(orig, new, width_zeros=6, rolloff=0.99):
    """torchaudio's sinc_interp_hann kernel for orig -> new (already divided by their gcd)."""
    base = min(orig, new) * rolloff
    width = math.ceil(width_zeros * orig / base)
    idx = np.arange(-width, width + orig, dtype=np.float64) / orig
    t = (np.arange(0, -new, -1, dtype=np.float32)[:, None] / new + idx).astype(np.float32)
    t *= base
    t = np.clip(t, -width_zeros, width_zeros)
    window = np.cos(t * np.pi / width_zeros / 2) ** 2
    t *= np.pi
    with np.errstate(invalid="ignore", divide="ignore"):
        k = np.where(t == 0, 1.0, np.sin(t) / t)
    return (k * window * (base / orig)).astype(np.float32), width


def resample(x, orig, new):
    g = math.gcd(orig, new)
    o, n = orig // g, new // g
    k, width = resample_kernel(o, n)
    padded = np.pad(x, (width, width + o))
    taps = k.shape[1]
    steps = (len(padded) - taps) // o + 1
    frames = np.lib.stride_tricks.as_strided(
        padded, (steps, taps), (padded.strides[0] * o, padded.strides[0])
    )
    y = (frames @ k.T).reshape(-1)  # (steps, new) -> interleaved
    return y[: math.ceil(n * len(x) / o)].astype(np.float32)


def frames_of(x, n_fft, hop):
    count = 1 + (len(x) - n_fft) // hop
    return np.lib.stride_tricks.as_strided(x, (count, n_fft), (x.strides[0] * hop, x.strides[0]))


def overlap_add(frames, hop, window):
    """Windowed overlap-add of (T, n_fft) frames, divided by the summed squared window."""
    count, n_fft = frames.shape
    size = (count - 1) * hop + n_fft
    y = np.zeros(size, np.float32)
    env = np.zeros(size, np.float32)
    for i in range(count):
        y[i * hop : i * hop + n_fft] += frames[i] * window
        env[i * hop : i * hop + n_fft] += window**2
    return y, env


def bwe(session, x48, n_fft=2048, hop=512):
    pad = (n_fft - hop) // 2
    w = hann(n_fft)
    padded = np.pad(x48, (pad, pad), mode="reflect")
    mag = np.abs(np.fft.rfft(frames_of(padded, n_fft, hop) * w, axis=1)).astype(np.float32)
    real, imag = session.run(None, {"magnitude": mag.T[None]})
    spec = (real[0] + 1j * imag[0]).T  # (T, F)
    frames = np.fft.irfft(spec, n_fft, axis=1).astype(np.float32)
    y, env = overlap_add(frames, hop, w)
    return y[pad:-pad] / env[pad:-pad]


def denoise(session, x16, n_fft=512, hop=256):
    w = hann(n_fft)
    padded = np.pad(x16, (n_fft // 2, n_fft // 2), mode="reflect")
    spec = np.fft.rfft(frames_of(padded, n_fft, hop) * w, axis=1)  # (T, F)
    stacked = np.stack([spec.real, spec.imag]).astype(np.float32)[None]  # (1, 2, T, F)
    (enhanced,) = session.run(None, {"spec": stacked})
    spec = enhanced[0, 0] + 1j * enhanced[0, 1]
    frames = np.fft.irfft(spec, n_fft, axis=1).astype(np.float32)
    y, env = overlap_add(frames, hop, w)
    start, length = n_fft // 2, hop * (len(frames) - 1)
    y = y[start : start + length] / env[start : start + length]
    return np.pad(y, (0, len(x16) - len(y)))


def merge(pred, orig, cutoff, transition_bins=1024, rate=48000):
    """FastLRMerge: original below the cutoff, prediction above, smoothstep between."""
    a, b = np.fft.rfft(pred), np.fft.rfft(orig)
    n = len(a)
    cutoff_bin = int((cutoff / (rate / 2)) * n)
    half = transition_bins // 2
    start, end = max(0, cutoff_bin - half), min(n, cutoff_bin + half)
    t = (np.linspace(-1, 1, transition_bins, dtype=np.float32) + 1) / 2
    fade = (3 * t**2 - 2 * t**3)[: end - start]
    mask = np.ones(n, np.float32)
    mask[:start] = 0
    mask[start:end] = fade
    return np.fft.irfft(b + (a - b) * mask, n=len(pred)).astype(np.float32)


def enhance(sessions, x16, cutoff, denoise_on):
    if denoise_on:
        x16 = denoise(sessions["denoiser"], x16)
    x48 = resample(x16, 16000, 48000)
    pred = bwe(sessions["bwe"], x48)
    n = min(len(pred), len(x48))
    return merge(pred[:n], x48[:n], cutoff)


def snr_db(want, got):
    err = np.sum((want - got) ** 2)
    return float("inf") if err == 0 else 10 * np.log10(np.sum(want**2) / err + 1e-30)


def main():
    sessions = {
        name: ort.InferenceSession(str(PACKAGE / f"{name}.onnx"), providers=["CPUExecutionProvider"])
        for name in ("bwe", "denoiser")
    }
    index = json.loads((FIXTURES / "fixtures.json").read_text())
    ok = True
    for name, spec in index.items():
        x, _ = sf.read(FIXTURES / f"{name}.in.wav", dtype="float32")
        want, _ = sf.read(FIXTURES / f"{name}.out.wav", dtype="float32")
        got = enhance(sessions, x, spec["cutoffHz"], spec["denoise"])
        same_length = len(got) == len(want)
        n = min(len(got), len(want))
        err = float(np.abs(got[:n] - want[:n]).max())
        snr = snr_db(want[:n], got[:n])
        passed = same_length and (snr > 60 or err < 1e-4)
        ok &= passed
        print(f"{'ok  ' if passed else 'FAIL'} {name}: len {len(got)}/{len(want)}, max err {err:.2e}, snr {snr:.1f} dB")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
