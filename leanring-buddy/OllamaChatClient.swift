//
//  OllamaChatClient.swift
//  leanring-buddy
//
//  Streams local multimodal chat completions from Ollama.
//

import Foundation

struct OllamaStreamChunk: Equatable {
    let visibleContent: String
    let isDone: Bool
}

final class OllamaChatClient {
    private let chatURL: URL
    private let session: URLSession

    init(baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.chatURL = baseURL.appending(path: "/api/chat")

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)
    }

    func streamChatResponse(
        modelName: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPrompt: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.makeRequestBody(
                modelName: modelName,
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt
            )
        )

        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "OllamaChatClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Ollama returned an invalid response."]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorLines: [String] = []
            for try await line in byteStream.lines {
                errorLines.append(line)
            }

            throw NSError(
                domain: "OllamaChatClient",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: errorLines.joined(separator: "\n")]
            )
        }

        var fullVisibleResponse = ""

        for try await line in byteStream.lines {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard let streamChunk = Self.parseStreamChunk(from: line) else { continue }

            if !streamChunk.visibleContent.isEmpty {
                fullVisibleResponse += streamChunk.visibleContent
                let currentVisibleResponse = fullVisibleResponse
                await onTextChunk(currentVisibleResponse)
            }

            if streamChunk.isDone {
                break
            }
        }

        return fullVisibleResponse
    }

    static func parseStreamChunk(from line: String) -> OllamaStreamChunk? {
        guard let lineData = line.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return nil
        }

        let isDone = payload["done"] as? Bool ?? false

        if let message = payload["message"] as? [String: Any] {
            let visibleContent = (message["content"] as? String) ?? ""
            return OllamaStreamChunk(visibleContent: visibleContent, isDone: isDone)
        }

        if let visibleContent = payload["response"] as? String {
            return OllamaStreamChunk(visibleContent: visibleContent, isDone: isDone)
        }

        return OllamaStreamChunk(visibleContent: "", isDone: isDone)
    }

    static func makeRequestBody(
        modelName: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPrompt: String, assistantResponse: String)],
        userPrompt: String
    ) -> [String: Any] {
        var messages: [[String: Any]] = [
            [
                "role": "system",
                "content": systemPrompt,
            ]
        ]

        for historyMessage in conversationHistory {
            messages.append([
                "role": "user",
                "content": historyMessage.userPrompt,
            ])
            messages.append([
                "role": "assistant",
                "content": historyMessage.assistantResponse,
            ])
        }

        var currentUserMessage: [String: Any] = [
            "role": "user",
            "content": makeUserContent(images: images, userPrompt: userPrompt),
        ]

        if !images.isEmpty {
            currentUserMessage["images"] = images.map { $0.data.base64EncodedString() }
        }

        messages.append(currentUserMessage)

        return [
            "model": modelName,
            "messages": messages,
            "stream": true,
            "think": false,
        ]
    }

    static func makeUserContent(
        images: [(data: Data, label: String)],
        userPrompt: String
    ) -> String {
        var contentLines: [String] = []

        if !images.isEmpty {
            contentLines.append("Attached screenshots are available for this turn.")
            for (index, image) in images.enumerated() {
                contentLines.append("Screenshot \(index + 1): \(image.label)")
            }
        } else {
            contentLines.append("No screenshots are attached for this turn.")
        }

        contentLines.append("User request: \(userPrompt)")
        return contentLines.joined(separator: "\n")
    }
}
