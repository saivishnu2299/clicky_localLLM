# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->

## Overview

Clicky is a local-first macOS menu bar companion app. It lives entirely in the macOS status bar with no dock icon and no main window. Clicking the menu bar icon opens a floating panel with companion controls. Holding `ctrl + option` records push-to-talk audio, transcribes it locally, sends the transcript plus optional screenshots to a local Ollama model, speaks the answer with the system voice, and can point at UI elements with the existing `[POINT:x,y:label:screenN]` format.

The app no longer depends on a Cloudflare Worker or external AI APIs for chat, speech-to-text, or text-to-speech.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI with AppKit bridging for the status bar panel and full-screen overlay
- **Pattern**: MVVM with `@MainActor`, `@Published`, and async/await
- **Local Chat**: Ollama via `http://localhost:11434/api/chat`
- **Model Discovery**: Ollama `/api/tags` and `/api/show`
- **Speech-to-Text**: WhisperKit with Apple Speech file transcription as fallback
- **Text-to-Speech**: `AVSpeechSynthesizer`
- **Screen Capture**: ScreenCaptureKit with multi-monitor support
- **Voice Input**: `AVAudioEngine` + listen-only CGEvent tap for the global push-to-talk shortcut
- **Element Pointing**: The local model returns `[POINT:x,y:label:screenN]` tags that drive the existing cursor overlay animation
- **Analytics**: PostHog via `ClickyAnalytics.swift`

### Key Local Decisions

**Ollama model picker**: The panel lists all locally installed Ollama models. Cloud-backed entries returned by Ollama with `remote_host` are excluded. `gemma4:e4b` is the preferred default when it is installed. The panel can start Ollama, install the recommended model, and load the selected model into memory without terminal commands.

**Vision gating**: Screenshot capture is only used when the selected Ollama model reports `vision` capability. Text-only models remain selectable, but Clicky degrades to text-only assistance and suppresses pointing for that turn.

**Reasoning safety**: Conversation history stores only visible user and assistant text. Any model reasoning or thinking fields are ignored and never persisted, displayed, or passed back as future context.

**Buffered WhisperKit flow**: Push-to-talk audio is buffered locally and transcribed when the user releases the shortcut. This preserves the existing interaction model without reworking the dictation state machine.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring-buddy/leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Creates `CompanionManager` and the panel manager. |
| `leanring-buddy/CompanionManager.swift` | ~1070 | Central state machine for push-to-talk, Ollama chat, local TTS, screenshot capture, model selection, and pointing. |
| `leanring-buddy/CompanionPanelView.swift` | ~800 | Panel UI for permissions, local runtime status, model picker, model readiness, and quit controls. |
| `leanring-buddy/OllamaModelCatalog.swift` | ~200 | Local Ollama model discovery plus in-app Ollama start, install, preload, and running-model status. |
| `leanring-buddy/OllamaChatClient.swift` | ~160 | Streaming Ollama chat client that only accumulates visible assistant output. |
| `leanring-buddy/WhisperKitTranscriptionProvider.swift` | ~290 | Local STT provider using WhisperKit with Apple Speech file transcription fallback. |
| `leanring-buddy/BuddyMicrophoneCaptureSession.swift` | ~90 | Per-turn microphone capture abstraction that creates a fresh `AVAudioEngine` session for each push-to-talk turn. |
| `leanring-buddy/LocalSpeechSynthesizer.swift` | ~70 | Local `AVSpeechSynthesizer` wrapper with start/stop/speaking state for the response pipeline. |
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

Before using the app, make sure Ollama for macOS is installed. Clicky can start Ollama, install the recommended model, and load the selected model directly from the panel.

**Do NOT run `xcodebuild` from the terminal**. It can invalidate TCC permissions and force macOS to re-request screen recording, accessibility, and related grants.

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
- Do not run `xcodebuild` from the terminal

## Self-Update Instructions

When you make changes that materially affect the architecture or key files list in this document, update this file. Minor edits and small bug fixes do not require documentation changes.
