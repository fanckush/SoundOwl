"""Exports the pinned LavaSR v2 to the model package the app downloads.

    uv run python export.py            # writes build/lavasr-v2/ and build/lavasr-v2-<version>.zip

The package holds two ONNX graphs and a model.json with every constant the native code needs.
"""

import hashlib
import json
import shutil
import zipfile
from pathlib import Path

import numpy as np
import onnxruntime as ort
import torch

from lava import CODE_COMMIT, HF_REPO, HF_REVISION, BWECore, DenoiseCore, load_upstream

MODEL_ID = "lavasr-v2"
PACKAGE_VERSION = 1  # bump when the graphs or model.json change for the same upstream weights
OPSET = 17

OUT = Path(__file__).parent / "build" / MODEL_ID


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def export(module, args, path, input_names, output_names, dynamic_axes):
    torch.onnx.export(
        module,
        args,
        path,
        input_names=input_names,
        output_names=output_names,
        dynamic_axes=dynamic_axes,
        opset_version=OPSET,
        dynamo=False,
    )


def check(module, path, inputs):
    """Runs the graph and the torch module on the same input and returns the max abs difference."""
    session = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
    feeds = {i.name: x.numpy() for i, x in zip(session.get_inputs(), inputs)}
    got = session.run(None, feeds)
    with torch.no_grad():
        want = module(*inputs)
    want = want if isinstance(want, tuple) else (want,)
    return max(float(np.abs(g - w.numpy()).max()) for g, w in zip(got, want))


def main():
    lava, weights = load_upstream()
    vocos = lava.bwe_model.bwe_model
    bwe = BWECore(vocos).eval()
    denoise = DenoiseCore(lava.denoiser_model.model).eval()

    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)

    torch.manual_seed(0)
    mag = torch.rand(1, 1025, 200) * 3
    export(bwe, (mag,), OUT / "bwe.onnx", ["magnitude"], ["real", "imag"],
           {"magnitude": {2: "frames"}, "real": {2: "frames"}, "imag": {2: "frames"}})
    spec = torch.randn(1, 2, 300, 257)
    export(denoise, (spec,), OUT / "denoiser.onnx", ["spec"], ["enhanced"],
           {"spec": {2: "frames"}, "enhanced": {2: "frames"}})

    # Different lengths than the trace, so a frame count baked in by accident shows up here.
    bwe_err = check(bwe, OUT / "bwe.onnx", [torch.rand(1, 1025, 333) * 3])
    den_err = check(denoise, OUT / "denoiser.onnx", [torch.randn(1, 2, 517, 257)])
    print(f"onnx vs torch: bwe {bwe_err:.2e}, denoiser {den_err:.2e}")
    assert bwe_err < 1e-2 and den_err < 1e-4, "exported graphs disagree with torch"

    feature = vocos.feature_extractor.mel_spec
    manifest = {
        "id": MODEL_ID,
        "name": "LavaSR v2",
        "packageVersion": PACKAGE_VERSION,
        "upstream": {
            "authors": "Yatharth Sharma",
            "license": "Apache-2.0",
            "code": f"https://github.com/ysharma3501/LavaSR/tree/{CODE_COMMIT}",
            "weights": f"https://huggingface.co/{HF_REPO}/tree/{HF_REVISION}",
            "paper": "https://arxiv.org/abs/2603.07285",
            "denoiser": {
                "name": "UL-UNAS",
                "authors": "Xiaobin Rong et al.",
                "license": "MIT",
                "code": "https://github.com/Xiaobin-Rong/ul-unas",
            },
        },
        "pipeline": {
            "modelSampleRate": 16000,
            "outputSampleRate": 48000,
            "resample": {"lowpassFilterWidth": 6, "rolloff": 0.99, "window": "hann"},
            "bwe": {
                "file": "bwe.onnx",
                "nFFT": feature.n_fft,
                "hop": feature.hop_length,
                "window": "hann-periodic",
                "padding": "same-reflect",
            },
            "denoiser": {
                "file": "denoiser.onnx",
                "nFFT": lava.denoiser_model.model.n_fft,
                "hop": lava.denoiser_model.model.hop_len,
                "window": "hann-periodic",
                "padding": "center-reflect",
            },
            "merge": {"cutoffHz": 8000, "transitionBins": 1024},
        },
        "files": {},
    }
    for name in ("bwe.onnx", "denoiser.onnx"):
        manifest["files"][name] = {"sha256": sha256(OUT / name), "bytes": (OUT / name).stat().st_size}
    (OUT / "model.json").write_text(json.dumps(manifest, indent=2) + "\n")

    for license_file in (Path(__file__).parent / "licenses").iterdir():
        shutil.copy(license_file, OUT / license_file.name)

    # Fixed timestamps and order, so the same export always hashes the same: the app pins the hash.
    zip_path = OUT.parent / f"{MODEL_ID}-{PACKAGE_VERSION}.zip"
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(OUT.iterdir()):
            info = zipfile.ZipInfo(f"{MODEL_ID}/{f.name}", date_time=(2026, 1, 1, 0, 0, 0))
            info.external_attr = 0o644 << 16
            z.writestr(info, f.read_bytes(), zipfile.ZIP_DEFLATED)
    print(f"wrote {zip_path} ({zip_path.stat().st_size / 1e6:.1f} MB) sha256 {sha256(zip_path)}")
    print(f"weights from {weights}")


if __name__ == "__main__":
    main()
