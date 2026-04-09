//
//  WhisperKitTranscriptionProvider.swift
//  leanring-buddy
//
//  Local speech transcription using WhisperKit with Apple Speech fallback.
//

import AVFoundation
import Foundation
import Speech
import WhisperKit

struct WhisperKitTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

enum LocalFileTranscriptionFallback {
    static func transcribe(
        primaryTranscription: @escaping @Sendable () async throws -> String,
        fallbackTranscription: @escaping @Sendable () async throws -> String,
        primaryTimeoutSeconds: TimeInterval = 12
    ) async throws -> String {
        do {
            return try await withThrowingTaskGroup(of: String.self) { taskGroup in
                taskGroup.addTask {
                    try await primaryTranscription()
                }

                taskGroup.addTask {
                    try await Task.sleep(nanoseconds: UInt64(primaryTimeoutSeconds * 1_000_000_000))
                    throw WhisperKitTranscriptionProviderError(
                        message: "WhisperKit took too long to finish, so Clicky is falling back to Apple Speech."
                    )
                }

                let transcriptText = try await taskGroup.next() ?? ""
                taskGroup.cancelAll()
                return transcriptText
            }
        } catch {
            return try await fallbackTranscription()
        }
    }
}

enum WhisperKitFileTranscriptionPipeline {
    static func transcribeAudioFile(
        at audioFileURL: URL,
        contextualKeyterms: [String],
        primaryTranscription: (@Sendable (URL) async throws -> String)? = nil,
        fallbackTranscription: (@Sendable (URL, [String]) async throws -> String)? = nil
    ) async throws -> String {
        let resolvedPrimaryTranscription = primaryTranscription ?? { audioFileURL in
            try await WhisperKitRuntime.shared.transcribeAudioFile(at: audioFileURL)
        }

        let resolvedFallbackTranscription = fallbackTranscription ?? { audioFileURL, contextualKeyterms in
            try await AppleSpeechFileTranscriber.transcribeAudioFile(
                at: audioFileURL,
                contextualKeyterms: contextualKeyterms
            )
        }

        return try await LocalFileTranscriptionFallback.transcribe(
            primaryTranscription: {
                try await resolvedPrimaryTranscription(audioFileURL)
            },
            fallbackTranscription: {
                try await resolvedFallbackTranscription(audioFileURL, contextualKeyterms)
            }
        )
    }
}

