//
//  OllamaModelCatalog.swift
//  leanring-buddy
//
//  Discovers locally installed Ollama models and their capabilities.
//

import AppKit
import Foundation

struct OllamaModelDescriptor: Identifiable, Equatable {
    let name: String
    let supportsVision: Bool
    let parameterSize: String?
    let quantizationLevel: String?

    var id: String { name }
}

enum OllamaRuntimeStatus: Equatable {
    case checking
    case unavailable
    case noLocalModels
    case ready
}

struct OllamaModelCatalogSnapshot: Equatable {
    let models: [OllamaModelDescriptor]
    let runtimeStatus: OllamaRuntimeStatus
    let loadedModelNames: Set<String>
}

struct OllamaPullProgress: Equatable {
    let status: String
    let completedUnitCount: Int64?
    let totalUnitCount: Int64?

    var userFacingDescription: String {
        guard let completedUnitCount,
              let totalUnitCount,
              totalUnitCount > 0 else {
            return status
        }

        let percentage = max(0, min(100, Int((Double(completedUnitCount) / Double(totalUnitCount)) * 100)))
        return "\(status) \(percentage)%"
    }
}

final class OllamaModelCatalog {
    private struct ListModelsResponse: Decodable {
        let models: [ListModel]
    }

    struct ListModel: Decodable, Equatable {
        struct Details: Decodable, Equatable {
            let parameter_size: String?
            let quantization_level: String?
        }

        let name: String
        let model: String
        let remote_host: String?
        let details: Details?
    }

    private struct ShowModelResponse: Decodable {
        let capabilities: [String]?
    }

    private struct RunningModelsResponse: Decodable {
        let models: [RunningModel]
    }

