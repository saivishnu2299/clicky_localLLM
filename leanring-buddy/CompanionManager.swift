//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

enum CompanionOllamaActionState: Equatable {
    case idle
    case startingApp
    case installingRecommendedModel(progress: String?)
    case loadingModel(String)
    case failure(String)

    var isBusy: Bool {
        switch self {
        case .startingApp, .installingRecommendedModel, .loadingModel:
            return true
        case .idle, .failure:
            return false
        }
    }
}

@MainActor
final class CompanionManager: ObservableObject {
    private static let recommendedOllamaModelName = "gemma4:e4b"

    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var isScreenRecordingPermissionPendingRelaunch = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from the local model response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager: BuddyDictationManager
    let globalPushToTalkShortcutMonitor: GlobalPushToTalkShortcutMonitor
    let overlayWindowManager: OverlayWindowManager
    private let ollamaModelCatalog: any OllamaModelCataloging
    private let ollamaChatClient: any OllamaChatStreaming
    private let localSpeechSynthesizer: any LocalSpeechSynthesizing
    private let screenshotCapture: @MainActor () async throws -> [CompanionScreenCapture]

    /// Conversation history so the local model remembers prior exchanges within a session.
    /// Each entry stores only visible user/assistant text, never reasoning.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var applicationDidBecomeActiveObserver: NSObjectProtocol?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    private var ollamaControlTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    @Published private(set) var availableOllamaModels: [OllamaModelDescriptor] = []
    @Published private(set) var loadedOllamaModelNames: Set<String> = []
    @Published private(set) var ollamaRuntimeStatus: OllamaRuntimeStatus = .checking
    @Published private(set) var ollamaActionState: CompanionOllamaActionState = .idle

    /// The selected Ollama model used for local responses. Persisted to UserDefaults.
    @Published var selectedModel: String

