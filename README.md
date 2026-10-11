# MiniDictate

A small push-to-talk dictation app for macOS. Hold the right Option key, speak, release, and your words are pasted at the cursor in whatever app you're using.

Speech is transcribed on your Mac with [Whisper](https://github.com/openai/whisper) (the multilingual `base` model, via [WhisperKit](https://github.com/argmaxinc/WhisperKit)). No account, API key or internet connection is needed after the first launch.

It was built as a minimal take on the dictation flow of apps like Wispr Flow: one hotkey, a live waveform while you talk, and a history of what you dictated.

![MiniDictate home window showing stats and dictation history](docs/screenshots/home.png)

While you hold the key, a pill at the bottom of the screen shows a live waveform of your voice:

<img src="docs/screenshots/pill.png" alt="Recording pill with a live waveform" width="220">

Settings shows the state of each permission and which transcription engine is active:

![MiniDictate settings window](docs/screenshots/settings.png)

The screenshots use sample data from the app's demo mode (see Troubleshooting).

## Features

- **Hold-to-talk hotkey:** right Option (⌥), works in any app.
- **On-device transcription:** Whisper `base`, with the language detected per dictation.
- **Live waveform pill** at the bottom of the screen while recording, on whichever display the pointer is on.
- **Paste at the cursor**, with the previous clipboard contents restored afterwards.
- **History window** with streak, word count and words-per-minute.
- **Optional hosted transcription** through any OpenAI-compatible endpoint.

## Download

Get `MiniDictate.dmg` from the [latest release](https://github.com/SidharthBhasin21/mini-dictate/releases/latest), then follow [Install on another Mac](#install-on-another-mac) for the first-launch step.

## Requirements

- Apple Silicon Mac
- macOS 13 or later
- To build: Xcode (or the Swift 5.9+ toolchain)

## Build and run

```bash
./build.sh
open MiniDictate.app
```

The first build fetches WhisperKit. The first launch downloads the Whisper model (about 145 MB) into `~/Library/Application Support/MiniDictate/models`; until that finishes, dictation falls back to Apple's built-in speech recognizer.

### Permissions

macOS asks for these on first use:

| Permission | Why |
|---|---|
| Accessibility | Detect the hotkey and send the paste keystroke |
| Microphone | Record while the key is held |
| Speech Recognition | Only for the Apple fallback recognizer |

The Settings page in the app shows the state of each one.

### Rebuilding resets Accessibility

The app is ad-hoc signed, so every rebuild looks like a new app to macOS and the Accessibility grant stops applying. After a rebuild, run:

```bash
pkill -x MiniDictate; tccutil reset Accessibility local.minidictate && open MiniDictate.app
```

then switch MiniDictate on again in System Settings → Privacy & Security → Accessibility. Signing with a Developer ID certificate would avoid this.

## Install on another Mac

```bash
./make-dmg.sh
```

This writes `dist/MiniDictate.dmg` without touching the app in the project folder. On the other Mac, drag the app to Applications. Because the app is not notarized, the first launch is blocked: open System Settings → Privacy & Security and click **Open Anyway**, or run

```bash
xattr -dr com.apple.quarantine /Applications/MiniDictate.app
```

## Configuration

Optional. Create `~/.minidictate.json`; changes apply to the next dictation.

| Key | Meaning | Default |
|---|---|---|
| `language` | Pin the language, e.g. `"en"` or `"hi"` | Detected per dictation |
| `apiKey` | Use a hosted transcription API instead of on-device Whisper | Not set |
| `endpoint` | OpenAI-compatible transcription URL | `https://api.openai.com/v1/audio/transcriptions` |
| `model` | Hosted model name | `whisper-1` |

Example, pinning English:

```json
{ "language": "en" }
```

With `apiKey` set, audio is uploaded to that endpoint. The key is stored in this file as plain text.

## How it works

1. A `CGEventTap` watches modifier-key changes for right Option.
2. While the key is held, `AVAudioEngine` records the microphone, converted to 16 kHz mono 16-bit PCM. The loudness of each chunk drives the waveform.
3. On release, the audio goes to the first available engine: the hosted API if a key is configured, otherwise Whisper, otherwise Apple's recognizer.
4. The text is written to the clipboard, Cmd+V is posted to the focused app, and the previous clipboard contents are restored about half a second later.

## Project layout

```
Package.swift
build.sh                  builds MiniDictate.app
make-dmg.sh               builds dist/MiniDictate.dmg
Sources/MiniDictate/
  main.swift              app delegate, hotkey listener, dictation flow
  Core.swift              config, log, recorder, transcriber, paste
  Whisper.swift           WhisperKit engine
  UI.swift                hub window, settings, waveform pill
```

## Data on your Mac

| What | Where |
|---|---|
| Dictation history (plain text, last 200) | `~/Library/Application Support/MiniDictate/history.json` |
| Whisper model | `~/Library/Application Support/MiniDictate/models` |
| Log (step names and key codes, never transcript text) | `~/Library/Logs/MiniDictate.log` |

## Troubleshooting

- **Nothing happens when holding right Option:** check Settings in the app. If Accessibility is off, use the reset command above. If Accessibility is on but the key listener is off, quit and reopen the app.
- **Checking a step:** the log shows each stage of a dictation (key down, seconds recorded, engine used, characters transcribed).
- **Testing transcription without the microphone:**
  ```bash
  MiniDictate.app/Contents/MacOS/MiniDictate --transcribe clip.wav
  ```
  The file must be 16 kHz mono 16-bit WAV.
- **Demo mode:** opens the app with sample data and no microphone, hotkey or real history. This is how the screenshots above were taken.
  ```bash
  .build/release/MiniDictate --demo home        # or: settings, recording
  ```

## Known limits

- Paste assumes the V key is in its QWERTY position.
- Typing Option characters with the right Option key also starts a recording.
- Whisper `base` is a small model; expect mistakes on names, accents and fast speech.
- Mixed Hindi-English (Hinglish) speech is not handled well by this model.
