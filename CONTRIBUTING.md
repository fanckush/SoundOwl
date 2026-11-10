# Contributing to SoundOwl

Thanks for helping. SoundOwl's whole point is that it feels simple, so the bar for new options in
the main window is high. Bug fixes, speed, robustness with odd files, and polish are always welcome.
For anything bigger, open a [discussion](https://github.com/fanckush/SoundOwl/discussions) first.

## Getting set up

Requires Xcode 26 (Swift 6.2) on an Apple Silicon Mac running macOS 15 or later.

```sh
git clone https://github.com/fanckush/SoundOwl && cd SoundOwl
scripts/setup-hooks.sh      # lint on commit, commit-message check, tests on push
scripts/fetch-model.sh      # the model package, for the engine tests and the CLI
swift test
open SoundOwl.xcodeproj     # scheme "SoundOwl", then Run
```

The app downloads the model on first launch like any other copy. To skip the download while
developing, serve your local package and point the app at it:

```sh
(cd tools/model-export/build && python3 -m http.server 8765 --bind 127.0.0.1) &
defaults write app.soundowl.SoundOwl ModelDownloadURL http://127.0.0.1:8765/lavasr-v2-1.zip
```

The checksum pinned in `ModelRelease.swift` still applies. `defaults delete app.soundowl.SoundOwl
ModelDownloadURL` undoes it.

## Layout

| Path | What's there |
| --- | --- |
| `Sources/SoundOwlCore` | Everything that isn't UI: the engine, streaming, audio I/O, recipes, model download, export |
| `Sources/SoundOwlCLI` | The shipped `soundowl` command. The app binary runs it when started with `--cli`; `Contents/Resources/soundowl` is the wrapper script |
| `Sources/soundowl` | A thin `main` for `swift run soundowl` |
| `Sources/soundowl-dev` | Developer harness: `parity`, `restore`, `bench`, `lookahead`. Never shipped |
| `SoundOwl/` | The SwiftUI app: the window (Listen mode), the menu bar item, the Finder service and the Shortcuts action |
| `project.yml` | The Xcode project, via [XcodeGen](https://github.com/yonaskolb/XcodeGen). Run `scripts/generate-project.sh` after editing it and commit both |
| `tools/model-export` | Python (uv) scripts that turn upstream LavaSR into the ONNX package and the test fixtures |
| `docs/engine.md` | How the native engine maps onto the upstream PyTorch pipeline |

## The engine

The Swift engine must reproduce upstream LavaSR exactly. `Tests/Fixtures/lavasr-v2` holds
reference outputs from the PyTorch pipeline, and `swift test` (or
`swift run -c release soundowl-dev parity`) compares against them. A change to the DSP code
or to how the model is run should keep every fixture passing.

`swift run -c release soundowl-dev bench <file>` reports speed and peak memory. Please include
before/after numbers with performance changes.

Rebuilding the model package from upstream (only needed when changing the export):

```sh
brew install uv
cd tools/model-export
uv run python export.py
```

## Commits and pull requests

Commit subjects and PR titles use [Conventional Commits](https://www.conventionalcommits.org):
`feat:`, `fix:`, `perf:`, `docs:` or `chore:`, with an optional scope (`fix(export): …`). Releases
and their notes are generated from them, so a `feat:` or `fix:` subject is what users read in the
changelog. Write it for them.

Run `scripts/test.sh` and `scripts/lint.sh` before opening a PR. The pre-commit hook runs the
linter on staged files; `scripts/lint.sh --fix` applies the formatter.

By contributing you agree that your work is licensed under the [Apache License 2.0](LICENSE).
