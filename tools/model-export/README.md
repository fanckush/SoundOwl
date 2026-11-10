# Model export (developer only)

Turns the pinned upstream LavaSR v2 into the model package the app downloads, and produces the
golden fixtures the Swift engine is tested against. Nothing here ships in the app.

```sh
brew install uv
cd tools/model-export
uv run python export.py         # build/lavasr-v2/ (bwe.onnx, denoiser.onnx, model.json, licenses) + .zip
uv run python make_fixtures.py  # Tests/Fixtures/lavasr-v2 (needs macOS `say`)
uv run python mirror.py         # NumPy + ORT pipeline vs the fixtures
```

Then from the repo root: `swift test`, or `swift run -c release soundowl-dev parity`.

Upstream is pinned in `lava.py` (`HF_REVISION`, `CODE_COMMIT`) and `pyproject.toml`. To move to a
new upstream: bump both, bump `PACKAGE_VERSION` in `export.py`, re-export, regenerate fixtures,
and check parity. See `docs/engine.md` for what the split between ONNX and native code is.
