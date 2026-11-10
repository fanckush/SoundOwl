"""Builds the before/after samples on the SoundOwl website.

A public-domain LibriVox reading is degraded three ways (phone line, low-bitrate podcast, noisy
room), restored with the app's own engine (soundowl-dev), and written to site/samples/ as AAC plus
a spectrogram of each side. The degradations are simulated, and the site says so.

    curl -fLO https://archive.org/download/alice_in_wonderland_librivox/wonderland_ch_01_64kb.mp3
    swift build -c release --product soundowl-dev
    uv run --project tools/model-export python scripts/site-samples.py wonderland_ch_01_64kb.mp3
"""

from __future__ import annotations

import json
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
import torchaudio.functional as AF
from scipy.signal import butter, sosfilt

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "site" / "samples"
CLI = ROOT / ".build" / "release" / "soundowl-dev"
RATE = 48_000

# (id, title, what was done, start s, end s), cut at pauses in chapter 1.
SAMPLES = [
    ("podcast", "Old podcast", "Squeezed into a 24 kbps, 16 kHz AAC file.", 109.08, 122.68),
    ("noisy", "Noisy room", "Recorded at 16 kHz with fan noise and mains hum. Restored with Reduce background noise on.",
     143.9, 158.33),
    ("phone", "Phone call", "Sent through an 8 kHz phone line.", 64.15, 79.0),
]


def resample(x: np.ndarray, src: int, dst: int) -> np.ndarray:
    return AF.resample(torch.from_numpy(x).float(), src, dst).numpy()


def phone(x: np.ndarray, sr: int) -> tuple[np.ndarray, int]:
    y = resample(x, sr, 8000)
    y = sosfilt(butter(4, [300, 3400], btype="band", fs=8000, output="sos"), y)
    # G.711 µ-law, as on a real line.
    t = torch.from_numpy(np.clip(y, -1, 1)).float()
    y = AF.mu_law_decoding(AF.mu_law_encoding(t, 256), 256).numpy()
    return y, 8000


def podcast(x: np.ndarray, sr: int, work: Path) -> tuple[np.ndarray, int]:
    y = resample(x, sr, 16000)
    sf.write(work / "pod.wav", y, 16000, subtype="PCM_16")
    run("afconvert", "-f", "m4af", "-d", "aac@16000", "-b", "24000", work / "pod.wav", work / "pod.m4a")
    run("afconvert", "-f", "WAVE", "-d", "LEF32@16000", work / "pod.m4a", work / "pod-dec.wav")
    z, _ = sf.read(work / "pod-dec.wav", dtype="float32")
    return z[: len(y)], 16000


def noisy(x: np.ndarray, sr: int) -> tuple[np.ndarray, int]:
    y = resample(x, sr, 16000)
    rng = np.random.default_rng(7)
    # Fan: brownish noise. Hum: 50 Hz and harmonics.
    fan = np.cumsum(rng.standard_normal(len(y)))
    fan = sosfilt(butter(2, 40, btype="high", fs=16000, output="sos"), fan)
    fan *= np.sqrt(np.mean(y**2)) / np.sqrt(np.mean(fan**2)) * 10 ** (-12 / 20)
    t = np.arange(len(y)) / 16000
    hum = sum(0.004 / k * np.sin(2 * np.pi * 50 * k * t) for k in (1, 2, 3, 5))
    return (y + fan + hum).astype(np.float32), 16000


def run(*args: object) -> None:
    subprocess.run([str(a) for a in args], check=True, capture_output=True)


def encode(y: np.ndarray, path: Path, work: Path) -> None:
    sf.write(work / "enc.wav", y, RATE, subtype="FLOAT")
    run("afconvert", "-f", "m4af", "-d", "aac@48000", "-b", "160000", "-q", "127", work / "enc.wav", path)


# --- Spectrogram -----------------------------------------------------------------------------

