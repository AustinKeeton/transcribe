# Transcribe

An iPhone app for transcribing audio and video on the device.

- **Share Sheet / Files / Photos:** add a recording; files from Files are linked, not copied.
- **Transcribe on command,** per recording: *Coaching (2 speakers)* or *Single speaker*, plus custom vocabulary (client name, company, terms).
- **All on device (Neural Engine), via [FluidAudio](https://github.com/FluidInference/FluidAudio):** Silero VAD → Parakeet TDT 0.6B v2 (English) per speech segment → vocabulary rescoring (filtered to replacements that resemble the term) → offline pyannote diarization with exactly two speakers in coaching mode. Models (~650 MB) download once, Wi-Fi only.
- **Verbatim:** every um, stutter and pause kept; formatting only (capitals, commas around fillers, pause markers). Speakers renamable; names detected from introductions and direct address.

Requires iOS 26.

## Build

```sh
brew install xcodegen
xcodegen generate
open Transcribe.xcodeproj
```

Set your own `DEVELOPMENT_TEAM`, bundle IDs and App Group in `project.yml` before building for a device.

## Layout

- `App/` – the app: list, detail, settings, Parakeet and speaker models (FluidAudio)
- `ShareExtension/` – adds shared media and opens the app
- `Shared/` – storage, Apple transcription, word timings, speaker naming, transcript view
