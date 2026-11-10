# Third-party notices

SoundOwl is licensed under the [Apache License 2.0](LICENSE). It builds on the work below.

## The voice model (downloaded on first launch, not bundled)

The model package (`lavasr-v2-1.zip`) is built from upstream by `tools/model-export` and published
on this repository's releases. The license texts travel inside the package.

| Component | Authors | License | Source |
| --- | --- | --- | --- |
| LavaSR v2 (speech restoration: code and weights) | Yatharth Sharma | Apache-2.0 | [ysharma3501/LavaSR](https://github.com/ysharma3501/LavaSR), [YatharthS/LavaSR](https://huggingface.co/YatharthS/LavaSR) |
| UL-UNAS (noise reduction) | Xiaobin Rong et al. | MIT (code); weights distributed in the Apache-2.0 LavaSR repository | [Xiaobin-Rong/ul-unas](https://github.com/Xiaobin-Rong/ul-unas) |
| Vocos (the bandwidth-extension backbone LavaSR builds on) | Hubert Siuzdak and contributors | MIT | [gemelo-ai/vocos](https://github.com/gemelo-ai/vocos) |

## Bundled in the app

| Component | License | Source |
| --- | --- | --- |
| ONNX Runtime | MIT | [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) |
| Sparkle | MIT, plus the notices in its repository | [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle) |

## Developer tools (not shipped)

PyTorch, torchaudio, ONNX and the upstream Python packages are used only by `tools/model-export`
to build the model package and test fixtures. Their versions are pinned in
`tools/model-export/pyproject.toml`.
