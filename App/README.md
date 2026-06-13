# Advisor App

Mic + system audio → energy VAD → whisper.cpp (Metal, local) → live transcript,
with a Node sidecar (`../sidecar`, Claude Agent SDK) that auto-detects
questions/topics/claims and produces research cards, plus an on-demand query box.
Sessions are saved as markdown to `~/Library/Application Support/Advisor/sessions/`.

Sidecar build: `cd ../sidecar && npm install --include=dev && npm run build`
(note: global npm config has `omit=dev`, hence the flag).

## One-time setup

```sh
# from Advisor/ — already done if vendor/whisper.cpp exists and is built
git clone --depth 1 https://github.com/ggml-org/whisper.cpp vendor/whisper.cpp
cmake -S vendor/whisper.cpp -B vendor/whisper.cpp/build -DCMAKE_BUILD_TYPE=Release
cmake --build vendor/whisper.cpp/build -j
sh vendor/whisper.cpp/models/download-ggml-model.sh small
sh App/setup.sh   # symlinks whisper headers into Sources/CWhisper/include
```

## Build & run

```sh
cd App
swift build
.build/debug/Advisor              # GUI: click Listen (or press space), speak
```

First run prompts for microphone access (attributed to the launching terminal).

## Smoke test (headless)

```sh
.build/debug/Advisor --smoke ../vendor/whisper.cpp/samples/jfk.wav
```

Expected: `SMOKE OK (~130 ms): And so my fellow Americans...`

## Model selection

```sh
ADVISOR_WHISPER_MODEL=/path/to/ggml-large-v3-turbo.bin .build/debug/Advisor
```

Benchmarks (M4 Max, 11 s clip, warm): `small` 130 ms, `large-v3-turbo` 395 ms.

## Packaging

```sh
sh package.sh        # → dist/Advisor.app (self-contained, ad-hoc signed)
```

The app icon source is `Resources/AppIcon.iconset/` (master: `AppIcon-1024.png`);
`package.sh` compiles it to `AppIcon.icns` via `iconutil` and `Info.plist`
references it through `CFBundleIconFile`/`CFBundleIconName`. To re-skin, tweak the
knobs (palette, waveform, squircle) at the top of `Resources/make-icon.py`, run
`python3 Resources/make-icon.py` to regenerate the iconset, then repackage —
no app code change needed.

## Layout

- `Sources/CWhisper/` — C shim exposing `whisper.h` (headers are symlinks into `vendor/`)
- `Sources/Advisor/AudioCapture.swift` — AVAudioEngine mic tap → 16 kHz mono
- `Sources/Advisor/Segmenter.swift` — energy VAD; segments on ~700 ms silence / 8 s cap
- `Sources/Advisor/WhisperTranscriber.swift` — whisper.cpp C API wrapper
- `Sources/Advisor/Recorder.swift` — pipeline wiring + transcript store
- `Sources/Advisor/AdvisorApp.swift` — SwiftUI window + `--smoke` mode