    init(
        buddyDictationManager: BuddyDictationManager? = nil,
        globalPushToTalkShortcutMonitor: GlobalPushToTalkShortcutMonitor? = nil,
        overlayWindowManager: OverlayWindowManager? = nil,
        ollamaModelCatalog: (any OllamaModelCataloging)? = nil,
        ollamaChatClient: (any OllamaChatStreaming)? = nil,
        localSpeechSynthesizer: (any LocalSpeechSynthesizing)? = nil,
        screenshotCapture: @escaping @MainActor () async throws -> [CompanionScreenCapture] = {
            try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        },
        selectedModel: String = UserDefaults.standard.string(forKey: "selectedOllamaModel") ?? "gemma4:e4b",
        availableOllamaModels: [OllamaModelDescriptor] = [],
        loadedOllamaModelNames: Set<String> = [],
        ollamaRuntimeStatus: OllamaRuntimeStatus = .checking
    ) {
        self.buddyDictationManager = buddyDictationManager ?? BuddyDictationManager()
        self.globalPushToTalkShortcutMonitor = globalPushToTalkShortcutMonitor ?? GlobalPushToTalkShortcutMonitor()
        self.overlayWindowManager = overlayWindowManager ?? OverlayWindowManager()
        self.ollamaModelCatalog = ollamaModelCatalog ?? OllamaModelCatalog()
        self.ollamaChatClient = ollamaChatClient ?? OllamaChatClient()
        self.localSpeechSynthesizer = localSpeechSynthesizer ?? LocalSpeechSynthesizer()
        self.screenshotCapture = screenshotCapture
        self.selectedModel = selectedModel
        self.availableOllamaModels = availableOllamaModels
        self.loadedOllamaModelNames = loadedOllamaModelNames
        self.ollamaRuntimeStatus = ollamaRuntimeStatus
    }

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedOllamaModel")
        loadSelectedModelFromPanel(force: true)
    }

    var selectedModelDescriptor: OllamaModelDescriptor? {
        availableOllamaModels.first(where: { $0.name == selectedModel })
    }

    var selectedModelSupportsVision: Bool {
        selectedModelDescriptor?.supportsVision ?? false
    }

    var isOllamaReady: Bool {
        ollamaRuntimeStatus == .ready && !selectedModel.isEmpty
    }

    var isSelectedModelLoaded: Bool {
        !selectedModel.isEmpty && loadedOllamaModelNames.contains(selectedModel)
    }

    var canStartOllamaFromUI: Bool {
        ollamaRuntimeStatus == .unavailable && !ollamaActionState.isBusy
    }

    var canInstallRecommendedModelFromUI: Bool {
        !ollamaActionState.isBusy
            && ollamaRuntimeStatus != .checking
            && !availableOllamaModels.contains(where: { $0.name == Self.recommendedOllamaModelName })
    }

    var canLoadSelectedModelFromUI: Bool {
        isOllamaReady && !selectedModel.isEmpty && !isSelectedModelLoaded && !ollamaActionState.isBusy
    }

    var recommendedModelName: String {
        Self.recommendedOllamaModelName
    }

    var selectedModelStatusTitle: String {
        if selectedModel.isEmpty {
            return "No model selected"
        }

        if case .loadingModel(let modelName) = ollamaActionState, modelName == selectedModel {
            return "\(selectedModel) is loading"
        }

        if isSelectedModelLoaded {
            return "\(selectedModel) is ready"
        }

        return "\(selectedModel) is installed"
    }

    var selectedModelStatusMessage: String {
        guard !selectedModel.isEmpty else {
            return "Install or select a local model to enable voice responses."
        }

        if case .loadingModel(let modelName) = ollamaActionState, modelName == selectedModel {
            return "Clicky is loading the selected model into Ollama now."
        }

        if isSelectedModelLoaded {
            if selectedModelSupportsVision {
                return "Loaded in memory. Screenshot understanding, pointing, and spoken replies are ready."
            }

            return "Loaded in memory. Spoken replies are ready. This model will answer without screenshots or pointing."
        }

        if selectedModelSupportsVision {
            return "Installed locally. Load it once and Clicky will use screenshots, pointing, and spoken replies."
        }

        return "Installed locally. Load it once and Clicky will answer with spoken text-only help."
    }

    var ollamaStatusTitle: String {
        switch ollamaActionState {
        case .startingApp:
            return "Starting Ollama"
        case .installingRecommendedModel:
            return "Installing \(Self.recommendedOllamaModelName)"
        case .loadingModel(let modelName):
            return "Loading \(modelName)"
        case .failure:
            return "Ollama Setup Needed"
        case .idle:
            break
        }

        switch ollamaRuntimeStatus {
        case .checking:
            return "Checking Ollama"
        case .unavailable:
            return "Ollama Not Running"
        case .noLocalModels:
            return "Install a Local Model"
        case .ready:
            return "Local Mode Ready"
        }
    }

    var ollamaStatusMessage: String {
        switch ollamaActionState {
        case .startingApp:
            return "Launching the Ollama app and waiting for the local API to come online."
        case .installingRecommendedModel(let progress):
            return progress ?? "Downloading the recommended local model now."
        case .loadingModel(let modelName):
            return "Loading \(modelName) into Ollama so Clicky can answer immediately."
        case .failure(let message):
            return message
        case .idle:
            break
        }

        switch ollamaRuntimeStatus {
        case .checking:
            return "Checking your local Ollama runtime."
        case .unavailable:
            return "Start Ollama from this panel. Clicky will connect as soon as the local runtime is up."
        case .noLocalModels:
            return "Install the recommended local model here and Clicky will select it automatically."
        case .ready:
            if selectedModel.isEmpty {
                return "Choose a local model to start using Clicky."
            }
            return selectedModelStatusMessage
        }
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        installApplicationDidBecomeActiveObserver()
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        refreshOllamaRuntime()

        if allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    func refreshOllamaRuntime(shouldPrepareSelectedModel: Bool = true) {
        if !ollamaActionState.isBusy {
            ollamaActionState = .idle
        }
        ollamaRuntimeStatus = .checking

        Task {
            let catalogSnapshot = await ollamaModelCatalog.fetchCatalogSnapshot()

            availableOllamaModels = catalogSnapshot.models
            loadedOllamaModelNames = catalogSnapshot.loadedModelNames
            ollamaRuntimeStatus = catalogSnapshot.runtimeStatus

            if let resolvedSelectedModelName = OllamaModelCatalog.defaultModelName(
                from: catalogSnapshot.models,
                savedModelName: selectedModel
            ) {
                if selectedModel != resolvedSelectedModelName {
                    setSelectedModel(resolvedSelectedModelName)
                }
            } else if catalogSnapshot.runtimeStatus != .ready {
                selectedModel = ""
                UserDefaults.standard.removeObject(forKey: "selectedOllamaModel")
            }

            if shouldPrepareSelectedModel,
               catalogSnapshot.runtimeStatus == .ready,
               !selectedModel.isEmpty,
               !catalogSnapshot.loadedModelNames.contains(selectedModel) {
                loadSelectedModelFromPanel()
            }
        }
    }

    func startOllamaFromPanel() {
        guard !ollamaActionState.isBusy else { return }

        ollamaControlTask?.cancel()
        ollamaActionState = .startingApp

        ollamaControlTask = Task {
            let didStart = await ollamaModelCatalog.startOllamaApp()
            guard !Task.isCancelled else { return }

            if didStart {
                await MainActor.run {
                    self.ollamaActionState = .idle
                    self.refreshOllamaRuntime()
                }
            } else {
                await MainActor.run {
                    self.ollamaActionState = .failure(
                        "Clicky couldn't launch the Ollama app. Install Ollama for macOS or open it once manually."
                    )
                }
            }
        }
    }

    func installRecommendedModelFromPanel() {
        guard !ollamaActionState.isBusy else { return }

        ollamaControlTask?.cancel()
        ollamaActionState = .installingRecommendedModel(progress: "Preparing \(Self.recommendedOllamaModelName).")

        ollamaControlTask = Task {
            if ollamaRuntimeStatus == .unavailable {
                let didStart = await ollamaModelCatalog.startOllamaApp()
                guard !Task.isCancelled else { return }

                guard didStart else {
                    await MainActor.run {
                        self.ollamaActionState = .failure(
                            "Clicky couldn't start Ollama, so it can't install the recommended model yet."
                        )
                    }
                    return
                }
            }

            do {
                try await ollamaModelCatalog.pullModel(named: Self.recommendedOllamaModelName) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.ollamaActionState = .installingRecommendedModel(progress: progress.userFacingDescription)
                    }
                }

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    self.ollamaActionState = .idle
                    self.selectedModel = Self.recommendedOllamaModelName
                    UserDefaults.standard.set(Self.recommendedOllamaModelName, forKey: "selectedOllamaModel")
                    self.refreshOllamaRuntime()
                }
            } catch is CancellationError {
                // Ignore cancellation.
            } catch {
                await MainActor.run {
                    self.ollamaActionState = .failure(
                        "The model download failed. Make sure Ollama is online and try again."
                    )
                }
            }
        }
    }

    func loadSelectedModelFromPanel(force: Bool = false) {
        guard isOllamaReady else { return }
        guard !selectedModel.isEmpty else { return }
        guard force || !isSelectedModelLoaded else {
            ollamaActionState = .idle
            return
        }
        guard !ollamaActionState.isBusy || force else { return }

        let modelName = selectedModel
        ollamaControlTask?.cancel()
        ollamaActionState = .loadingModel(modelName)

        ollamaControlTask = Task {
            do {
                try await ollamaModelCatalog.preloadModel(named: modelName)
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    self.loadedOllamaModelNames.insert(modelName)
                    self.ollamaActionState = .idle
                    self.refreshOllamaRuntime(shouldPrepareSelectedModel: false)
                }
            } catch is CancellationError {
                // Ignore cancellation.
            } catch {
                await MainActor.run {
                    self.ollamaActionState = .failure(
                        "Clicky couldn't load \(modelName) into Ollama. Try refreshing the runtime and loading it again."
                    )
                }
            }
        }
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        ollamaControlTask?.cancel()
        ollamaControlTask = nil
        currentResponseTask?.cancel()
        currentResponseTask = nil
        localSpeechSynthesizer.stopPlayback()
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
        if let applicationDidBecomeActiveObserver {
            NotificationCenter.default.removeObserver(applicationDidBecomeActiveObserver)
            self.applicationDidBecomeActiveObserver = nil
        }
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibilityTrust = WindowPositionManager.hasAccessibilityPermission()
        let canInstallGlobalShortcutMonitor = globalPushToTalkShortcutMonitor.start()
        hasAccessibilityPermission = currentlyHasAccessibilityTrust || canInstallGlobalShortcutMonitor

        if !hasAccessibilityPermission {
            globalPushToTalkShortcutMonitor.stop()
        }

        let screenRecordingPermissionStatus = WindowPositionManager.currentScreenRecordingPermissionStatus()
        hasScreenRecordingPermission = screenRecordingPermissionStatus.isGrantedForAppFlow
        isScreenRecordingPermissionPendingRelaunch = screenRecordingPermissionStatus.requiresRelaunch

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }

        if allPermissionsGranted && isClickyCursorEnabled && !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else if !allPermissionsGranted && isOverlayVisible {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    if allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func installApplicationDidBecomeActiveObserver() {
        guard applicationDidBecomeActiveObserver == nil else { return }

        applicationDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAllPermissions()
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            localSpeechSynthesizer.stopPlayback()
            clearDetectedElementLocation()

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToModelWithOptionalScreenshots(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk. when screenshots are attached, you can use them for screen-aware help. your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if screenshots are attached, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.
    - never reveal reasoning, thinking traces, or chain-of-thought. answer with final visible output only.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen, but only when screenshots are attached for this turn. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when screenshots are attached and you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if screenshots are not attached, or pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    // MARK: - AI Response Pipeline

    /// Captures screenshots when the selected model supports vision, sends the
    /// request to Ollama, and plays the response aloud locally. The cursor
    /// stays in the spinner/processing state until speech has been queued.
    /// The model response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    func sendTranscriptToModelWithOptionalScreenshots(transcript: String) {
        currentResponseTask?.cancel()
        currentResponseTask = nil
        localSpeechSynthesizer.stopPlayback()
        clearDetectedElementLocation()

        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            voiceState = .idle
            scheduleTransientHideIfNeeded()
            return
        }

        currentResponseTask = Task {
            voiceState = .processing

            guard isOllamaReady else {
                await speakLocalFallbackMessage(
                    "ollama is not ready yet. open the clicky panel, start ollama, and load a local model first."
                )
                voiceState = .idle
                currentResponseTask = nil
                scheduleTransientHideIfNeeded()
                return
            }

            do {
                if !isSelectedModelLoaded {
                    try await ollamaModelCatalog.preloadModel(named: selectedModel)
                    loadedOllamaModelNames.insert(selectedModel)
                }

                let shouldUseScreenshots = selectedModelSupportsVision
                let screenCaptures = shouldUseScreenshots
                    ? try await screenshotCapture()
                    : []

                guard !Task.isCancelled else { return }

                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                let historyForAPI = conversationHistory.map { entry in
                    (userPrompt: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let fullResponseText = try await ollamaChatClient.streamChatResponse(
                    modelName: selectedModel,
                    images: labeledImages,
                    systemPrompt: shouldUseScreenshots
                        ? Self.companionVoiceResponseSystemPrompt
                        : Self.companionVoiceResponseSystemPrompt + "\n\nNo screenshots are attached for this turn. Answer without screen references and end with [POINT:none].",
                    conversationHistory: historyForAPI,
                    userPrompt: trimmedTranscript,
                    onTextChunk: { _ in
                        // The overlay stays in spinner mode until local speech has been queued.
                    }
                )

                guard !Task.isCancelled else { return }

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                let hasPointCoordinate = parseResult.coordinate != nil && shouldUseScreenshots
                if hasPointCoordinate {
                    voiceState = .idle
                }

                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    let appKitY = displayHeight - displayLocalY

                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                conversationHistory.append((
                    userTranscript: trimmedTranscript,
                    assistantResponse: spokenText
                ))

                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    voiceState = .responding
                    await localSpeechSynthesizer.speakText(spokenText)
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted.
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                await speakLocalFallbackMessage(
                    "something went wrong with the local response. check that ollama is running and that the selected model finished loading, then try again."
                )
            }

            if !Task.isCancelled {
                voiceState = .idle
                currentResponseTask = nil
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            while localSpeechSynthesizer.isSpeaking {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    private func speakLocalFallbackMessage(_ message: String) async {
        voiceState = .responding
        await localSpeechSynthesizer.speakText(message)
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from the model response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if the model said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of the model response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks the selected local vision model to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        guard voiceState == .idle || voiceState == .responding else { return }
        guard selectedModelSupportsVision else {
            print("🎯 Onboarding demo skipped: selected model does not support vision")
            return
        }
        guard isOllamaReady else {
            print("🎯 Onboarding demo skipped: Ollama is not ready")
            return
        }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let fullResponseText = try await ollamaChatClient.streamChatResponse(
                    modelName: selectedModel,
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    conversationHistory: [],
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
