//
//  BuddyMicrophoneCaptureSession.swift
//  leanring-buddy
//
//  Per-turn microphone capture sessions for push-to-talk dictation.
//

import AVFoundation
import CoreMedia
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

final class ResilientMicrophoneCaptureSession: BuddyMicrophoneCaptureSession {
    private let sessionFactories: [() -> any BuddyMicrophoneCaptureSession]
    private var activeCaptureSession: (any BuddyMicrophoneCaptureSession)?

    init(
        sessionFactories: [() -> any BuddyMicrophoneCaptureSession] = [
            { AVAudioEngineMicrophoneCaptureSession() },
            { AVCaptureSessionMicrophoneCaptureSession() }
        ]
    ) {
        self.sessionFactories = sessionFactories
    }

    func startCapturingAudio(
        onAudioBuffer: @escaping (AVAudioPCMBuffer) -> Void
    ) throws {
        cancelCapture()

        var lastError: Error?

        for (sessionIndex, sessionFactory) in sessionFactories.enumerated() {
            let captureSession = sessionFactory()

            do {
                try captureSession.startCapturingAudio(onAudioBuffer: onAudioBuffer)
                activeCaptureSession = captureSession

                if sessionIndex > 0 {
                    print("🎙️ Buddy microphone capture: using AVCapture fallback after AVAudioEngine startup failed")
                }

                return
            } catch {
                captureSession.cancelCapture()
                lastError = error

                if sessionIndex < sessionFactories.count - 1 {
                    print("⚠️ Buddy microphone capture: primary audio engine startup failed, falling back to AVCapture")
                }
            }
        }

        if let lastError {
            throw lastError
        }

        throw BuddyMicrophoneCaptureError.failedToStart(underlyingDescription: nil)
    }

    func stopCapturingAudio() {
        activeCaptureSession?.stopCapturingAudio()
        activeCaptureSession = nil
    }

    func cancelCapture() {
        activeCaptureSession?.cancelCapture()
        activeCaptureSession = nil
    }

    deinit {
        cancelCapture()
    }
}

final class AVCaptureSessionMicrophoneCaptureSession: NSObject, BuddyMicrophoneCaptureSession {
    private let configurationQueue = DispatchQueue(label: "com.clicky.microphone-capture.configuration")
    private let sampleBufferQueue = DispatchQueue(label: "com.clicky.microphone-capture.output")

    private var captureSession: AVCaptureSession?
    private var audioDataOutput: AVCaptureAudioDataOutput?
    private var sampleBufferDelegate: SampleBufferDelegate?

    func startCapturingAudio(
        onAudioBuffer: @escaping (AVAudioPCMBuffer) -> Void
    ) throws {
        cancelCapture()

        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            throw BuddyMicrophoneCaptureError.noInputDevice
        }

        let captureSession = AVCaptureSession()
        let audioDataOutput = AVCaptureAudioDataOutput()
        let sampleBufferDelegate = SampleBufferDelegate { sampleBuffer in
            guard let audioBuffer = Self.makeAudioPCMBuffer(from: sampleBuffer) else { return }
            onAudioBuffer(audioBuffer)
        }

        do {
            let deviceInput = try AVCaptureDeviceInput(device: audioDevice)

            captureSession.beginConfiguration()

            guard captureSession.canAddInput(deviceInput) else {
                captureSession.commitConfiguration()
                throw BuddyMicrophoneCaptureError.failedToStart(
                    underlyingDescription: "Clicky couldn't attach the selected microphone input."
                )
            }
            captureSession.addInput(deviceInput)

            guard captureSession.canAddOutput(audioDataOutput) else {
                captureSession.commitConfiguration()
                throw BuddyMicrophoneCaptureError.failedToStart(
                    underlyingDescription: "Clicky couldn't create the microphone output stream."
                )
            }
            captureSession.addOutput(audioDataOutput)

            audioDataOutput.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: true
            ]
            audioDataOutput.setSampleBufferDelegate(sampleBufferDelegate, queue: sampleBufferQueue)

            captureSession.commitConfiguration()

            self.captureSession = captureSession
            self.audioDataOutput = audioDataOutput
            self.sampleBufferDelegate = sampleBufferDelegate

            configurationQueue.sync {
                captureSession.startRunning()
            }

            guard captureSession.isRunning else {
                cancelCapture()
                throw BuddyMicrophoneCaptureError.failedToStart(
                    underlyingDescription: "AVCaptureSession failed to start the microphone stream."
                )
            }
        } catch let microphoneCaptureError as BuddyMicrophoneCaptureError {
            cancelCapture()
            throw microphoneCaptureError
        } catch {
            cancelCapture()

            let underlyingDescription = error.localizedDescription
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BuddyMicrophoneCaptureError.failedToStart(
                underlyingDescription: underlyingDescription.isEmpty ? nil : underlyingDescription
            )
        }
    }

    func stopCapturingAudio() {
        let activeCaptureSession = captureSession
        let activeAudioDataOutput = audioDataOutput

        captureSession = nil
        audioDataOutput = nil
        sampleBufferDelegate = nil

        activeAudioDataOutput?.setSampleBufferDelegate(nil, queue: nil)

        configurationQueue.sync {
            guard let activeCaptureSession, activeCaptureSession.isRunning else { return }
            activeCaptureSession.stopRunning()
        }
    }

    func cancelCapture() {
        stopCapturingAudio()
    }

    private static func makeAudioPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescriptionPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        var streamDescription = streamDescriptionPointer.pointee
        guard let audioFormat = AVAudioFormat(streamDescription: &streamDescription) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let audioBuffer = AVAudioPCMBuffer(
                  pcmFormat: audioFormat,
                  frameCapacity: frameCount
              ) else {
            return nil
        }

        audioBuffer.frameLength = frameCount

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: audioBuffer.mutableAudioBufferList
        )

        guard copyStatus == noErr else {
            return nil
        }

        return audioBuffer
    }

    deinit {
        cancelCapture()
    }
}

private final class SampleBufferDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let onSampleBuffer: (CMSampleBuffer) -> Void

    init(onSampleBuffer: @escaping (CMSampleBuffer) -> Void) {
        self.onSampleBuffer = onSampleBuffer
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSampleBuffer(sampleBuffer)
    }
}
