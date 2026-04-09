# Local Architecture

## Stack

- App shell: SwiftUI + AppKit `NSStatusItem` / `NSPanel`
- Local chat: Ollama `POST /api/chat`
- Model discovery and readiness: Ollama `GET /api/tags`, `GET /api/ps`, `POST /api/show`, `POST /api/pull`, and `POST /api/generate`
- Speech-to-text: WhisperKit
- STT fallback: Apple Speech
- Text-to-speech: Kokoro in a managed local Python runtime, with Apple speech as a temporary fallback
- Screen capture: ScreenCaptureKit
- Overlay pointing: existing `[POINT:x,y:label:screenN]` parsing and overlay animation

## Request Flow

1. Clicky launches, refreshes the Ollama catalog, starts Ollama automatically if needed, resolves the saved or default installed model, and preloads that model into memory.
2. The global push-to-talk monitor captures `Control` + `Option` for the full app lifetime.
3. `BuddyDictationManager` records microphone audio with `AVAudioEngine`.
4. `WhisperKitTranscriptionProvider` buffers PCM16 audio locally and transcribes after key release.
5. If WhisperKit cannot initialize or transcribe the buffered file, the session falls back to Apple Speech file transcription.
6. `CompanionManager` checks the selected Ollama model capabilities.
7. If the selected model supports vision, Clicky captures screenshots and sends them with the prompt.
8. `OllamaChatClient` streams visible assistant content from the local Ollama daemon.
9. Clicky strips and parses any `[POINT:...]` suffix.
10. `LocalSpeechSynthesizer` prepares Kokoro if needed, synthesizes a WAV response through the bundled helper, and falls back to Apple speech only when Kokoro is not ready.
11. If a point tag is present, the overlay animates the blue cursor to the resolved screen coordinate.

## Capability Rules

- Only locally installed Ollama models are shown in the picker.
- Cloud-backed Ollama entries with `remote_host` are excluded.
- `gemma4:e4b` is preferred as the default when installed.
- Clicky auto-starts Ollama and auto-loads the saved or default installed model at launch.
- Non-vision models remain selectable, but Clicky degrades to text-only help for that turn and forces `[POINT:none]`.

## Reasoning Safety

- Conversation history stores only visible user transcripts and visible assistant replies.
- Ollama streaming chunks are parsed from `message.content` only.
- Any reasoning or thinking fields are ignored and never persisted, displayed, or reused as context.

## Local Runtime State

`OllamaModelCatalog` exposes three user-facing runtime states:

- Ollama unavailable
- Ollama reachable but no local models installed
- Ready with one or more local models

The panel surfaces that state directly so the user can see whether Clicky is automatically preparing Ollama, whether a local model still needs installation, and whether Kokoro is ready or temporarily falling back.
