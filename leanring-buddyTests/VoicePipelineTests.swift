//
//  VoicePipelineTests.swift
//  leanring-buddyTests
//

import AppKit
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

    private final class TestOllamaModelCatalog: OllamaModelCataloging, @unchecked Sendable {
        private var catalogSnapshots: [OllamaModelCatalogSnapshot]
        private let startOllamaAppResult: Bool
        private(set) var preloadModelNames: [String] = []
        private(set) var startOllamaAppCallCount = 0

        init(
            catalogSnapshots: [OllamaModelCatalogSnapshot] = [
                OllamaModelCatalogSnapshot(models: [], runtimeStatus: .ready, loadedModelNames: [])
            ],
            startOllamaAppResult: Bool = true
        ) {
            self.catalogSnapshots = catalogSnapshots
            self.startOllamaAppResult = startOllamaAppResult
        }

        func fetchCatalogSnapshot() async -> OllamaModelCatalogSnapshot {
            if catalogSnapshots.count > 1 {
                return catalogSnapshots.removeFirst()
            }

            return catalogSnapshots.first ?? OllamaModelCatalogSnapshot(
                models: [],
                runtimeStatus: .ready,
                loadedModelNames: []
            )
        }

        func startOllamaApp() async -> Bool {
            startOllamaAppCallCount += 1
            return startOllamaAppResult
        }

        func pullModel(
            named modelName: String,
            onProgress: @escaping @Sendable (OllamaPullProgress) -> Void
        ) async throws {}

        func preloadModel(named modelName: String) async throws {
            preloadModelNames.append(modelName)
        }
    }

    private final class TestOllamaChatClient: OllamaChatStreaming, @unchecked Sendable {
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

    private final class TestLocalSpeechSynthesizer: LocalSpeechSynthesizing, @unchecked Sendable {
        private(set) var spokenTexts: [String] = []
        private(set) var stopCallCount = 0
        private(set) var prepareCallCount = 0
        var isSpeaking = false
        var runtimeStatus: LocalSpeechRuntimeStatus = .ready(voiceName: "test_voice")

        func prepareIfNeeded() {
            prepareCallCount += 1
        }

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

    private final class TestGlobalPushToTalkShortcutMonitor: GlobalPushToTalkShortcutMonitor, @unchecked Sendable {
        private let startResult: Bool
        private(set) var startCallCount = 0
        private(set) var stopCallCount = 0
        var grantsAccessibilityForAppFlowOverride: Bool?

        init(startResult: Bool = true) {
            self.startResult = startResult
            super.init()
        }

        override var grantsAccessibilityForAppFlow: Bool {
            grantsAccessibilityForAppFlowOverride ?? super.grantsAccessibilityForAppFlow
        }

        override func start() -> Bool {
            startCallCount += 1
            return startResult
        }

        override func stop() {
            stopCallCount += 1
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
        defer { manager.cancelCurrentDictation() }

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
        defer { manager.cancelCurrentDictation() }

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
        defer { manager.cancelCurrentDictation() }

        let startTask = Task {
            await manager.startPushToTalkFromKeyboardShortcut(
                currentDraftText: "",
                updateDraftText: { _ in },
                submitDraftText: { _ in }
            )
        }

        await Task.yield()
        manager.stopPushToTalkFromKeyboardShortcut()
        await startTask.value

        try await waitUntil {
            !manager.isDictationInProgress && !manager.isKeyboardShortcutSessionActiveOrFinalizing
        }

        #expect(captureFactory.createdSessions.isEmpty)
        #expect(manager.lastErrorMessage == nil)
    }

    @Test func resilientMicrophoneCaptureFallsBackToSecondaryBackend() throws {
        let primarySession = TestMicrophoneCaptureSession(
            startError: BuddyMicrophoneCaptureError.failedToStart(
                underlyingDescription: "AVAudioEngine could not start"
            )
        )
        let fallbackSession = TestMicrophoneCaptureSession()

        let resilientSession = ResilientMicrophoneCaptureSession(
            sessionFactories: [
                { primarySession },
                { fallbackSession }
            ]
        )

        try resilientSession.startCapturingAudio { _ in }

        #expect(primarySession.startCallCount == 1)
        #expect(primarySession.cancelCallCount == 1)
        #expect(fallbackSession.startCallCount == 1)

        resilientSession.stopCapturingAudio()

        #expect(fallbackSession.stopCallCount == 1)
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
        defer { manager.cancelCurrentDictation() }

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
        defer { manager.cancelCurrentDictation() }

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
        defer {
            manager.stop()
            UserDefaults.standard.removeObject(forKey: "selectedOllamaModel")
        }

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
        defer {
            manager.stop()
            UserDefaults.standard.removeObject(forKey: "selectedOllamaModel")
        }

        manager.sendTranscriptToModelWithOptionalScreenshots(transcript: "help me")
        await manager.waitForCurrentResponseForTesting()

        #expect(catalog.preloadModelNames == ["gemma4:e4b"])
        #expect(chatClient.streamedUserPrompts == ["help me"])
        #expect(speechSynthesizer.spokenTexts == ["local answer"])
        #expect(screenshotCaptureCallCount == 0)
        #expect(manager.isSelectedModelLoaded)
        #expect(manager.voiceState == .idle)
    }

    @Test func launchBootstrapAutoStartsOllamaAndLoadsResolvedModel() async throws {
        let modelDescriptors = [
            OllamaModelDescriptor(
                name: "gemma4:e4b",
                supportsVision: true,
                parameterSize: "4B",
                quantizationLevel: "Q4_K_M"
            )
        ]
        let catalog = TestOllamaModelCatalog(
            catalogSnapshots: [
                OllamaModelCatalogSnapshot(models: [], runtimeStatus: .unavailable, loadedModelNames: []),
                OllamaModelCatalogSnapshot(models: modelDescriptors, runtimeStatus: .ready, loadedModelNames: []),
                OllamaModelCatalogSnapshot(models: modelDescriptors, runtimeStatus: .ready, loadedModelNames: ["gemma4:e4b"]),
            ]
        )
        let manager = CompanionManager(
            ollamaModelCatalog: catalog,
            ollamaChatClient: TestOllamaChatClient(responseText: "unused [POINT:none]"),
            localSpeechSynthesizer: TestLocalSpeechSynthesizer(),
            selectedModel: "gemma4:e4b"
        )
        defer { UserDefaults.standard.removeObject(forKey: "selectedOllamaModel") }

        manager.bootstrapOllamaRuntimeOnLaunch()
        await manager.waitForOllamaPreparationForTesting()

        #expect(catalog.preloadModelNames == ["gemma4:e4b"])
        #expect(manager.selectedModel == "gemma4:e4b")
        #expect(manager.isSelectedModelLoaded)
        #expect(manager.ollamaActionState == .idle)
        manager.stop()
    }

    @Test func changingModelLoadsTheNewSelection() async throws {
        let modelDescriptors = [
            OllamaModelDescriptor(
                name: "gemma4:e4b",
                supportsVision: true,
                parameterSize: "4B",
                quantizationLevel: "Q4_K_M"
            ),
            OllamaModelDescriptor(
                name: "llama3.2",
                supportsVision: false,
                parameterSize: "3B",
                quantizationLevel: "Q4_K_M"
            ),
        ]
        let catalog = TestOllamaModelCatalog(
            catalogSnapshots: [
                OllamaModelCatalogSnapshot(models: modelDescriptors, runtimeStatus: .ready, loadedModelNames: ["gemma4:e4b"]),
                OllamaModelCatalogSnapshot(models: modelDescriptors, runtimeStatus: .ready, loadedModelNames: ["gemma4:e4b", "llama3.2"]),
            ]
        )
        let manager = CompanionManager(
            ollamaModelCatalog: catalog,
            ollamaChatClient: TestOllamaChatClient(responseText: "unused [POINT:none]"),
            localSpeechSynthesizer: TestLocalSpeechSynthesizer(),
            selectedModel: "gemma4:e4b",
            availableOllamaModels: modelDescriptors,
            loadedOllamaModelNames: ["gemma4:e4b"],
            ollamaRuntimeStatus: .ready
        )
        defer { UserDefaults.standard.removeObject(forKey: "selectedOllamaModel") }

        manager.setSelectedModel("llama3.2")
        await manager.waitForOllamaPreparationForTesting()

        #expect(manager.selectedModel == "llama3.2")
        #expect(manager.isSelectedModelLoaded)
        #expect(catalog.preloadModelNames == ["llama3.2"])
        #expect(manager.ollamaActionState == .idle)
        manager.stop()
    }

    @Test func companionStartKeepsGlobalShortcutMonitorIndependentFromPermissionRefresh() async throws {
        let modelDescriptors = [
            OllamaModelDescriptor(
                name: "gemma4:e4b",
                supportsVision: true,
                parameterSize: "4B",
                quantizationLevel: "Q4_K_M"
            )
        ]
        let globalMonitor = TestGlobalPushToTalkShortcutMonitor()
        let speechSynthesizer = TestLocalSpeechSynthesizer()
        let manager = CompanionManager(
            globalPushToTalkShortcutMonitor: globalMonitor,
            ollamaModelCatalog: TestOllamaModelCatalog(
                catalogSnapshots: [
                    OllamaModelCatalogSnapshot(models: modelDescriptors, runtimeStatus: .ready, loadedModelNames: ["gemma4:e4b"]),
                    OllamaModelCatalogSnapshot(models: modelDescriptors, runtimeStatus: .ready, loadedModelNames: ["gemma4:e4b"]),
                ]
            ),
            ollamaChatClient: TestOllamaChatClient(responseText: "unused [POINT:none]"),
            localSpeechSynthesizer: speechSynthesizer,
            selectedModel: "gemma4:e4b",
            availableOllamaModels: modelDescriptors,
            loadedOllamaModelNames: ["gemma4:e4b"],
            ollamaRuntimeStatus: .ready
        )
        defer { UserDefaults.standard.removeObject(forKey: "selectedOllamaModel") }

        manager.start()
        manager.refreshAllPermissions()

        #expect(globalMonitor.startCallCount == 1)
        #expect(globalMonitor.stopCallCount == 0)
        #expect(speechSynthesizer.prepareCallCount == 1)

        manager.stop()
        #expect(globalMonitor.stopCallCount == 1)
    }

    @Test func activeGlobalShortcutMonitorCountsAsAccessibilityGrant() async throws {
        let globalMonitor = TestGlobalPushToTalkShortcutMonitor()
        globalMonitor.grantsAccessibilityForAppFlowOverride = true

        let manager = CompanionManager(
            globalPushToTalkShortcutMonitor: globalMonitor,
            ollamaModelCatalog: TestOllamaModelCatalog(),
            ollamaChatClient: TestOllamaChatClient(responseText: "unused [POINT:none]"),
            localSpeechSynthesizer: TestLocalSpeechSynthesizer()
        )
        defer { manager.stop() }

        manager.refreshAllPermissions()

        #expect(manager.hasAccessibilityPermission)
    }

    @Test func leftControlShortcutPressRequiresOnlyLeftControl() {
        let pressTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: .flagsChanged,
            keyCode: BuddyPushToTalkShortcut.leftControlKeyCode,
            modifierFlagsRawValue: UInt64(NSEvent.ModifierFlags.control.rawValue),
            wasShortcutPreviouslyPressed: false
        )

        #expect(pressTransition == .pressed)

        let extraModifierTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: .flagsChanged,
            keyCode: BuddyPushToTalkShortcut.leftControlKeyCode,
            modifierFlagsRawValue: UInt64((NSEvent.ModifierFlags.control.union(.option)).rawValue),
            wasShortcutPreviouslyPressed: false
        )

        #expect(extraModifierTransition == .none)
    }

    @Test func leftControlShortcutIgnoresRightControlAndReleasesOnLeftControlLift() {
        let rightControlTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: .flagsChanged,
            keyCode: 62,
            modifierFlagsRawValue: UInt64(NSEvent.ModifierFlags.control.rawValue),
            wasShortcutPreviouslyPressed: false
        )

        #expect(rightControlTransition == .none)

        let releaseTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: .flagsChanged,
            keyCode: BuddyPushToTalkShortcut.leftControlKeyCode,
            modifierFlagsRawValue: 0,
            wasShortcutPreviouslyPressed: true
        )

        #expect(releaseTransition == .released)
    }

    @Test func companionTracksFallbackSpeechRuntimeState() async throws {
        let speechSynthesizer = TestLocalSpeechSynthesizer()
        speechSynthesizer.runtimeStatus = .usingFallback("fallback voice is active")
        let manager = CompanionManager(
            globalPushToTalkShortcutMonitor: TestGlobalPushToTalkShortcutMonitor(),
            ollamaModelCatalog: TestOllamaModelCatalog(),
            ollamaChatClient: TestOllamaChatClient(responseText: "unused [POINT:none]"),
            localSpeechSynthesizer: speechSynthesizer
        )
        defer {
            manager.stop()
            UserDefaults.standard.removeObject(forKey: "selectedOllamaModel")
        }

        manager.start()

        #expect(manager.speechRuntimeStatus == .usingFallback("fallback voice is active"))
        #expect(manager.speechStatusTitle == "Using system voice")
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
