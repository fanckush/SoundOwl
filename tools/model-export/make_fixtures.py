"""Renders the golden fixtures: upstream LavaSR v2 output for a handful of short speech clips.

    uv run python make_fixtures.py

Speech comes from macOS `say`, so the inputs are reproducible and carry no licensing baggage.
The parity boundary is the 16 kHz mono signal handed to `LavaEnhance.enhance`: each fixture stores
that signal and the 48 kHz upstream output, and the native engine must turn one into the other.
"""

import json
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
import torchaudio

from lava import load_upstream

FIXTURES = Path(__file__).parents[2] / "Tests" / "Fixtures" / "lavasr-v2"

TEXT = (
    "She sells sea shells by the sea shore, and the shells she sells are surely seashells. "
    "Six thick thistle sticks."
)

# name: (voice, text, input_sr, denoise, noise_snr_db, seconds)
CLIPS = {
    "speech-16k": ("Samantha", TEXT, 16000, False, None, None),
    "phone-8k": ("Daniel", TEXT, 8000, False, None, None),
    "noisy-16k-denoise": ("Samantha", TEXT, 16000, True, 10, None),
    "short": ("Fred", "Hi.", 16000, False, None, 0.25),
    "silence": (None, None, 16000, False, None, 1.0),
}


def say(voice, text):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "say.wav"
        subprocess.run(
            ["say", "-v", voice, "-o", str(path), "--file-format=WAVE", "--data-format=LEF32@48000", text],
            check=True,
        )
        wav, sr = sf.read(path, dtype="float32")
    assert sr == 48000
    return torch.from_numpy(wav)


def to_model_input(wav48, input_sr):
    """What upstream `load_wav` does after decoding: down to the source rate, then to 16 kHz."""
    x = torchaudio.functional.resample(wav48, 48000, input_sr)
    return torchaudio.functional.resample(x, input_sr, 16000).unsqueeze(0)


def main():
    lava, _ = load_upstream()
    FIXTURES.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(7)
    index = {}

    for name, (voice, text, input_sr, denoise, snr_db, seconds) in CLIPS.items():
        if voice is None:
            wav48 = torch.zeros(int(48000 * seconds))
        else:
            wav48 = say(voice, text)
            if seconds is not None:
                wav48 = wav48[: int(48000 * seconds)]
        if snr_db is not None:
            noise = rng.standard_normal(wav48.shape[0]).astype(np.float32)
            noise *= wav48.square().mean().sqrt().item() / 10 ** (snr_db / 20)
            wav48 = wav48 + torch.from_numpy(noise)

        x = to_model_input(wav48, input_sr)
        cutoff = input_sr // 2
        lava.bwe_model.lr_refiner = type(lava.bwe_model.lr_refiner)(cutoff=cutoff, transition_bins=1024)
        y = lava.enhance(x, denoise=denoise).numpy().astype(np.float32)

        sf.write(FIXTURES / f"{name}.in.wav", x.squeeze(0).numpy(), 16000, subtype="FLOAT")
        sf.write(FIXTURES / f"{name}.out.wav", y, 48000, subtype="FLOAT")
        index[name] = {"cutoffHz": cutoff, "denoise": denoise}
        print(f"{name}: {x.shape[1]} -> {y.shape[0]} samples, peak {np.abs(y).max():.3f}")

    (FIXTURES / "fixtures.json").write_text(json.dumps(index, indent=2) + "\n")


if __name__ == "__main__":
    main()
