//
//  LocalSpeechSynthesizer.swift
//  leanring-buddy
//
//  Kokoro-backed local text-to-speech with an AVSpeechSynthesizer fallback
//  while the managed Kokoro runtime is still provisioning.
//

import AVFoundation
import Foundation

@MainActor
final class LocalSpeechSynthesizer: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    private enum PythonBootstrapTool {
        case uv(URL)
        case python3(URL)
    }

    private static let managedPythonVersion = "3.12"
    private static let managedRuntimeVersion = "kokoro-0.9.4"
    private static let defaultKokoroVoice = "af_heart"
    private static let defaultLanguageCode = "a"
    private static let synthesisSpeed = "1.0"
    private static let supportedPythonMinorVersions: Set<Int> = [10, 11, 12]

    private let fallbackSpeechSynthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var hasPendingPlayback = false
    private var activeTemporaryAudioFileURL: URL?
    private var activePreparationTask: Task<Void, Never>?
    private var activeSynthesisTask: Task<Void, Never>?
    private var runtimeStatusValue: LocalSpeechRuntimeStatus = .idle

    override init() {
        super.init()
        fallbackSpeechSynthesizer.delegate = self
    }

    var isSpeaking: Bool {
        hasPendingPlayback
    }

    var runtimeStatus: LocalSpeechRuntimeStatus {
        runtimeStatusValue
    }

    func prepareIfNeeded() {
        guard activePreparationTask == nil else { return }

        switch runtimeStatusValue {
        case .ready, .preparing:
            return
        case .idle, .usingFallback:
            runtimeStatusValue = .preparing("Clicky is preparing Kokoro speech.")
        }

        activePreparationTask = Task { [weak self] in
            guard let self else { return }
            await self.prepareManagedRuntime()
        }
    }

    func speakText(_ text: String) async {
        stopPlayback()

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        prepareIfNeeded()

        switch runtimeStatusValue {
        case .ready:
            await speakWithKokoro(trimmedText)
        case .idle, .preparing, .usingFallback:
            speakWithFallback(trimmedText)
        }
    }

    func stopPlayback() {
        activeSynthesisTask?.cancel()
        activeSynthesisTask = nil
        hasPendingPlayback = false

        if fallbackSpeechSynthesizer.isSpeaking {
            fallbackSpeechSynthesizer.stopSpeaking(at: .immediate)
        }

        if let audioPlayer {
            audioPlayer.stop()
            audioPlayer.delegate = nil
            self.audioPlayer = nil
        }

        cleanupTemporaryAudioFile()
    }

    private func speakWithFallback(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.autoupdatingCurrent.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.43
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.prefersAssistiveTechnologySettings = true

        hasPendingPlayback = true
        fallbackSpeechSynthesizer.speak(utterance)
    }

    private func speakWithKokoro(_ text: String) async {
        activeSynthesisTask?.cancel()

        let synthesisTask = Task { [weak self] in
            guard let self else { return }

            do {
                let audioFileURL = try await self.generateSpeechAudioFile(for: text)
                guard !Task.isCancelled else { return }
                try self.playGeneratedAudioFile(at: audioFileURL)
            } catch is CancellationError {
                // Ignore cancellation when a newer utterance replaces the current one.
            } catch {
                print("⚠️ Kokoro synthesis failed: \(error.localizedDescription)")
                runtimeStatusValue = .usingFallback(
                    "Clicky is using the system voice until Kokoro finishes preparing."
                )
                prepareIfNeeded()
                speakWithFallback(text)
            }
        }

        activeSynthesisTask = synthesisTask
        await synthesisTask.value
    }

    private func playGeneratedAudioFile(at audioFileURL: URL) throws {
        let audioPlayer = try AVAudioPlayer(contentsOf: audioFileURL)
        audioPlayer.delegate = self

        guard audioPlayer.prepareToPlay(), audioPlayer.play() else {
            throw NSError(
                domain: "LocalSpeechSynthesizer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Clicky couldn't play Kokoro audio output."]
            )
        }

        activeTemporaryAudioFileURL = audioFileURL
        self.audioPlayer = audioPlayer
        hasPendingPlayback = true
    }

    private func prepareManagedRuntime() async {
        do {
            let runtimeDirectories = try Self.makeRuntimeDirectories()
            let pythonBootstrapTool = try Self.findPythonBootstrapTool()
            let venvPythonURL = runtimeDirectories.venvDirectoryURL
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("python", isDirectory: false)

            if FileManager.default.isExecutableFile(atPath: venvPythonURL.path),
               try await !Self.isSupportedPythonExecutable(at: venvPythonURL) {
                try? FileManager.default.removeItem(at: runtimeDirectories.venvDirectoryURL)
            }

            if !FileManager.default.isExecutableFile(atPath: venvPythonURL.path) {
                switch pythonBootstrapTool {
                case .uv(let uvExecutableURL):
                    runtimeStatusValue = .preparing("Clicky is installing a managed Python runtime for Kokoro.")
                    _ = try await Self.runProcess(
                        executableURL: uvExecutableURL,
                        arguments: ["python", "install", Self.managedPythonVersion]
                    )

                    runtimeStatusValue = .preparing("Clicky is creating the local Kokoro environment.")
                    _ = try await Self.runProcess(
                        executableURL: uvExecutableURL,
                        arguments: [
                            "venv",
                            "--python",
                            Self.managedPythonVersion,
                            runtimeDirectories.venvDirectoryURL.path,
                        ]
                    )
                case .python3(let pythonExecutableURL):
                    runtimeStatusValue = .preparing("Clicky is creating the local Kokoro environment.")
                    _ = try await Self.runProcess(
                        executableURL: pythonExecutableURL,
                        arguments: ["-m", "venv", runtimeDirectories.venvDirectoryURL.path]
                    )
                }
            }

            if Self.runtimeMarkerNeedsRefresh(at: runtimeDirectories.runtimeMarkerURL) {
                runtimeStatusValue = .preparing("Clicky is installing Kokoro speech locally.")
                _ = try await Self.runProcess(
                    executableURL: venvPythonURL,
                    arguments: ["-m", "pip", "install", "--upgrade", "pip"]
                )
                _ = try await Self.runProcess(
                    executableURL: venvPythonURL,
                    arguments: ["-m", "pip", "install", "kokoro==0.9.4", "numpy", "soundfile"]
                )
                try Self.managedRuntimeVersion.write(
                    to: runtimeDirectories.runtimeMarkerURL,
                    atomically: true,
                    encoding: .utf8
                )
            }

            runtimeStatusValue = .preparing("Clicky is verifying the Kokoro voice runtime.")
            try await Self.runSmokeTest(
                pythonExecutableURL: venvPythonURL,
                audioOutputDirectoryURL: runtimeDirectories.audioOutputDirectoryURL
            )

            runtimeStatusValue = .ready(voiceName: Self.defaultKokoroVoice)
        } catch {
            print("⚠️ Kokoro runtime preparation failed: \(error.localizedDescription)")
            runtimeStatusValue = .usingFallback(
                "Clicky is using the system voice while Kokoro setup is still unavailable."
            )
        }

        activePreparationTask = nil
    }

    private func generateSpeechAudioFile(for text: String) async throws -> URL {
        let runtimeDirectories = try Self.makeRuntimeDirectories()
        let helperScriptURL = try Self.findBundledHelperScript()
        let pythonExecutableURL = runtimeDirectories.venvDirectoryURL
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python", isDirectory: false)

        guard FileManager.default.isExecutableFile(atPath: pythonExecutableURL.path) else {
            throw NSError(
                domain: "LocalSpeechSynthesizer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "The managed Kokoro runtime is not ready yet."]
            )
        }

        let outputFileURL = runtimeDirectories.audioOutputDirectoryURL
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        _ = try await Self.runProcess(
            executableURL: pythonExecutableURL,
            arguments: [
                helperScriptURL.path,
                "--text",
                text,
                "--output",
                outputFileURL.path,
                "--voice",
                Self.defaultKokoroVoice,
                "--speed",
                Self.synthesisSpeed,
                "--lang-code",
                Self.defaultLanguageCode,
            ]
        )

        return outputFileURL
    }

    private func cleanupTemporaryAudioFile() {
        guard let activeTemporaryAudioFileURL else { return }
        try? FileManager.default.removeItem(at: activeTemporaryAudioFileURL)
        self.activeTemporaryAudioFileURL = nil
    }

    private static func makeRuntimeDirectories() throws -> (
        rootDirectoryURL: URL,
        venvDirectoryURL: URL,
        audioOutputDirectoryURL: URL,
        runtimeMarkerURL: URL
    ) {
        let applicationSupportDirectoryURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)

        let rootDirectoryURL = applicationSupportDirectoryURL
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("Kokoro", isDirectory: true)
        let venvDirectoryURL = rootDirectoryURL.appendingPathComponent("venv", isDirectory: true)
        let audioOutputDirectoryURL = rootDirectoryURL.appendingPathComponent("Audio", isDirectory: true)
        let runtimeMarkerURL = rootDirectoryURL.appendingPathComponent("runtime-version.txt", isDirectory: false)

        try FileManager.default.createDirectory(
            at: audioOutputDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        return (rootDirectoryURL, venvDirectoryURL, audioOutputDirectoryURL, runtimeMarkerURL)
    }

    private static func runtimeMarkerNeedsRefresh(at markerURL: URL) -> Bool {
        guard let existingMarker = try? String(contentsOf: markerURL).trimmingCharacters(in: .whitespacesAndNewlines) else {
            return true
        }

        return existingMarker != managedRuntimeVersion
    }

    private static func findPythonBootstrapTool() throws -> PythonBootstrapTool {
        if let uvExecutableURL = firstExecutableURL(
            at: [
                "/opt/homebrew/bin/uv",
                "/usr/local/bin/uv",
                "/usr/bin/uv",
            ]
        ) {
            return .uv(uvExecutableURL)
        }

        if let pythonExecutableURL = firstExecutableURL(
            at: [
                "/opt/homebrew/bin/python3.12",
                "/opt/homebrew/bin/python3.11",
                "/opt/homebrew/bin/python3.10",
                "/opt/homebrew/bin/python3",
                "/usr/local/bin/python3.12",
                "/usr/local/bin/python3.11",
                "/usr/local/bin/python3.10",
                "/usr/local/bin/python3",
                "/usr/bin/python3",
                "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            ]
        ) {
            return .python3(pythonExecutableURL)
        }

        throw NSError(
            domain: "LocalSpeechSynthesizer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Clicky couldn't find uv or python3 on this Mac."]
        )
    }

    private static func firstExecutableURL(at candidatePaths: [String]) -> URL? {
        guard let matchedPath = candidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }

        return URL(fileURLWithPath: matchedPath)
    }

    private static func findBundledHelperScript() throws -> URL {
        if let helperScriptURL = Bundle.main.url(forResource: "kokoro_tts", withExtension: "py") {
            return helperScriptURL
        }

        if let resourceURL = Bundle.main.resourceURL {
            let fallbackScriptURL = resourceURL.appendingPathComponent("kokoro_tts.py", isDirectory: false)
            if FileManager.default.fileExists(atPath: fallbackScriptURL.path) {
                return fallbackScriptURL
            }
        }

        throw NSError(
            domain: "LocalSpeechSynthesizer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "The bundled Kokoro helper script is missing."]
        )
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String]
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = mergedProcessEnvironment()

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { terminatedProcess in
                let standardOutputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let standardErrorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                let standardOutput = String(decoding: standardOutputData, as: UTF8.self)
                let standardError = String(decoding: standardErrorData, as: UTF8.self)
                let combinedOutput = [standardOutput, standardError]
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: "\n")

                guard terminatedProcess.terminationStatus == 0 else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "LocalSpeechSynthesizer",
                            code: Int(terminatedProcess.terminationStatus),
                            userInfo: [
                                NSLocalizedDescriptionKey: combinedOutput.isEmpty
                                    ? "A Kokoro runtime command failed."
                                    : combinedOutput,
                            ]
                        )
                    )
                    return
                }

                continuation.resume(returning: combinedOutput)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func mergedProcessEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let bundledPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .joined(separator: ":")
        environment["PATH"] = bundledPath + ":" + (environment["PATH"] ?? "")
        return environment
    }

    private static func isSupportedPythonExecutable(at executableURL: URL) async throws -> Bool {
        let versionOutput = try await runProcess(
            executableURL: executableURL,
            arguments: [
                "-c",
                "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')",
            ]
        )

        let versionComponents = versionOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".")
        guard versionComponents.count == 2,
              let majorVersion = Int(versionComponents[0]),
              let minorVersion = Int(versionComponents[1]) else {
            return false
        }

        return majorVersion == 3 && supportedPythonMinorVersions.contains(minorVersion)
    }

    private static func runSmokeTest(
        pythonExecutableURL: URL,
        audioOutputDirectoryURL: URL
    ) async throws {
        let helperScriptURL = try findBundledHelperScript()
        let outputFileURL = audioOutputDirectoryURL
            .appendingPathComponent("kokoro-smoke-test")
            .appendingPathExtension("wav")

        defer {
            try? FileManager.default.removeItem(at: outputFileURL)
        }

        _ = try await runProcess(
            executableURL: pythonExecutableURL,
            arguments: [
                helperScriptURL.path,
                "--text",
                "clicky is ready",
                "--output",
                outputFileURL.path,
                "--voice",
                defaultKokoroVoice,
                "--speed",
                synthesisSpeed,
                "--lang-code",
                defaultLanguageCode,
            ]
        )

        let outputAttributes = try FileManager.default.attributesOfItem(atPath: outputFileURL.path)
        let outputSize = (outputAttributes[.size] as? NSNumber)?.intValue ?? 0
        guard outputSize > 0 else {
            throw NSError(
                domain: "LocalSpeechSynthesizer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Kokoro finished setup, but the smoke test did not produce audio."]
            )
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.hasPendingPlayback = false
            self?.audioPlayer = nil
            self?.cleanupTemporaryAudioFile()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            self?.hasPendingPlayback = false
            self?.audioPlayer = nil
            self?.cleanupTemporaryAudioFile()
            self?.runtimeStatusValue = .usingFallback(
                "Clicky is using the system voice until Kokoro playback is healthy again."
            )
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.hasPendingPlayback = true
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.hasPendingPlayback = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.hasPendingPlayback = false
        }
    }
}
