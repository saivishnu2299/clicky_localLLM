//
//  CompanionRuntimeDependencies.swift
//  leanring-buddy
//
//  Lightweight protocol surfaces for testing the local response pipeline.
//

import Foundation

enum LocalSpeechRuntimeStatus: Equatable {
    case idle
    case preparing(String)
    case ready(voiceName: String)
    case usingFallback(String)
}

protocol OllamaModelCataloging {
    func fetchCatalogSnapshot() async -> OllamaModelCatalogSnapshot
    @MainActor
    func startOllamaApp() async -> Bool
    func pullModel(
        named modelName: String,
        onProgress: @escaping @Sendable (OllamaPullProgress) -> Void
    ) async throws
    func preloadModel(named modelName: String) async throws
}

protocol OllamaChatStreaming {
    func streamChatResponse(
        modelName: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPrompt: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String
}

@MainActor
protocol LocalSpeechSynthesizing: AnyObject {
    var isSpeaking: Bool { get }
    var runtimeStatus: LocalSpeechRuntimeStatus { get }
    func prepareIfNeeded()
    func speakText(_ text: String) async
    func stopPlayback()
}

extension OllamaModelCatalog: OllamaModelCataloging {}
extension OllamaChatClient: OllamaChatStreaming {}
extension LocalSpeechSynthesizer: LocalSpeechSynthesizing {}
