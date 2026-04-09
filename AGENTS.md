# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->

## Overview

Clicky is a local-first macOS menu bar companion app. It lives entirely in the macOS status bar with no dock icon and no main window. Clicking the menu bar icon opens a floating panel with companion controls. Holding the left `control` key records push-to-talk audio globally, transcribes it locally, sends the transcript plus optional screenshots to a local Ollama model, speaks the answer with local speech synthesis, and can point at UI elements with the existing `[POINT:x,y:label:screenN]` format.

The app no longer depends on a Cloudflare Worker or external AI APIs for chat, speech-to-text, or text-to-speech.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI with AppKit bridging for the status bar panel and full-screen overlay
- **Pattern**: MVVM with `@MainActor`, `@Published`, and async/await
- **Local Chat**: Ollama via `http://localhost:11434/api/chat`
- **Model Discovery**: Ollama `/api/tags` and `/api/show`
- **Speech-to-Text**: WhisperKit with Apple Speech file transcription as fallback
- **Text-to-Speech**: Kokoro with Apple speech as a temporary local fallback while Kokoro is provisioning or unavailable
- **Screen Capture**: ScreenCaptureKit with multi-monitor support
- **Voice Input**: `AVAudioEngine` with `AVCaptureSession` fallback + listen-only CGEvent tap for the global push-to-talk shortcut
- **Element Pointing**: The local model returns `[POINT:x,y:label:screenN]` tags that drive the existing cursor overlay animation
- **Analytics**: PostHog via `ClickyAnalytics.swift`

### Key Local Decisions

**Ollama readiness**: On app launch, Clicky refreshes the Ollama catalog, starts Ollama automatically if needed, resolves the saved or default installed model, and preloads that model into memory. The panel still exposes manual retry and install controls, but the normal path is "Clicky opens, Ollama is made ready in the background."

**Ollama model picker**: The panel lists all locally installed Ollama models. Cloud-backed entries returned by Ollama with `remote_host` are excluded. `gemma4:e4b` is the preferred default when it is installed. Changing the selected model immediately triggers a reload path so the new choice is the next model used.

**Vision gating**: Screenshot capture is only used when the selected Ollama model reports `vision` capability. Text-only models remain selectable, but Clicky degrades to text-only assistance and suppresses pointing for that turn.

**Reasoning safety**: Conversation history stores only visible user and assistant text. Any model reasoning or thinking fields are ignored and never persisted, displayed, or passed back as future context.

**Buffered WhisperKit flow**: Push-to-talk audio is buffered locally and transcribed when the user releases the shortcut. This preserves the existing interaction model without reworking the dictation state machine.

**Global hotkey**: The left `Control` push-to-talk monitor is installed at launch and kept alive for the full app lifetime. It is not tied to panel visibility.

**Managed Kokoro runtime**: Clicky provisions a Kokoro runtime under Application Support with a Python 3.10-3.12 environment and a bundled helper script. It prefers `uv` when available, but falls back to a compatible local `python3.x` when needed. Apple speech remains only as a temporary fallback until Kokoro is ready.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring-buddy/leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Creates `CompanionManager` and the panel manager. |
| `leanring-buddy/CompanionManager.swift` | ~1100 | Central state machine for push-to-talk, Ollama auto-start/preload, local speech runtime state, screenshot capture, model selection, and pointing. |
| `leanring-buddy/CompanionPanelView.swift` | ~820 | Panel UI for permissions, Ollama readiness, Kokoro speech status, model picker, and quit controls. |
| `leanring-buddy/OllamaModelCatalog.swift` | ~200 | Local Ollama model discovery plus in-app Ollama start, install, preload, and running-model status. |
| `leanring-buddy/GlobalPushToTalkShortcutMonitor.swift` | ~220 | Dedicated lifetime-long global event tap for left-Control push-to-talk. |
| `leanring-buddy/OllamaChatClient.swift` | ~160 | Streaming Ollama chat client that only accumulates visible assistant output. |
| `leanring-buddy/WhisperKitTranscriptionProvider.swift` | ~290 | Local STT provider using WhisperKit with Apple Speech file transcription fallback. |
| `leanring-buddy/BuddyMicrophoneCaptureSession.swift` | ~320 | Per-turn microphone capture abstraction that prefers a fresh `AVAudioEngine` session for each push-to-talk turn and falls back to `AVCaptureSession` when CoreAudio refuses to start the engine. |
| `leanring-buddy/LocalSpeechSynthesizer.swift` | ~340 | Kokoro-backed local speech runtime manager with Apple speech fallback, playback state, and Application Support provisioning. |
| `leanring-buddy/kokoro_tts.py` | ~90 | Bundled helper script that synthesizes WAV output from Kokoro inside the managed Python runtime. |
| `leanring-buddy/BuddyDictationManager.swift` | ~850 | Shared push-to-talk audio pipeline and transcription session coordination. |
| `leanring-buddy/BuddyTranscriptionProvider.swift` | ~60 | Provider abstraction and local-only provider resolution. |
| `leanring-buddy/AppleSpeechTranscriptionProvider.swift` | ~147 | Live Apple Speech provider kept as the fallback-compatible local recognizer implementation. |
| `leanring-buddy/CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. |
| `leanring-buddy/OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the cursor, spinner, waveform, and pointing animation. |
| `leanring-buddy/DesignSystem.swift` | ~880 | Shared design tokens and panel styling. |
| `LOCAL_SETUP.md` | ~55 | Local setup instructions for Ollama, WhisperKit, and Xcode. |
| `LOCAL_ARCHITECTURE.md` | ~50 | Summary of the local runtime stack and request flow. |

## Build & Run

```bash
open leanring-buddy.xcodeproj
```

In Xcode:

1. Select the `leanring-buddy` scheme.
2. Set your signing team.
3. Run with `Cmd + R`.

Before using the app, make sure Ollama for macOS is installed. Clicky now starts Ollama automatically on launch, resolves the saved or default installed model, and preloads it. If no local model exists yet, the panel stays in setup mode and offers the recommended install flow.

**Do NOT run `xcodebuild` from the terminal unless the user explicitly asks for terminal-side build verification**. It can invalidate TCC permissions and force macOS to re-request screen recording, accessibility, and related grants.

## Code Style & Conventions

### Variable and Method Naming

- Prefer explicit, descriptive names over short names
- Keep argument names aligned with the source variable names when passing values through
- Optimize for immediate readability by someone who has no project context

### Code Clarity

- Clear is better than clever
- Add a short comment only when the why is not obvious from the code
- Do not add unrelated refactors or “cleanup” outside the requested change

### Swift / SwiftUI Conventions

- Use SwiftUI for UI unless AppKit is required
- Keep UI state updates on `@MainActor`
- Use async/await for asynchronous work
- All buttons and interactive controls should show pointer cursor feedback on hover

### Do NOT

- Do not reintroduce cloud chat, cloud STT, or cloud TTS dependencies
- Do not store or expose model reasoning / thinking output
- Do not rename the project directory or scheme (`leanring` stays)
- Do not run `xcodebuild` from the terminal unless the user explicitly asks for it

## Self-Update Instructions

When you make changes that materially affect the architecture or key files list in this document, update this file. Minor edits and small bug fixes do not require documentation changes.
