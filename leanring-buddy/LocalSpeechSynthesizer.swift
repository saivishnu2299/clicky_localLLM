//
//  LocalSpeechSynthesizer.swift
//  leanring-buddy
//
//  Local text-to-speech using AVSpeechSynthesizer.
//

import AVFoundation
import Foundation

@MainActor
final class LocalSpeechSynthesizer: NSObject, AVSpeechSynthesizerDelegate {
    private let speechSynthesizer = AVSpeechSynthesizer()
    // Tracks speech that has been queued but may not have reached AVFoundation's
    // speaking state yet, so overlay teardown waits for the full playback lifecycle.
    private var hasPendingPlayback = false

    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    var isSpeaking: Bool {
        hasPendingPlayback
    }

    func speakText(_ text: String) async {
        stopPlayback()

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: trimmedText)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.autoupdatingCurrent.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.43
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.prefersAssistiveTechnologySettings = true

        hasPendingPlayback = true
        speechSynthesizer.speak(utterance)
    }

    func stopPlayback() {
        let shouldStopPlayback = hasPendingPlayback
        hasPendingPlayback = false

        if shouldStopPlayback {
            speechSynthesizer.stopSpeaking(at: .immediate)
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
