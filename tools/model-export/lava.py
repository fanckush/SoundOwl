"""Loads the pinned upstream LavaSR v2 and wraps the parts that go into ONNX.

The app runs the neural networks through ONNX Runtime and does the signal processing around them
(STFT, iSTFT, resampling, the low/high band merge) natively. The wrappers here draw that line:
everything inside them is exported, everything outside is mirrored in `mirror.py` and in Swift.
"""

from pathlib import Path

import torch
from huggingface_hub import snapshot_download

# Pinned upstream. Bump these together, re-export, and regenerate the fixtures.
HF_REPO = "YatharthS/LavaSR"
HF_REVISION = "b98dc8be472da45ab7b6346ad7997e1dfeb5911d"
CODE_COMMIT = "33ac040892519c1bb4aed7eb32e79af51cc29e2a"

CACHE_DIR = Path(__file__).parent / ".cache"


def load_upstream():
    """Returns the upstream LavaEnhance2 built from the pinned weights."""
    from LavaSR.model import LavaEnhance2

    path = snapshot_download(
        HF_REPO,
        revision=HF_REVISION,
        cache_dir=CACHE_DIR,
        allow_patterns=["enhancer_v2/*", "denoiser/*", "README.md"],
    )
    return LavaEnhance2(path, device="cpu"), Path(path)


class BWECore(torch.nn.Module):
    """Linear STFT magnitude in, complex STFT of the 48 kHz prediction out.

    Mirrors MelSpectrogramFeatures (after its STFT) + backbone + LavaSR's patched ISTFTHead
    (before its inverse STFT). The mel filterbank rides along as a constant so the app never has
    to reproduce torchaudio's slaney filterbank (built for 44.1 kHz upstream, on 48 kHz audio).
    """

    def __init__(self, vocos):
        super().__init__()
        self.register_buffer("fb", vocos.feature_extractor.mel_spec.mel_scale.fb.clone())
        self.backbone = vocos.backbone
        self.out = vocos.head.out

    def forward(self, magnitude):  # (1, 1025, T)
        mel = torch.matmul(magnitude.transpose(1, 2), self.fb).transpose(1, 2)
        features = torch.log(torch.clip(mel, min=1e-5))
        x = self.backbone(features)
        x = self.out(x).transpose(1, 2)
        mag, phase = x.chunk(2, dim=1)
        mag = torch.clip(torch.exp(mag), max=1e3)
        return mag * torch.cos(phase), mag * torch.sin(phase)


class DenoiseCore(torch.nn.Module):
    """16 kHz STFT (B, 2, T, 257) in, enhanced STFT of the same shape out (ULUNAS minus its STFTs)."""

    def __init__(self, ulunas):
        super().__init__()
        self.m = ulunas

    def forward(self, spec):
        m = self.m
        feat = torch.log10(torch.norm(spec, dim=1, keepdim=True).clamp(1e-12))
        feat = m.erb.bm(feat)
        feat, en_outs = m.encoder(feat)
        feat = m.dpgrnn(feat)
        mask = m.erb.bs(m.decoder(feat, en_outs))
        return spec * mask
