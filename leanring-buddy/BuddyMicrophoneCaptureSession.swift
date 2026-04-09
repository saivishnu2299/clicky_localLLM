//
//  BuddyMicrophoneCaptureSession.swift
//  leanring-buddy
//
//  Per-turn microphone capture sessions for push-to-talk dictation.
//

import AVFoundation
import Foundation

enum BuddyMicrophoneCaptureError: LocalizedError {
    case noInputDevice
    case invalidInputFormat
    case failedToStart(underlyingDescription: String?)

    var isRetryable: Bool {
        if case .failedToStart = self {
            return true
        }

        return false
    }

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "clicky couldn't find an available microphone input."
        case .invalidInputFormat:
            return "clicky opened the microphone, but the audio format was invalid."
        case .failedToStart:
            return "clicky couldn't start microphone capture. try again. if it keeps failing, close other apps using the mic and reopen clicky."
        }
    }
}

protocol BuddyMicrophoneCaptureSession: AnyObject {
    func startCapturingAudio(
        onAudioBuffer: @escaping (AVAudioPCMBuffer) -> Void
    ) throws
    func stopCapturingAudio()
    func cancelCapture()
}

final class AVAudioEngineMicrophoneCaptureSession: BuddyMicrophoneCaptureSession {
    private var audioEngine: AVAudioEngine?

    func startCapturingAudio(
        onAudioBuffer: @escaping (AVAudioPCMBuffer) -> Void
    ) throws {
        cancelCapture()

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.channelCount > 0 else {
            throw BuddyMicrophoneCaptureError.noInputDevice
        }

        guard inputFormat.sampleRate > 0 else {
            throw BuddyMicrophoneCaptureError.invalidInputFormat
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            onAudioBuffer(buffer)
        }

        audioEngine.prepare()

        do {
            try audioEngine.start()
            self.audioEngine = audioEngine
        } catch {
            inputNode.removeTap(onBus: 0)
            audioEngine.stop()

            let underlyingDescription = error.localizedDescription
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BuddyMicrophoneCaptureError.failedToStart(
                underlyingDescription: underlyingDescription.isEmpty ? nil : underlyingDescription
            )
        }
    }

    func stopCapturingAudio() {
        guard let audioEngine else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        self.audioEngine = nil
    }

    func cancelCapture() {
        stopCapturingAudio()
    }

    deinit {
        cancelCapture()
    }
}
