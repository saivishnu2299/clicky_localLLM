# Local Setup

## 1. Install Ollama

Install Ollama for macOS and make sure the local daemon is running.

Check that it is reachable:

```bash
ollama list
```

## 2. Install a Local Model

Clicky defaults to `gemma4:e4b` when it is available. You can install and load it directly from the Clicky panel after the app launches, so terminal setup is optional.

If you prefer to verify Ollama separately first, you can still run:

```bash
ollama list
```

## 3. Open the Project in Xcode

```bash
open leanring-buddy.xcodeproj
```

In Xcode:

1. Select the `leanring-buddy` scheme.
2. Set your signing team.
3. Run the app with `Cmd + R`.

## 4. Grant Permissions

Clicky needs:

- Microphone
- Accessibility
- Screen Recording
- Screen Content
- Speech Recognition

Speech Recognition stays enabled because Apple Speech is used as the fallback transcription path when WhisperKit cannot complete locally.

## 5. First WhisperKit Run

On the first transcription request, WhisperKit may download its recommended on-device model into Application Support. That first run can take noticeably longer than later runs.

After the first successful load, the model stays local and later dictation turns are much faster.

## 6. Verify the Local Stack

Once the app is running:

1. Open the Clicky panel from the menu bar.
2. Use the panel to start Ollama if needed, install the recommended model if no local model is present, and confirm the selected model shows as loaded and ready.
3. Hold `Control` + `Option` and speak.
4. Release the hotkey to send the buffered audio for transcription and local model response.
5. If your selected model supports vision, Clicky should use screenshots and can point at UI elements.
6. If you switch to a text-only model, Clicky should still answer, but without screenshot-based pointing.
