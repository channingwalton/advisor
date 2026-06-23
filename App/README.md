# Advisor App

Mic + system audio → Apple SpeechAnalyzer (on-device) → live transcript,
with a Node sidecar (`../sidecar`, Claude Agent SDK) that auto-detects
questions/topics/claims and produces research cards, plus an on-demand query box.
Sessions are saved as markdown to `~/Library/Application Support/Advisor/sessions/`.

Sidecar build: `cd ../sidecar && npm install --include=dev && npm run build`
(note: global npm config has `omit=dev`, hence the flag).

## Build & run

```sh
cd App
swift build
.build/debug/Advisor              # GUI: click Listen (or press space), speak
```

First run prompts for microphone access; a bare dev run may be attributed to the
launching terminal.

## Packaging

```sh
sh package.sh        # → dist/Advisor.app (self-contained, locally signed)
sh dmg.sh            # → dist/Advisor.dmg (contains Advisor.app + Applications link)
```

The app icon source is `Resources/AppIcon.iconset/` (master: `AppIcon-1024.png`);
`package.sh` compiles it to `AppIcon.icns` via `iconutil` and `Info.plist`
references it through `CFBundleIconFile`/`CFBundleIconName`. To re-skin, edit the
self-contained `Resources/icon-master.html` (palette, waveform, squircle tokens
documented inline), re-export the PNG sizes into `AppIcon.iconset/` using the
Apple naming convention (`icon_16x16.png` … `icon_512x512@2x.png`), then
repackage — no app code change needed.

## Layout

- `Sources/Advisor/AudioCapture.swift` — AVAudioEngine mic tap → 16 kHz mono
- `Sources/Advisor/AppleSpeechEngine.swift` — Apple SpeechAnalyzer STT wrapper
- `Sources/Advisor/Recorder.swift` — pipeline wiring + transcript store
- `Sources/Advisor/AdvisorApp.swift` — SwiftUI window
