# Transcribe

An iPhone app for transcribing audio and video on the device.

- **Share Sheet:** share a recording from Voice Memos, Photos or Files to add it. The app opens on it.
- **Import:** the + button links to files in Files / iCloud Drive (originals are never copied or deleted).
- **Transcribe on command:** each recording has a Transcribe button. Nothing runs on its own.
- **Engines:** Apple's on-device `SpeechTranscriber` by default; [Parakeet Ultra](https://github.com/FluidInference/FluidAudio) as an optional download (~630 MB) in Settings.
- **Speakers:** labelled with FluidAudio's Sortformer model (~100 MB, downloaded on first use), named automatically from introductions and direct address ("Hi Dana"), and renamable by tapping the label.
- **Titles:** short descriptions from the on-device Apple Intelligence model.

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
