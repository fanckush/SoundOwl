# Restoration engine

SoundOwl runs LavaSR v2 with the two neural networks in ONNX Runtime and all signal processing
around them in Swift (Accelerate). There is no Python in the app.

```
16 kHz mono ──► [denoiser.onnx]? ──► resample ×3 ──► STFT ──► [bwe.onnx] ──► iSTFT ──► band merge ──► 48 kHz
               (UL-UNAS, optional)  (torchaudio sinc)  (2048/512)  (mel+Vocos)                  (orig < cutoff < predicted)
```

| Piece | Where | Upstream reference |
|---|---|---|
| Denoiser STFT/iSTFT (512/256, center, reflect) | `LavaSR.denoise` | `torch.stft` in `ULUNAS.forward` |
| Denoiser network + mask | `denoiser.onnx` | `ULUNAS` minus its STFTs |
| 16 → 48 kHz resample | `Signal.resample` | `torchaudio.functional.resample` defaults |
| STFT magnitude (2048/512, "same" reflect padding) | `LavaSR.bandwidthExtend` | `MelSpectrogramFeatures` before the mel matmul |
| Mel filterbank, log, Vocos backbone, head | `bwe.onnx` | `BWECore` in `tools/model-export/lava.py` |
| iSTFT ("same" padding, window-envelope normalised) | `LavaSR.bandwidthExtend` | `vocos.spectral_ops.ISTFT` |
| Low/high band merge | `Signal.bandMerge` | `FastLRMerge` |
| Chunking on a 512-sample grid, no crossfade needed | `ChunkPlan`, `Restorer` | (ours) |

`tools/model-export/mirror.py` is the executable spec: the same pipeline in NumPy, checked against
upstream. The Swift engine is checked against the same golden fixtures (`swift test`, or
`swift run -c release soundowl-dev parity`).

## Parity (milestone 0)

Native output vs upstream PyTorch on the fixtures in `Tests/Fixtures/lavasr-v2`:

| Fixture | SNR vs upstream | Length |
|---|---|---|
| speech-16k | 115 dB | exact |
| phone-8k (cutoff 4 kHz) | 64 dB | exact |
| noisy-16k with denoiser | 117 dB | exact |
| short (0.25 s) | 108 dB | exact |
| silence | max error 1e-8 | exact |

A chunked restore matches a single pass at 91 dB.

## Things upstream does that matter

- **Everything goes through 16 kHz.** `load_wav` resamples any input to 16 kHz, and the mel
  features stop at 8 kHz. Real content above 8 kHz in the source is thrown away and regenerated.
  Worth evaluating: merging the *original* full-band signal up to the source's real bandwidth.
- **The end gets clipped.** The iSTFT returns `frames × hop` samples, up to 511 fewer than 3×
  the input. `Restorer` pads with silence and trims, so output is always exactly 3× the input.
- **The crossover width depends on length.** `FastLRMerge` uses 1024 bins of one FFT over the
  whole signal: ~170 Hz on a 6 s clip, a near brick-wall on an hour. The app uses a fixed 170 Hz
  (`Restorer.transitionHz`); `enhance(transitionHz: nil)` keeps upstream's behaviour for parity.
- **The networks are not shift-invariant.** The generated high band depends on where STFT frames
  fall. Chunk windows start on multiples of 512 input samples so they share a single pass's
  frame grid. Without that, chunk seams differ audibly (25 dB instead of 91 dB).
- **The mel filterbank is built for 44.1 kHz** but applied to 48 kHz audio. It is exported as a
  constant inside `bwe.onnx`, so this quirk is reproduced exactly without re-deriving it.
- `cutoff` is `input_sr / 2` upstream (8 kHz by default, 4 kHz for 8 kHz phone audio). The app
  measures it instead (`Bandwidth.cutoff`, 3–8 kHz), because a file's sample rate says little about
  what survived in it: a 44.1 kHz MP3 of a phone call is still a phone call.
- **The network predicts above 8 kHz, not above the cutoff.** It was trained on 16 kHz input, so
  for phone audio (nothing above ~3.5 kHz) the 4–8 kHz band stays nearly empty after restoration.
  It still sounds much clearer, but the gap is visible in a spectrogram (see the phone sample on
  the website). Closing it would need a model trained for narrowband input.

