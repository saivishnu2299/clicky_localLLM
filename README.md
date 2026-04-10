# Clicky (IN PROGRESS)

Clicky is a local-first macOS menu bar assistant that lives next to your cursor. It uses push-to-talk voice input, captures screenshots only when you ask it to, answers through a local Ollama model, speaks with the system voice, and can point at UI elements with `[POINT:x,y:label:screenN]` tags.

This fork removes the old Cloudflare Worker and cloud AI stack. The app now runs with:

- Ollama for local multimodal chat
- WhisperKit for on-device speech-to-text
- Apple Speech as the local fallback transcription path
- `AVSpeechSynthesizer` for local text-to-speech

## Requirements

- Apple silicon Mac
- macOS 14.2+
- Xcode 16+
- Ollama for macOS installed

`gemma4:e4b` is the preferred default model, and the Clicky panel can install and load it directly.

## Quick Start

1. Install Ollama for macOS.
2. Open `leanring-buddy.xcodeproj` in Xcode.
3. Select the `leanring-buddy` scheme, set your signing team, and run the app from Xcode.
4. Grant Microphone, Accessibility, Screen Recording, and Screen Content permissions.
5. Use the Clicky panel to start Ollama if needed, install the recommended model if none are present, and load the selected model.

For the local setup checklist, see [LOCAL_SETUP.md](LOCAL_SETUP.md).

For the new runtime architecture, see [LOCAL_ARCHITECTURE.md](LOCAL_ARCHITECTURE.md).

## How It Works

- Hold `Control` + `Option` to talk.
- Clicky captures microphone audio locally.
- WhisperKit transcribes the buffered push-to-talk audio on release.
- Clicky captures screenshots when the selected Ollama model supports vision.
- Ollama streams the response back locally.
- The visible response is spoken with the macOS system voice.
- If the response ends with a `[POINT:...]` tag, the overlay animates the blue cursor to that location.

## Notes

- Non-vision Ollama models are still selectable. When you choose one, Clicky falls back to text-only help for that turn and suppresses pointing.
- The app never stores or displays model reasoning or thought traces in conversation history.
- Do not run `xcodebuild` from the terminal for this project. Run from Xcode so the macOS privacy permissions stay intact.