    private struct RunningModel: Decodable {
        let name: String
    }

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.baseURL = baseURL

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)
    }

    func fetchCatalogSnapshot() async -> OllamaModelCatalogSnapshot {
        do {
            let installedLocalModels = try await fetchInstalledLocalModels()
            let loadedModelNames = (try? await fetchRunningModelNames()) ?? Set<String>()

            guard !installedLocalModels.isEmpty else {
                return OllamaModelCatalogSnapshot(
                    models: [],
                    runtimeStatus: .noLocalModels,
                    loadedModelNames: loadedModelNames
                )
            }

            let modelDescriptors = await fetchModelDescriptors(for: installedLocalModels)
            let sortedModelDescriptors = modelDescriptors.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            guard !sortedModelDescriptors.isEmpty else {
                return OllamaModelCatalogSnapshot(
                    models: [],
                    runtimeStatus: .noLocalModels,
                    loadedModelNames: loadedModelNames
                )
            }

            return OllamaModelCatalogSnapshot(
                models: sortedModelDescriptors,
                runtimeStatus: .ready,
                loadedModelNames: loadedModelNames
            )
        } catch {
            print("⚠️ Ollama catalog refresh failed: \(error.localizedDescription)")
            return OllamaModelCatalogSnapshot(models: [], runtimeStatus: .unavailable, loadedModelNames: [])
        }
    }

    func fetchInstalledLocalModels() async throws -> [ListModel] {
        let requestURL = baseURL.appending(path: "/api/tags")
        let (responseData, response) = try await session.data(from: requestURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "OllamaModelCatalog",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Ollama model listing failed."]
            )
        }

        let listModelsResponse = try JSONDecoder().decode(ListModelsResponse.self, from: responseData)
        return Self.localInstalledModels(from: listModelsResponse.models)
    }

    func fetchModelCapabilities(for modelName: String) async throws -> [String] {
        let requestURL = baseURL.appending(path: "/api/show")
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelName,
            "verbose": false,
        ])

        let (responseData, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "OllamaModelCatalog",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Ollama model details failed for \(modelName)."]
            )
        }

        let showModelResponse = try JSONDecoder().decode(ShowModelResponse.self, from: responseData)
        return showModelResponse.capabilities ?? []
    }

    func fetchRunningModelNames() async throws -> Set<String> {
        let requestURL = baseURL.appending(path: "/api/ps")
        let (responseData, response) = try await session.data(from: requestURL)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "OllamaModelCatalog",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Ollama running model listing failed."]
            )
        }

        let runningModelsResponse = try JSONDecoder().decode(RunningModelsResponse.self, from: responseData)
        return Set(runningModelsResponse.models.map(\.name))
    }

    @MainActor
    func startOllamaApp() async -> Bool {
        if (try? await fetchInstalledLocalModels()) != nil {
            return true
        }

        let ollamaAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama")
            ?? URL(fileURLWithPath: "/Applications/Ollama.app")

        let didOpenApp = await withCheckedContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false

            NSWorkspace.shared.openApplication(at: ollamaAppURL, configuration: configuration) { _, error in
                continuation.resume(returning: error == nil)
            }
        }

        guard didOpenApp else { return false }

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if (try? await fetchInstalledLocalModels()) != nil {
                return true
            }

            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return false
            }
        }

        return false
    }

    func pullModel(
        named modelName: String,
        onProgress: @escaping @Sendable (OllamaPullProgress) -> Void
    ) async throws {
        let requestURL = baseURL.appending(path: "/api/pull")
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelName,
            "stream": true,
        ])

        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "OllamaModelCatalog",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Ollama model download failed for \(modelName)."]
            )
        }

        for try await line in byteStream.lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }
            guard let lineData = trimmedLine.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            if let errorMessage = payload["error"] as? String {
                throw NSError(
                    domain: "OllamaModelCatalog",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: errorMessage]
                )
            }

            let status = (payload["status"] as? String) ?? "Downloading \(modelName)"
            let completedUnitCount = Self.int64Value(from: payload["completed"])
            let totalUnitCount = Self.int64Value(from: payload["total"])

            onProgress(
                OllamaPullProgress(
                    status: status,
                    completedUnitCount: completedUnitCount,
                    totalUnitCount: totalUnitCount
                )
            )
        }
    }

    func preloadModel(named modelName: String) async throws {
        let requestURL = baseURL.appending(path: "/api/generate")
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelName,
            "keep_alive": -1,
        ])

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "OllamaModelCatalog",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Ollama failed to load \(modelName)."]
            )
        }
    }

    private func fetchModelDescriptors(for installedLocalModels: [ListModel]) async -> [OllamaModelDescriptor] {
        await withTaskGroup(of: OllamaModelDescriptor.self) { taskGroup in
            for installedLocalModel in installedLocalModels {
                taskGroup.addTask { [session = self.session, baseURL = self.baseURL] in
                    let supportsVision = await Self.fetchVisionSupport(
                        session: session,
                        baseURL: baseURL,
                        modelName: installedLocalModel.name
                    )

                    return OllamaModelDescriptor(
                        name: installedLocalModel.name,
                        supportsVision: supportsVision,
                        parameterSize: installedLocalModel.details?.parameter_size,
                        quantizationLevel: installedLocalModel.details?.quantization_level
                    )
                }
            }

            var descriptors: [OllamaModelDescriptor] = []
            for await descriptor in taskGroup {
                descriptors.append(descriptor)
            }
            return descriptors
        }
    }

    private static func fetchVisionSupport(
        session: URLSession,
        baseURL: URL,
        modelName: String
    ) async -> Bool {
        do {
            let requestURL = baseURL.appending(path: "/api/show")
            var request = URLRequest(url: requestURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": modelName,
                "verbose": false,
            ])

            let (responseData, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return false
            }

            let showModelResponse = try JSONDecoder().decode(ShowModelResponse.self, from: responseData)
            return (showModelResponse.capabilities ?? []).contains("vision")
        } catch {
            print("⚠️ Ollama capabilities lookup failed for \(modelName): \(error.localizedDescription)")
            return false
        }
    }

    static func localInstalledModels(from listModels: [ListModel]) -> [ListModel] {
        listModels.filter { listedModel in
            let remoteHost = listedModel.remote_host?.trimmingCharacters(in: .whitespacesAndNewlines)
            return remoteHost == nil || remoteHost?.isEmpty == true
        }
    }

    static func defaultModelName(
        from modelDescriptors: [OllamaModelDescriptor],
        savedModelName: String?
    ) -> String? {
        if let savedModelName,
           modelDescriptors.contains(where: { $0.name == savedModelName }) {
            return savedModelName
        }

        if modelDescriptors.contains(where: { $0.name == "gemma4:e4b" }) {
            return "gemma4:e4b"
        }

        return modelDescriptors
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .first?
            .name
    }

    private static func int64Value(from rawValue: Any?) -> Int64? {
        switch rawValue {
        case let value as Int64:
            return value
        case let value as Int:
            return Int64(value)
        case let value as Double:
            return Int64(value)
        case let value as NSNumber:
            return value.int64Value
        default:
            return nil
        }
    }
}
