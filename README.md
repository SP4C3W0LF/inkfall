# Inkfall

Offline dictation for macOS. Press a hotkey, speak, and your words land in whatever app you're using — transcribed, cleaned up, and pasted entirely on your Mac.

Your voice and your text never leave your machine. Dictation makes zero network calls: no cloud transcription, no telemetry, no logging. The only network use the app is capable of is downloading a speech model when you ask it to.

## Features

- **Zero-setup speech recognition** — on-device Whisper via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML). Works out of the box; pick larger models in Settings if you want more accuracy.
- **On-device rewrite** — optional cleanup of fillers and phrasing through Apple Intelligence (Foundation Models), with a deterministic rule-based fallback when it's unavailable.
- **Global hotkey** — default `⌥ Space`, fully rebindable with a click-to-record shortcut field that warns about system-shortcut conflicts.
- **Quiet by design** — a monochrome menu-bar waveform and a floating HUD that shows recording, transcribing, and polishing as they actually happen.
- **Words are never lost** — every transcript is copied to the clipboard before insertion is attempted, so a failed paste degrades to a simple `⌘V`.
- **Custom vocabulary and language** — bias cleanup toward your names and jargon.
- **Bring your own engine (advanced)** — plug in a local `whisper-cli` / `llama-cli` and GGUF models instead of the built-in engines.
- **Launch at login**, configurable HUD position, and a settings window that never makes you edit a config file.

## Install

1. Download `Inkfall.dmg` from the [latest release](../../releases/latest).
2. Drag **Inkfall** to Applications and open it.
3. On first run, grant **Microphone** access and enable Inkfall under **System Settings ▸ Privacy & Security ▸ Accessibility** (required to type dictated text into other apps).

**Requirements:** an Apple silicon Mac running macOS 27 or later. The rewrite step additionally requires Apple Intelligence to be enabled (it falls back to rule-based cleanup when it isn't).

## Usage

Press `⌥ Space` (or click the menu-bar waveform ▸ Start Dictation), speak, and press it again to stop. The HUD shows the transcript as it's inserted into the frontmost app. `Copy last result` in the menu re-copies the most recent transcript.

## Build from source

```sh
brew install xcodegen
git clone https://github.com/SP4C3W0LF/inkfall.git
cd inkfall
xcodegen generate        # creates Inkfall.xcodeproj (gitignored)
open Inkfall.xcodeproj
```

For quick iteration without Xcode:

```sh
swift build
swift run Inkfall
```

## Configuration

Everything is available in the app under `Settings…`, stored at `~/Library/Application Support/Inkfall/config.json`. Advanced users can also point Inkfall at external CLI engines:

```sh
export INKFALL_WHISPER_BIN=/path/to/whisper-cli
export INKFALL_WHISPER_MODEL=/path/to/ggml-large-v3-turbo.bin
export INKFALL_LLAMA_BIN=/path/to/llama-cli
export INKFALL_LLAMA_MODEL=/path/to/qwen3-1.7b-q4.gguf
```

or set the equivalent keys (`whisperBinaryPath`, `whisperModelPath`, `llamaBinaryPath`, `llamaModelPath`, `customVocabulary`, …) in `config.json`.

## Tests

```sh
swift build
swiftc Sources/Inkfall/TranscriptNormalizer.swift scripts/check_normalizer.swift -o work/check_normalizer
work/check_normalizer
```

## Privacy verification

Don't take the privacy claim on faith — verify it. Run Inkfall with Little Snitch, LuLu, or `lsof -i` watching: capture, transcription, cleanup, and insertion open no network sockets. The only outbound traffic you should ever be able to provoke is a model download you explicitly initiated (WhisperKit's first-use model fetch or a `Download model` action in Settings).

## License

[MIT](LICENSE) © Andre Hogan
