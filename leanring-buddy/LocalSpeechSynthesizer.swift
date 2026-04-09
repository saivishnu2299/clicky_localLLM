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
    private var speechStartContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }

    var isSpeaking: Bool {
        speechSynthesizer.isSpeaking
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

        await withCheckedContinuation { continuation in
            speechStartContinuation = continuation
            speechSynthesizer.speak(utterance)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if let speechStartContinuation = self.speechStartContinuation {
                    self.speechStartContinuation = nil
                    speechStartContinuation.resume()
                }
            }
        }
    }

    func stopPlayback() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        if let speechStartContinuation {
            self.speechStartContinuation = nil
            speechStartContinuation.resume()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        if let speechStartContinuation {
            self.speechStartContinuation = nil
            speechStartContinuation.resume()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        if let speechStartContinuation {
            self.speechStartContinuation = nil
            speechStartContinuation.resume()
        }
    }
}