## Performance (M5 Pro, CPU only)

`soundowl-dev bench` on 13.6 min of 22 kHz AAC speech: **~140× realtime** (an hour in ~26 s),
**~50× with the denoiser**. ONNX Runtime is ~75% of the time. The app restores in 30 s chunks
from disk-backed buffers (`PCMStore`), so memory doesn't grow with the length of the recording:
about 600 MB while restoring, mostly ONNX Runtime's arena, which the app releases after 20 s idle.

Two traps found on the way:
- vDSP keeps memory for large DFT setups even after destroying them (~20 MB per setup), so
  `LongDFT.shared` caches them by length.
- ORT's Objective-C API returns autoreleased tensors; `OnnxGraph.run` drains a pool per call.

## Live feasibility (2026-11-04, first run)

Could SoundOwl restore other people on a call as you hear them? `StreamRestorer` restores a stream
in hops of `core` samples, each from a window with `before` samples of history and `after` samples
of look-ahead. It is `Restorer.restoreChunk` on a plan that never ends, so with a second of
context on both sides it matches the file path exactly (`StreamRestorerTests`). The added delay is
`core + after + compute + device I/O`.

`scripts/lookahead-corpus.sh` builds call-like clips (Opus narrowband/wideband/super-wideband and
G.711, made from the site samples and fixtures with `afconvert`). Then run
`soundowl-dev lookahead build/lookahead-corpus/*.wav --core-ms 32,64 --right-ms 64,…,256 --load 4`,
with 4 busy processes standing in for the call app. The comparison is against the offline restore
(1 s context), above the cutoff. Median and worst of 12 clips, 512 ms history, 2 ORT threads:

| core / look-ahead | added delay | high-band LSD median / worst | p99 hop | CPU |
|---|---|---|---|---|
| 32 / 64 ms | ~125 ms | 5.2 / 6.5 dB | 5 ms | 0.2 cores |
| 32 / 96 ms | ~160 ms | 3.5 / 5.4 dB | 6 ms | 0.3 cores |
| 32 / 128 ms | ~190 ms | 2.0 / 3.9 dB | 6 ms | 0.3 cores |
| 32 / 160 ms | ~225 ms | 0.9 / 2.4 dB | 7 ms | 0.3 cores |
| 32 / 192 ms | ~255 ms | 0.3 / 1.1 dB | 7 ms | 0.3 cores |
| 32 / 256 ms | ~320 ms | 0.01 / 0.05 dB | 7 ms | 0.3 cores |

- **Speed is no constraint.** A hop takes 3–7 ms of a 32 ms budget under load, about a third of
  a core on average, and the cold first hop takes milliseconds.
- **Look-ahead is the constraint.** The Vocos backbone (8 ConvNeXt blocks, kernel 7, over 10.7 ms
  frames) sees about 290 ms ahead, so quality converges only past ~200 ms of look-ahead.
  Narrowband (phone, G.711) clips suffer most, because they have the most to regenerate.
- No setting meets the plan's objective bar (worst LSD ≤ 2 dB at ≤ 180 ms total). LSD measures the
  distance from the offline restore, not whether a restore sounds better than the call, so the
  decision rests on a blind listening test (`build/listening/`).
- Seam ratios rise with long look-ahead only because the remaining error is tiny; there is no
  hop-rate buzz at any setting.
- The online cutoff (first 3 s) matched the offline one within 250 Hz on 11 of 12 clips. On
  `phone-before` it measured 4750 vs 3500 Hz, so the estimate needs to keep updating.
- Full-band detection (`Quality.highBandLevel`, 8.5–11 kHz vs. 0.5–3 kHz) gave -38 to -53 dB on
  super-wideband and full-band speech and -79 dB or nothing on the rest. (A first -60 dB threshold
  let an old, hissy recording through as "already clear"; see below for what replaced it.)

### How Live is built (`Sources/SoundOwlLive`)

