//
//  VoicePipelineTests.swift
//  leanring-buddyTests
//

import AVFoundation
import Foundation
import Testing
@testable import Clicky

@Suite(.serialized)
@MainActor
struct VoicePipelineTests {
    private struct SessionCallbacks {
        let onTranscriptUpdate: (String) -> Void
        let onFinalTranscriptReady: (String) -> Void
        let onError: (Error) -> Void
    }

    private final class TestStreamingSession: BuddyStreamingTranscriptionSession {
        let finalTranscriptFallbackDelaySeconds: TimeInterval

        private let callbacks: SessionCallbacks
        private let finalTranscriptOnRequest: String
        private let finalTranscriptDelayNanoseconds: UInt64
        private let automaticallyEmitFinalTranscriptOnRequest: Bool

        private(set) var appendedBufferCount = 0
        private(set) var requestFinalTranscriptCallCount = 0
        private(set) var cancelCallCount = 0
        private var hasRequestedFinalTranscript = false

        init(
            callbacks: SessionCallbacks,
            finalTranscriptOnRequest: String,
            finalTranscriptFallbackDelaySeconds: TimeInterval = 0.01,
            finalTranscriptDelayNanoseconds: UInt64 = 0,
            automaticallyEmitFinalTranscriptOnRequest: Bool = true
        ) {
            self.callbacks = callbacks
            self.finalTranscriptOnRequest = finalTranscriptOnRequest
            self.finalTranscriptFallbackDelaySeconds = finalTranscriptFallbackDelaySeconds
            self.finalTranscriptDelayNanoseconds = finalTranscriptDelayNanoseconds
            self.automaticallyEmitFinalTranscriptOnRequest = automaticallyEmitFinalTranscriptOnRequest
        }

        func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
            appendedBufferCount += 1
        }

        func requestFinalTranscript() {
            guard !hasRequestedFinalTranscript else { return }

            hasRequestedFinalTranscript = true
            requestFinalTranscriptCallCount += 1

            guard automaticallyEmitFinalTranscriptOnRequest else { return }

            emitFinalTranscriptNow()
        }

        func emitFinalTranscriptNow() {
            Task {
                if finalTranscriptDelayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: finalTranscriptDelayNanoseconds)
                }

