# Local Setup

## 1. Install Ollama

Install Ollama for macOS. Clicky will start the Ollama app automatically on launch when it needs it.

Check that it is reachable:

```bash
ollama list
```

## 2. Install a Local Model

Clicky defaults to `gemma4:e4b` when it is available. You can install it directly from the Clicky panel after the app launches, and Clicky will automatically preload the saved or default installed model into Ollama.

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

The global `Control` + `Option` hotkey is installed at app launch and should work whether or not the panel is open.

## 5. First WhisperKit Run

On the first transcription request, WhisperKit may download its recommended on-device model into Application Support. That first run can take noticeably longer than later runs.

After the first successful load, the model stays local and later dictation turns are much faster.

## 6. Verify the Local Stack

Once the app is running:

1. Open the Clicky panel from the menu bar.
2. Wait for the panel to show Ollama as preparing or ready. If no local model is present, install the recommended model from the panel.
3. Confirm the selected model shows as loaded and ready without manually pressing a separate load button.
4. Confirm the speech row shows Kokoro preparing, ready, or temporary fallback status.
5. Hold `Control` + `Option` and speak, even if the panel is closed.
6. Release the hotkey to send the buffered audio for transcription and local model response.
7. If your selected model supports vision, Clicky should use screenshots and can point at UI elements.
8. If you switch to a text-only model, Clicky should still answer, but without screenshot-based pointing.

## 7. Kokoro Runtime Notes

Clicky provisions Kokoro under `~/Library/Application Support/Clicky/Kokoro`.

- `uv` is used to create a managed Python 3.12 environment.
- Kokoro is installed inside that local environment.
- Apple speech is used only while Kokoro is still provisioning or if the local Kokoro runtime cannot be prepared yet.
