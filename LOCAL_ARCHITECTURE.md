# Local Architecture

## Stack

- App shell: SwiftUI + AppKit `NSStatusItem` / `NSPanel`
- Local chat: Ollama `POST /api/chat`
- Model discovery and readiness: Ollama `GET /api/tags`, `GET /api/ps`, `POST /api/show`, `POST /api/pull`, and `POST /api/generate`
- Speech-to-text: WhisperKit
- STT fallback: Apple Speech
- Text-to-speech: `AVSpeechSynthesizer`
- Screen capture: ScreenCaptureKit
- Overlay pointing: existing `[POINT:x,y:label:screenN]` parsing and overlay animation

## Request Flow

1. The global push-to-talk monitor captures `Control` + `Option`.
2. `BuddyDictationManager` records microphone audio with `AVAudioEngine`.
3. `WhisperKitTranscriptionProvider` buffers PCM16 audio locally and transcribes after key release.
4. If WhisperKit cannot initialize or transcribe the buffered file, the session falls back to Apple Speech file transcription.
5. `CompanionManager` checks the selected Ollama model capabilities.
6. If the selected model supports vision, Clicky captures screenshots and sends them with the prompt.
7. `OllamaChatClient` streams visible assistant content from the local Ollama daemon.
8. Clicky strips and parses any `[POINT:...]` suffix.
9. The spoken response is played locally with `AVSpeechSynthesizer`.
10. If a point tag is present, the overlay animates the blue cursor to the resolved screen coordinate.

## Capability Rules

- Only locally installed Ollama models are shown in the picker.
- Cloud-backed Ollama entries with `remote_host` are excluded.
- `gemma4:e4b` is preferred as the default when installed.
- Non-vision models remain selectable, but Clicky degrades to text-only help for that turn and forces `[POINT:none]`.

## Reasoning Safety

- Conversation history stores only visible user transcripts and visible assistant replies.
- Ollama streaming chunks are parsed from `message.content` only.
- Any reasoning or thinking fields are ignored and never persisted, displayed, or reused as context.

## Local Runtime State

`OllamaModelCatalog` exposes three user-facing states:

- Ollama unavailable
- Ollama reachable but no local models installed
- Ready with one or more local models

The panel surfaces that state directly so the user can start Ollama, install the recommended model, load the selected model into memory, and fix local setup without digging into code or logs.
