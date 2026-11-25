<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="design/export/readme-lockup-dark.svg">
    <img src="design/export/readme-lockup-light.svg" alt="Inkfall" width="360">
  </picture>
</p>

# Inkfall

Offline dictation for macOS. Press a hotkey, speak, and your words land in whatever app you're using — transcribed, cleaned up, and pasted entirely on your Mac.

Your voice and your text stay on your machine: no cloud transcription, no telemetry, no logging. Once the speech model is on disk, the app needs no network: the built-in engine loads it with zero requests and transcribes with networking turned off (measured; see [Privacy verification](#privacy-verification)). The only network use is downloading a speech model: during setup, when you pick a different model, or on first use if the model is missing. A download shows on screen, and it comes from huggingface.co.

## Features

- **Zero-setup speech recognition** — on-device Whisper via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML). Works out of the box; pick larger models in Settings if you want more accuracy.
- **On-device rewrite** — optional cleanup of fillers and phrasing through Apple Intelligence (Foundation Models), with a deterministic rule-based fallback when it's unavailable.
- **Two ways to start** — tap a global shortcut (default `⌥ Space`, fully rebindable, warns about system-shortcut conflicts), or switch to **hold to talk** and just hold the **left Option key** while you speak. The right Option key stays free for typing accented characters.
- **Quiet by design** — a monochrome menu-bar glyph and a floating HUD that shows recording, transcribing, and polishing as they actually happen.
- **Your words stay reachable** — text is written at the cursor when the app allows it, without touching the clipboard. When Inkfall has to paste, the text sits on the clipboard for under a second, marked so clipboard managers skip it and it stays on this Mac, and your earlier clipboard is put back unless you copied something in between. If you switch apps before the text is ready, it is left on the clipboard and not pasted. `Copy last result` and `Copy original transcript` in the menu give the words back, the second one before any spoken-command or cleanup rule touched them.
- **Custom vocabulary and language** — your names and jargon condition the recogniser itself, so Whisper hears the word rather than being corrected afterwards, and the same list guides the cleanup pass.
- **Bring your own engine (advanced)** — plug in a local `whisper-cli` / `llama-cli` and GGUF models instead of the built-in engines.
- **Launch at login**, configurable HUD position, and a settings window that never makes you edit a config file.

## Install

1. Download `Inkfall.dmg` from the [latest release](../../releases/latest).
2. Drag **Inkfall** to Applications and open it.
3. On first run, grant **Microphone** access and enable Inkfall under **System Settings ▸ Privacy & Security ▸ Accessibility** (required to type dictated text into other apps).

**Requirements:** an Apple silicon Mac running macOS 26 (Tahoe) or later. The rewrite step additionally requires Apple Intelligence to be enabled (it falls back to rule-based cleanup when it isn't).

## Usage

Press `⌥ Space` (or click the menu-bar waveform ▸ Start Dictation), speak, and press it again to stop. The HUD says what happened: "Inserted" when the app confirmed the text is in the field, "Pasted" when a paste keystroke was sent and could not be confirmed, "Copied" when nothing was sent. In hold-to-talk mode, recording starts after the key has been held for 0.2 seconds, and is dropped if you press another key or click first. macOS can ignore an Option-only shortcut while a password field or Terminal's Secure Keyboard Entry is active.

### Spoken commands

Applied to the transcript before it is inserted:

- **Corrections:** "scratch that" and "delete that", set off by punctuation, remove the sentence before them. "Never mind" does the same only when it opens its own sentence. Inside a sentence ("I told her, never mind, it's fine") all words are kept.
- **Fillers:** "um", "uh", "erm" and stretched forms are removed with one neighbouring comma; "you know" and "I mean" only as an aside between commas.
- **Formatting:** "new line", "new paragraph", "bullet list" and "next bullet" become line breaks and bullets. They stay as words when the surrounding words show you are talking about them ("a new line").
- **Capitals** go at the start of sentences, not after things like "e.g." or inside web addresses.

The untouched transcript stays available through `Copy original transcript`.

## Build from source

```sh
brew install xcodegen
git clone https://github.com/SP4C3W0LF/inkfall.git
cd inkfall
xcodegen generate        # creates Inkfall.xcodeproj (gitignored)
open Inkfall.xcodeproj
```

Building requires the macOS 27 SDK (Xcode 27): the app runs on macOS 26, but its audio capture uses the macOS 27 tap API behind an availability check, falling back to the classic tap on Tahoe.

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

With `llama-cli`, the transcript is passed as a command-line argument, so other processes of the same user can see it while it runs.

If `config.json` cannot be read, Inkfall copies it to `config.json.bad-<date>` beside it, starts with defaults, and says so in Settings. Closing Settings with unsaved changes asks whether to save.

## Tests

```sh
swift test
```

`ci/release.sh <version> --dry-run` runs the same tests and then makes an unsigned build and disk image. It needs no secrets.

## Privacy verification

Don't take the privacy claim on faith — verify it. Run Inkfall with an outbound firewall such as Little Snitch or LuLu watching. What was measured: with the speech model on disk, the built-in engine loaded it with zero network requests, and it loaded and transcribed with networking denied. Capture, cleanup and insertion contain no network code. The only traffic you should be able to provoke is a model download: during setup, when you choose another model in Settings, or on first use if the model is missing. It contacts huggingface.co and its download servers under hf.co, and the app shows it on screen. Bring-your-own engines are your own programs; Inkfall does not control what they do.

## License

[MIT](LICENSE) © Andre Hogan

Third-party licences: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) (also inside the app, in `Contents/Resources`).