                await MainActor.run {
                    self.callbacks.onFinalTranscriptReady(self.finalTranscriptOnRequest)
                }
            }
        }

        func cancel() {
            cancelCallCount += 1
        }
    }

    private final class TestTranscriptionProvider: BuddyTranscriptionProvider {
        let displayName = "Test Provider"
        let requiresSpeechRecognitionPermission = false
        let isConfigured = true
        let unavailableExplanation: String? = nil

        private let startDelayNanoseconds: UInt64
        private let sessionBuilder: (SessionCallbacks) -> TestStreamingSession
        private(set) var startStreamingSessionCallCount = 0
        private(set) var lastSession: TestStreamingSession?

        init(
            startDelayNanoseconds: UInt64 = 0,
            sessionBuilder: @escaping (SessionCallbacks) -> TestStreamingSession
        ) {
            self.startDelayNanoseconds = startDelayNanoseconds
            self.sessionBuilder = sessionBuilder
        }

        func startStreamingSession(
            keyterms: [String],
            onTranscriptUpdate: @escaping (String) -> Void,
            onFinalTranscriptReady: @escaping (String) -> Void,
            onError: @escaping (Error) -> Void
        ) async throws -> any BuddyStreamingTranscriptionSession {
            startStreamingSessionCallCount += 1

            if startDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: startDelayNanoseconds)
            }

            let session = sessionBuilder(
                SessionCallbacks(
                    onTranscriptUpdate: onTranscriptUpdate,
                    onFinalTranscriptReady: onFinalTranscriptReady,
                    onError: onError
                )
            )
            lastSession = session
            return session
        }
    }

    private final class TestMicrophoneCaptureSession: BuddyMicrophoneCaptureSession {
        private let startError: Error?
        private(set) var startCallCount = 0
        private(set) var stopCallCount = 0
        private(set) var cancelCallCount = 0

        init(startError: Error? = nil) {
            self.startError = startError
        }

        func startCapturingAudio(
            onAudioBuffer: @escaping (AVAudioPCMBuffer) -> Void
        ) throws {
            startCallCount += 1
            if let startError {
                throw startError
            }
        }

        func stopCapturingAudio() {
            stopCallCount += 1
        }

        func cancelCapture() {
            cancelCallCount += 1
        }
    }

    private final class TestMicrophoneCaptureSessionFactory {
        private(set) var createdSessions: [TestMicrophoneCaptureSession] = []
        private var queuedSessions: [TestMicrophoneCaptureSession]

        init(queuedSessions: [TestMicrophoneCaptureSession]) {
            self.queuedSessions = queuedSessions
        }

        func makeSession() -> any BuddyMicrophoneCaptureSession {
            let session = queuedSessions.isEmpty ? TestMicrophoneCaptureSession() : queuedSessions.removeFirst()
            createdSessions.append(session)
            return session
        }
    }

    private final class TestOllamaModelCatalog: OllamaModelCataloging {
        private(set) var preloadModelNames: [String] = []

        func fetchCatalogSnapshot() async -> OllamaModelCatalogSnapshot {
            OllamaModelCatalogSnapshot(models: [], runtimeStatus: .ready, loadedModelNames: [])
        }

        func startOllamaApp() async -> Bool {
            true
        }

        func pullModel(
            named modelName: String,
            onProgress: @escaping @Sendable (OllamaPullProgress) -> Void
        ) async throws {}

        func preloadModel(named modelName: String) async throws {
            preloadModelNames.append(modelName)
        }
    }

    private final class TestOllamaChatClient: OllamaChatStreaming {
        private let responseText: String
        private(set) var streamedUserPrompts: [String] = []

        init(responseText: String) {
            self.responseText = responseText
        }

        func streamChatResponse(
            modelName: String,
            images: [(data: Data, label: String)],
            systemPrompt: String,
            conversationHistory: [(userPrompt: String, assistantResponse: String)],
            userPrompt: String,
            onTextChunk: @MainActor @Sendable (String) -> Void
        ) async throws -> String {
            streamedUserPrompts.append(userPrompt)
            await onTextChunk(responseText)
            return responseText
        }
    }

    private final class TestLocalSpeechSynthesizer: LocalSpeechSynthesizing {
        private(set) var spokenTexts: [String] = []
        private(set) var stopCallCount = 0
        var isSpeaking = false

        func speakText(_ text: String) async {
            isSpeaking = true
            spokenTexts.append(text)
            isSpeaking = false
        }

        func stopPlayback() {
            stopCallCount += 1
            isSpeaking = false
        }
    }

    @Test func successfulKeyboardShortcutSessionRecordsFinalTranscript() async throws {
        let provider = TestTranscriptionProvider { callbacks in
            TestStreamingSession(
                callbacks: callbacks,
                finalTranscriptOnRequest: "hello clicky"
            )
        }
        let captureFactory = TestMicrophoneCaptureSessionFactory(
            queuedSessions: [TestMicrophoneCaptureSession()]
        )
        let manager = BuddyDictationManager(
            transcriptionProvider: provider,
            microphoneCaptureSessionFactory: { captureFactory.makeSession() },
            permissionRequester: { true },
            defaultFinalTranscriptFallbackDelaySeconds: 0.01
        )

        var submittedDrafts: [String] = []

        await manager.startPushToTalkFromKeyboardShortcut(
            currentDraftText: "",
            updateDraftText: { _ in },
            submitDraftText: { submittedDrafts.append($0) }
        )

        #expect(manager.isRecordingFromKeyboardShortcut)
        #expect(captureFactory.createdSessions.count == 1)

        manager.stopPushToTalkFromKeyboardShortcut()

        try await waitUntil {
            submittedDrafts.count == 1 && !manager.isDictationInProgress
        }

        #expect(submittedDrafts == ["hello clicky"])
        #expect(!manager.isKeyboardShortcutSessionActiveOrFinalizing)
    }

    @Test func microphoneCaptureStartupRetriesWithFreshSession() async throws {
        let provider = TestTranscriptionProvider { callbacks in
            TestStreamingSession(
                callbacks: callbacks,
                finalTranscriptOnRequest: ""
            )
        }
        let captureFactory = TestMicrophoneCaptureSessionFactory(
            queuedSessions: [
                TestMicrophoneCaptureSession(
                    startError: BuddyMicrophoneCaptureError.failedToStart(
                        underlyingDescription: "first start failed"
                    )
                ),
                TestMicrophoneCaptureSession()
            ]
        )
        let manager = BuddyDictationManager(
            transcriptionProvider: provider,
            microphoneCaptureSessionFactory: { captureFactory.makeSession() },
            permissionRequester: { true },
            defaultFinalTranscriptFallbackDelaySeconds: 0.01
        )

        await manager.startPushToTalkFromKeyboardShortcut(
            currentDraftText: "",
            updateDraftText: { _ in },
            submitDraftText: { _ in }
        )

        #expect(manager.isRecordingFromKeyboardShortcut)
        #expect(captureFactory.createdSessions.count == 2)
        #expect(captureFactory.createdSessions[0].cancelCallCount == 1)
        #expect(captureFactory.createdSessions[1].startCallCount == 1)

        manager.stopPushToTalkFromKeyboardShortcut()
    }

    @Test func quickPressAndReleaseDoesNotStrandDictationState() async throws {
        let provider = TestTranscriptionProvider(
            startDelayNanoseconds: 50_000_000
        ) { callbacks in
            TestStreamingSession(
                callbacks: callbacks,
                finalTranscriptOnRequest: ""
            )
        }
        let captureFactory = TestMicrophoneCaptureSessionFactory(queuedSessions: [])
        let manager = BuddyDictationManager(
            transcriptionProvider: provider,
            microphoneCaptureSessionFactory: { captureFactory.makeSession() },
            permissionRequester: { true },
            defaultFinalTranscriptFallbackDelaySeconds: 0.01
        )

        let startTask = Task {
            await manager.startPushToTalkFromKeyboardShortcut(
                currentDraftText: "",
                updateDraftText: { _ in },
                submitDraftText: { _ in }
            )
        }

        await Task.yield()
        startTask.cancel()
        manager.stopPushToTalkFromKeyboardShortcut()
        await startTask.value

        try await waitUntil {
            !manager.isDictationInProgress && !manager.isKeyboardShortcutSessionActiveOrFinalizing
        }

        #expect(captureFactory.createdSessions.isEmpty)
        #expect(manager.lastErrorMessage == nil)
    }

    @Test func repeatedShortcutPressIsIgnoredWhileFinalizing() async throws {
        let provider = TestTranscriptionProvider { callbacks in
            TestStreamingSession(
                callbacks: callbacks,
                finalTranscriptOnRequest: "first request",
                finalTranscriptFallbackDelaySeconds: 0.05,
                finalTranscriptDelayNanoseconds: 0,
                automaticallyEmitFinalTranscriptOnRequest: false
            )
        }
        let captureFactory = TestMicrophoneCaptureSessionFactory(
            queuedSessions: [TestMicrophoneCaptureSession()]
        )
        let manager = BuddyDictationManager(
            transcriptionProvider: provider,
            microphoneCaptureSessionFactory: { captureFactory.makeSession() },
            permissionRequester: { true },
            defaultFinalTranscriptFallbackDelaySeconds: 0.01
        )

        var submittedDrafts: [String] = []

        await manager.startPushToTalkFromKeyboardShortcut(
            currentDraftText: "",
            updateDraftText: { _ in },
            submitDraftText: { submittedDrafts.append($0) }
        )
        manager.stopPushToTalkFromKeyboardShortcut()

        #expect(manager.isFinalizingTranscript)

        await manager.startPushToTalkFromKeyboardShortcut(
            currentDraftText: "",
            updateDraftText: { _ in },
            submitDraftText: { submittedDrafts.append($0) }
        )

        provider.lastSession?.emitFinalTranscriptNow()

        try await waitUntil {
            submittedDrafts.count == 1 && !manager.isDictationInProgress
        }

        #expect(captureFactory.createdSessions.count == 1)
        #expect(submittedDrafts == ["first request"])
    }

    @Test func emptyFinalTranscriptDoesNotAutoSubmit() async throws {
        let provider = TestTranscriptionProvider { callbacks in
            TestStreamingSession(
                callbacks: callbacks,
                finalTranscriptOnRequest: ""
            )
        }
        let captureFactory = TestMicrophoneCaptureSessionFactory(
            queuedSessions: [TestMicrophoneCaptureSession()]
        )
        let manager = BuddyDictationManager(
            transcriptionProvider: provider,
            microphoneCaptureSessionFactory: { captureFactory.makeSession() },
            permissionRequester: { true },
            defaultFinalTranscriptFallbackDelaySeconds: 0.01
        )

        var submittedDrafts: [String] = []

        await manager.startPushToTalkFromKeyboardShortcut(
            currentDraftText: "",
            updateDraftText: { _ in },
            submitDraftText: { submittedDrafts.append($0) }
        )
        manager.stopPushToTalkFromKeyboardShortcut()

        try await waitUntil {
            !manager.isDictationInProgress
        }

        #expect(submittedDrafts.isEmpty)
    }

    @Test func whisperKitTranscriptionSessionDeliversFinalTranscriptOnlyOnce() async throws {
        var finalTranscripts: [String] = []
        var transcriptionInvocationCount = 0

        let session = WhisperKitTranscriptionSession(
            keyterms: ["clicky"],
            onTranscriptUpdate: { _ in },
            onFinalTranscriptReady: { finalTranscripts.append($0) },
            onError: { error in
                Issue.record("unexpected whisperkit session error: \(error.localizedDescription)")
            },
            transcriptionPipeline: { _, _ in
                transcriptionInvocationCount += 1
                return "whisper transcript"
            }
        )

        session.appendAudioBuffer(Self.makeAudioBuffer())
        session.requestFinalTranscript()
        session.requestFinalTranscript()

        try await waitUntil {
            finalTranscripts.count == 1
        }

        #expect(transcriptionInvocationCount == 1)
        #expect(finalTranscripts == ["whisper transcript"])
    }

    @Test func emptyTranscriptDoesNotTriggerCompanionResponsePipeline() async throws {
        let catalog = TestOllamaModelCatalog()
        let chatClient = TestOllamaChatClient(responseText: "ignored [POINT:none]")
        let speechSynthesizer = TestLocalSpeechSynthesizer()
        let manager = CompanionManager(
            ollamaModelCatalog: catalog,
            ollamaChatClient: chatClient,
            localSpeechSynthesizer: speechSynthesizer,
            selectedModel: "gemma4:e4b",
            availableOllamaModels: [
                OllamaModelDescriptor(
                    name: "gemma4:e4b",
                    supportsVision: false,
                    parameterSize: "4B",
                    quantizationLevel: "Q4"
                )
            ],
            loadedOllamaModelNames: ["gemma4:e4b"],
            ollamaRuntimeStatus: .ready
        )

        manager.sendTranscriptToModelWithOptionalScreenshots(transcript: "   ")
        await Task.yield()

        #expect(chatClient.streamedUserPrompts.isEmpty)
        #expect(speechSynthesizer.spokenTexts.isEmpty)
        #expect(manager.voiceState == .idle)
    }

    @Test func companionResponsePipelineSpeaksLocalResponseAndReturnsIdle() async throws {
        let catalog = TestOllamaModelCatalog()
        let chatClient = TestOllamaChatClient(responseText: "local answer [POINT:none]")
        let speechSynthesizer = TestLocalSpeechSynthesizer()
        var screenshotCaptureCallCount = 0
        let manager = CompanionManager(
            ollamaModelCatalog: catalog,
            ollamaChatClient: chatClient,
            localSpeechSynthesizer: speechSynthesizer,
            screenshotCapture: {
                screenshotCaptureCallCount += 1
                return []
            },
            selectedModel: "gemma4:e4b",
            availableOllamaModels: [
                OllamaModelDescriptor(
                    name: "gemma4:e4b",
                    supportsVision: false,
                    parameterSize: "4B",
                    quantizationLevel: "Q4"
                )
            ],
            loadedOllamaModelNames: [],
            ollamaRuntimeStatus: .ready
        )

        manager.sendTranscriptToModelWithOptionalScreenshots(transcript: "help me")

        try await waitUntil {
            speechSynthesizer.spokenTexts.count == 1 && manager.voiceState == .idle
        }

        #expect(catalog.preloadModelNames == ["gemma4:e4b"])
        #expect(chatClient.streamedUserPrompts == ["help me"])
        #expect(speechSynthesizer.spokenTexts == ["local answer"])
        #expect(screenshotCaptureCallCount == 0)
        #expect(manager.isSelectedModelLoaded)
    }

    private func waitUntil(
        timeoutSeconds: TimeInterval = 5,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let timeoutDate = Date().addingTimeInterval(timeoutSeconds)

        while !condition() {
            if Date() >= timeoutDate {
                struct WaitTimeoutError: Error {}
                throw WaitTimeoutError()
            }

            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func makeAudioBuffer(sampleCount: Int = 1_600) -> AVAudioPCMBuffer {
        let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let audioBuffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: AVAudioFrameCount(sampleCount)
        )!

        audioBuffer.frameLength = AVAudioFrameCount(sampleCount)

        if let channelData = audioBuffer.floatChannelData {
            for sampleIndex in 0..<sampleCount {
                channelData[0][sampleIndex] = sampleIndex.isMultiple(of: 12) ? 0.25 : 0
            }
        }

        return audioBuffer
    }
}