# Night blue through indigo to the app's amber and a pale moon yellow.
STOPS = [(0.0, (12, 22, 48)), (0.35, (40, 52, 110)), (0.62, (150, 70, 120)), (0.82, (245, 158, 46)),
         (1.0, (255, 236, 190))]


def colormap(v: np.ndarray) -> np.ndarray:
    out = np.zeros(v.shape + (3,))
    for (a, ca), (b, cb) in zip(STOPS, STOPS[1:]):
        m = (v >= a) & (v <= b)
        f = ((v - a) / (b - a))[m][:, None]
        out[m] = np.array(ca) * (1 - f) + np.array(cb) * f
    return out.astype(np.uint8)


def spectrogram(y: np.ndarray, width: int = 1400, height: int = 420) -> np.ndarray:
    n, hop = 2048, 256
    win = np.hanning(n)
    frames = np.lib.stride_tricks.sliding_window_view(np.pad(y, n // 2), n)[::hop] * win
    mag = np.abs(np.fft.rfft(frames, axis=1)).T  # freq × time
    db = 20 * np.log10(mag + 1e-7)
    # Speech falls off steeply with frequency. Tilt the display (about 4.5 dB per octave above
    # 500 Hz), as speech spectrograms usually are, so the upper band is visible at all.
    freqs = np.fft.rfftfreq(n, 1 / RATE)
    db += 15 * np.log10(np.maximum(freqs, 500) / 500)[:, None]
    db = np.clip((db - (db.max() - 75)) / 75, 0, 1)
    # Linear frequency axis: the empty top half of a muffled recording is the point.
    rows = np.linspace(mag.shape[0] - 1, 0, height).astype(int)
    cols = np.linspace(0, mag.shape[1] - 1, width).astype(int)
    return colormap(db[rows][:, cols] ** 1.2)


def write_png(rgb: np.ndarray, path: Path) -> None:
    h, w, _ = rgb.shape
    raw = b"".join(b"\0" + rgb[r].tobytes() for r in range(h))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    path.write_bytes(png)


def main() -> None:
    source = Path(sys.argv[1])
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = []
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        run("afconvert", "-f", "WAVE", "-d", "LEF32@24000", "-c", "1", source, work / "source.wav")
        full, sr = sf.read(work / "source.wav", dtype="float32")
        for sample_id, title, detail, start, end in SAMPLES:
            x = full[int(start * sr) : int(end * sr)]
            if sample_id == "phone":
                degraded, rate = phone(x, sr)
            elif sample_id == "podcast":
                degraded, rate = podcast(x, sr, work)
            else:
                degraded, rate = noisy(x, sr)
            degraded = degraded / max(1.0, np.abs(degraded).max() / 0.98)
            sf.write(work / "in.wav", degraded, rate, subtype="FLOAT")
            flags = ["--denoise"] if sample_id == "noisy" else []
            run(CLI, "restore", work / "in.wav", work / "out.wav", *flags)
            after, _ = sf.read(work / "out.wav", dtype="float32")

            # Same rate and length for sample-accurate switching, and the same loudness so the
            # comparison is about clarity, as in the app.
            before = resample(degraded, rate, RATE)
            count = min(len(before), len(after))
            before, after = before[:count], after[:count]
            before *= np.sqrt(np.mean(after**2) / max(np.mean(before**2), 1e-12))
            peak = max(np.abs(before).max(), np.abs(after).max())
            if peak > 0.98:
                before, after = before * 0.98 / peak, after * 0.98 / peak

            for side, y in (("before", before), ("after", after)):
                encode(y, OUT / f"{sample_id}-{side}.m4a", work)
                write_png(spectrogram(y), work / "spec.png")
                run("cwebp", "-quiet", "-q", "82", work / "spec.png", "-o", OUT / f"{sample_id}-{side}.webp")
            manifest.append({"id": sample_id, "title": title, "detail": detail, "seconds": round(count / RATE, 2)})
            print(f"{sample_id}: {count / RATE:.1f} s")
    (OUT / "samples.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