- **`ProcessTap`**: a private `CATapDescription` on the chosen app's processes (its helpers
  included: `AudioProcesses` groups `com.google.Chrome.helper` under Chrome, and the WebKit GPU
  process under Safari), muted while tapped. It sits in a private aggregate device whose main
  sub-device is the current output, so one IOProc reads the call and writes what you hear on one
  clock. The tap is private and dies with the process: if SoundOwl crashes, the call is heard
  directly again. Teardown goes IOProc, aggregate device, tap.
- **`LivePipeline`**: the IOProc keeps both channels in a history ring and sends a mono mix to an
  engine thread through a lock-free `SampleFIFO`. The engine resamples to 16 kHz, runs
  `StreamRestorer` (2 ORT threads), resamples to the device rate and writes into a
  `TimelineRing` addressed by input frame. The IOProc plays frame *n − delay*: restored if it's
  there, the original otherwise, with a 5 ms crossfade. A stall means unrestored, never silence.
  The resamplers' delay is measured with an impulse at start, so restored and original line up to
  the sample (`LivePipelineTests`).
- **Bandwidth**: the first 3 s of sound set the cutoff, then it is re-measured every 10 s, moving
  only when two measurements agree or it jumps by 1 kHz or more. New sound starts fresh: after 2 s
  of quiet (the next video) the next 3 s are measured on their own, and when the sound changes
  between music and voice the last 3 s are measured at once. Restoring stops for "already clear"
  only after two clear measurements in a row, because 3 s of a dull voice sometimes reads as
  full-band; it starts again after one. Simulated in release: a song then a dull old talk switches
  to restoring 2.5–4 s into the talk (with or without a gap), and talk then song stops in about 3 s. A call that is already full-band
  plays untouched: 8.5–11 kHz within 50 dB of the voice band while someone speaks, *and* at least
  10 dB louder than in the pauses (`Quality.hasFullBandContent`). The second test matters: an old
  recording on YouTube is full-band as a stream, but what's up there is hiss, which doesn't come
  and go with the voice. Full-band voices measure about -40 dB with 13–27 dB of contrast; the dull
  and hissy samples -54 to -63 dB or under 10 dB (`soundowl-dev fullband <files>`).
- **Music** plays untouched as well: the model rebuilds voices and smears instruments and
  singing. Apple's sound classifier (SoundAnalysis, `.version1`, on device) labels the stream in
  1.5 s windows; music or singing at 0.35 or more makes a window music, speech at 0.6 or more a
  voice, and two of the last three windows decide (`SoundKindDetector`). On the corpus every speech
  window scored speech ≥ 0.86, and two songs were music in 55 and 60 of 60 windows, none speech.
  It costs about 2 ms per second of sound. Music also fails the full-band contrast test (its highs
  never pause), which is why it needs its own check: a guitar cover on YouTube was being restored.
- **Per-app options**, inline in the panel: Faster / Balanced / Clearer look-ahead (64, 128 or
  192 ms; about 0.13, 0.19 and 0.26 s in all, changing it starts the pipeline over), reduce
  background noise (about 12 ms per 32 ms hop instead of 4, so roughly three times the compute)
  and leave clear sound untouched (on by default).
- **`LiveSession`**: rebuilds when the default output or the app's processes change (and after
  wake). It turns Live off after 3 s of continuous fallback, and reports a missing permission
  after 8 s of digital silence from an app that is playing. An output under 24 kHz (a Bluetooth
  headset in call mode) can't carry the restored band, so Live waits.
- The first `AudioDeviceStart` blocks until the user answers macOS's System Audio Recording
  prompt, so nothing waits on the session's queue.
- **Settings**: `LiveSettings.standard` uses 32 ms hops, 512 ms of history and 128 ms of
  look-ahead, about 190 ms in all. The listening test may move the look-ahead.

`soundowl-dev live --pid N | --bundle ID` runs the whole path headless and prints latency,
fallback, hop times and CPU once a second (`afplay clip.wav & soundowl-dev live --pid $!`).

## Licensing

LavaSR code and weights: Apache-2.0 (Hugging Face repo and GitHub). UL-UNAS code: MIT, and the
denoiser weights ship inside the Apache-2.0 LavaSR weights repo. Both license texts travel inside
the model package (`tools/model-export/licenses/`).