final class WhisperKitTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "WhisperKit"
    let requiresSpeechRecognitionPermission = true
    let isConfigured = true
    let unavailableExplanation: String? = nil

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        return WhisperKitTranscriptionSession(
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private actor WhisperKitRuntime {
    static let shared = WhisperKitRuntime()

    private var activeWhisperKit: WhisperKit?
    private var activeInitializationTask: Task<WhisperKit, Error>?

    func transcribeAudioFile(at audioFileURL: URL) async throws -> String {
        let whisperKit = try await sharedWhisperKit()
        let transcriptionResults: [TranscriptionResult] = try await whisperKit.transcribe(
            audioPath: audioFileURL.path,
            decodeOptions: DecodingOptions(
                verbose: false,
                withoutTimestamps: true,
                wordTimestamps: false
            )
        )

        let fullTranscript = transcriptionResults
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !fullTranscript.isEmpty else {
            throw WhisperKitTranscriptionProviderError(
                message: "WhisperKit returned an empty transcript."
            )
        }

        return fullTranscript
    }

    private func sharedWhisperKit() async throws -> WhisperKit {
        if let activeWhisperKit {
            return activeWhisperKit
        }

        if let activeInitializationTask {
            return try await activeInitializationTask.value
        }

        let initializationTask = Task<WhisperKit, Error> {
            let whisperKitConfig = WhisperKitConfig(
                downloadBase: Self.modelStorageDirectoryURL,
                verbose: false
            )

            return try await WhisperKit(whisperKitConfig)
        }

        activeInitializationTask = initializationTask

        do {
            let whisperKit = try await initializationTask.value
            activeWhisperKit = whisperKit
            activeInitializationTask = nil
            return whisperKit
        } catch {
            activeInitializationTask = nil
            throw error
        }
    }

    private static var modelStorageDirectoryURL: URL {
        let applicationSupportDirectoryURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support", isDirectory: true)

        let clickyDirectoryURL = applicationSupportDirectoryURL
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("WhisperKit", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: clickyDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        return clickyDirectoryURL
    }
}

final class WhisperKitTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 18

    private static let targetSampleRate = 16_000

    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void
    private let transcriptionPipeline: @Sendable (URL, [String]) async throws -> String

    private let stateQueue = DispatchQueue(label: "com.clicky.whisperkit.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(targetSampleRate)
    )

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var transcriptionTask: Task<Void, Never>?

    init(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void,
        transcriptionPipeline: @escaping @Sendable (URL, [String]) async throws -> String = { audioFileURL, keyterms in
            try await WhisperKitFileTranscriptionPipeline.transcribeAudioFile(
                at: audioFileURL,
                contextualKeyterms: keyterms
            )
        }
    ) {
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
        self.transcriptionPipeline = transcriptionPipeline
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let bufferedPCM16AudioData = self.bufferedPCM16AudioData
            self.transcriptionTask = Task { [weak self] in
                await self?.transcribeBufferedAudio(bufferedPCM16AudioData)
            }
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }

        transcriptionTask?.cancel()
        transcriptionTask = nil
    }

    private func transcribeBufferedAudio(_ bufferedPCM16AudioData: Data) async {
        guard !Task.isCancelled else { return }

        let shouldFinishImmediately = stateQueue.sync {
            isCancelled || bufferedPCM16AudioData.isEmpty
        }

        if shouldFinishImmediately {
            deliverFinalTranscript("")
            return
        }

        let wavAudioData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: bufferedPCM16AudioData,
            sampleRate: Self.targetSampleRate
        )

        let temporaryAudioFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-\(UUID().uuidString).wav")

        do {
            try wavAudioData.write(to: temporaryAudioFileURL, options: .atomic)

            let transcriptText = try await transcriptionPipeline(temporaryAudioFileURL, keyterms)

            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }

            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            onError(error)
        }

        try? FileManager.default.removeItem(at: temporaryAudioFileURL)
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        stateQueue.async {
            guard !self.hasDeliveredFinalTranscript else { return }
            self.hasDeliveredFinalTranscript = true
            let finalTranscriptText = transcriptText

            DispatchQueue.main.async {
                self.onFinalTranscriptReady(finalTranscriptText)
            }
        }
    }
}

private enum AppleSpeechFileTranscriber {
    static func transcribeAudioFile(
        at audioFileURL: URL,
        contextualKeyterms: [String]
    ) async throws -> String {
        guard let speechRecognizer = makeBestAvailableSpeechRecognizer() else {
            throw WhisperKitTranscriptionProviderError(
                message: "Speech recognition is not available on this mac."
            )
        }

        let recognitionRequest = SFSpeechURLRecognitionRequest(url: audioFileURL)
        recognitionRequest.shouldReportPartialResults = false
        recognitionRequest.addsPunctuation = true
        if speechRecognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
        }

        if !contextualKeyterms.isEmpty {
            recognitionRequest.contextualStrings = contextualKeyterms
        }

        return try await withCheckedThrowingContinuation { continuation in
            var recognitionTask: SFSpeechRecognitionTask?
            var hasCompleted = false
            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { result, error in
                if let result, result.isFinal {
                    guard !hasCompleted else { return }
                    hasCompleted = true
                    recognitionTask?.cancel()
                    continuation.resume(
                        returning: result.bestTranscription.formattedString
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    return
                }

                if let error {
                    guard !hasCompleted else { return }
                    hasCompleted = true
                    recognitionTask?.cancel()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func makeBestAvailableSpeechRecognizer() -> SFSpeechRecognizer? {
        let preferredLocales = [
            Locale.autoupdatingCurrent,
            Locale(identifier: "en-US")
        ]

        for preferredLocale in preferredLocales {
            if let speechRecognizer = SFSpeechRecognizer(locale: preferredLocale) {
                return speechRecognizer
            }
        }

        return SFSpeechRecognizer()
    }
}
