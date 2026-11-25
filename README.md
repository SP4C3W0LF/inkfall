# Inkfall

Offline dictation for macOS. Press a hotkey, speak, and the text is typed into the app you're using. Transcription runs on your Mac.

## Install

Download `Inkfall.dmg` from the [latest release](../../releases/latest), drag Inkfall to Applications, and open it. Grant Microphone access, and enable Inkfall under System Settings ▸ Privacy & Security ▸ Accessibility.

Requires an Apple silicon Mac with macOS 26 or later.

## Build from source

Needs Xcode 27 (the macOS 27 SDK) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
git clone https://github.com/wasteland-labs-llc/inkfall.git
cd inkfall
xcodegen generate
open Inkfall.xcodeproj
```

Or without Xcode's editor: `swift build && swift run Inkfall`.

## License

[MIT](LICENSE) © Wasteland Labs LLC. Third-party licences: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
