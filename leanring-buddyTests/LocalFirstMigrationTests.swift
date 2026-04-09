//
//  LocalFirstMigrationTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import leanring_buddy

struct LocalFirstMigrationTests {
    private actor TranscriptionInvocationRecorder {
        private(set) var primaryInvocationURLs: [URL] = []
        private(set) var fallbackInvocationURLs: [URL] = []
        private(set) var fallbackInvocationKeyterms: [[String]] = []

        func recordPrimaryInvocation(url: URL) {
            primaryInvocationURLs.append(url)
        }

        func recordFallbackInvocation(url: URL, keyterms: [String]) {
            fallbackInvocationURLs.append(url)
            fallbackInvocationKeyterms.append(keyterms)
        }
    }

    @Test func localModelCatalogExcludesRemoteOnlyEntries() throws {
        let listedModels = [
            OllamaModelCatalog.ListModel(
                name: "gemma4:e4b",
                model: "gemma4:e4b",
                remote_host: nil,
                details: .init(parameter_size: "4B", quantization_level: "Q4_K_M")
            ),
            OllamaModelCatalog.ListModel(
                name: "glm-4.6:cloud",
                model: "glm-4.6:cloud",
                remote_host: "https://ollama.com:443",
                details: .init(parameter_size: "355B", quantization_level: "FP8")
            )
        ]

        let localModels = OllamaModelCatalog.localInstalledModels(from: listedModels)

        #expect(localModels.map(\.name) == ["gemma4:e4b"])
    }

    @Test func defaultModelPrefersSavedInstalledSelection() throws {
        let descriptors = [
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
            )
        ]

        let defaultModelName = OllamaModelCatalog.defaultModelName(
            from: descriptors,
            savedModelName: "llama3.2"
        )

        #expect(defaultModelName == "llama3.2")
    }

    @Test func defaultModelPrefersGemmaWhenNoSavedSelectionExists() throws {
        let descriptors = [
            OllamaModelDescriptor(
                name: "llama3.2",
                supportsVision: false,
                parameterSize: "3B",
                quantizationLevel: "Q4_K_M"
            ),
            OllamaModelDescriptor(
                name: "gemma4:e4b",
                supportsVision: true,
                parameterSize: "4B",
                quantizationLevel: "Q4_K_M"
            )
        ]

        let defaultModelName = OllamaModelCatalog.defaultModelName(
            from: descriptors,
            savedModelName: nil
        )

        #expect(defaultModelName == "gemma4:e4b")
    }

    @Test func defaultModelFallsBackToFirstSortedInstalledModel() throws {
        let descriptors = [
            OllamaModelDescriptor(
                name: "zeta-vision",
                supportsVision: true,
                parameterSize: "7B",
                quantizationLevel: "Q4_K_M"
            ),
            OllamaModelDescriptor(
                name: "alpha-text",
                supportsVision: false,
                parameterSize: "3B",
                quantizationLevel: "Q4_K_M"
            )
        ]

        let defaultModelName = OllamaModelCatalog.defaultModelName(
            from: descriptors,
            savedModelName: nil
        )

        #expect(defaultModelName == "alpha-text")
    }

    @Test func ollamaStreamParserReturnsVisibleContentOnly() throws {
        let streamLine = #"{"message":{"role":"assistant","content":"hello there","thinking":"hidden"},"done":false}"#

        let streamChunk = OllamaChatClient.parseStreamChunk(from: streamLine)

        #expect(streamChunk == OllamaStreamChunk(visibleContent: "hello there", isDone: false))
    }

    @Test func ollamaStreamParserRecognizesDoneMessage() throws {
        let streamLine = #"{"message":{"role":"assistant","content":""},"done":true}"#

        let streamChunk = OllamaChatClient.parseStreamChunk(from: streamLine)

        #expect(streamChunk == OllamaStreamChunk(visibleContent: "", isDone: true))
    }

    @Test func localTranscriptionFallbackUsesFallbackWhenPrimaryFails() async throws {
        enum SampleError: Error {
            case unavailable
        }

        let transcriptText = try await LocalFileTranscriptionFallback.transcribe(
            primaryTranscription: {
                throw SampleError.unavailable
            },
            fallbackTranscription: {
                "fallback transcript"
            }
        )

        #expect(transcriptText == "fallback transcript")
    }

    @Test func whisperKitFileTranscriptionPipelineFallsBackWhenPrimaryFails() async throws {
        enum SampleError: Error {
            case unavailable
        }

        let sampleAudioFileURL = URL(fileURLWithPath: "/tmp/clicky-whisperkit-test.wav")
        let invocationRecorder = TranscriptionInvocationRecorder()

        let transcriptText = try await WhisperKitFileTranscriptionPipeline.transcribeAudioFile(
            at: sampleAudioFileURL,
            contextualKeyterms: ["clicky", "ollama"],
            primaryTranscription: { audioFileURL in
                await invocationRecorder.recordPrimaryInvocation(url: audioFileURL)
                throw SampleError.unavailable
            },
            fallbackTranscription: { audioFileURL, contextualKeyterms in
                await invocationRecorder.recordFallbackInvocation(
                    url: audioFileURL,
                    keyterms: contextualKeyterms
                )
                return "fallback transcript"
            }
        )

        let primaryInvocationURLs = await invocationRecorder.primaryInvocationURLs
        let fallbackInvocationURLs = await invocationRecorder.fallbackInvocationURLs
        let fallbackInvocationKeyterms = await invocationRecorder.fallbackInvocationKeyterms

        #expect(transcriptText == "fallback transcript")
        #expect(primaryInvocationURLs == [sampleAudioFileURL])
        #expect(fallbackInvocationURLs == [sampleAudioFileURL])
        #expect(fallbackInvocationKeyterms == [["clicky", "ollama"]])
    }

    @Test func localTranscriptionFallbackUsesFallbackWhenPrimaryTimesOut() async throws {
        let transcriptText = try await LocalFileTranscriptionFallback.transcribe(
            primaryTranscription: {
                try await Task.sleep(nanoseconds: 300_000_000)
                return "slow primary transcript"
            },
            fallbackTranscription: {
                "fallback transcript"
            },
            primaryTimeoutSeconds: 0.05
        )

        #expect(transcriptText == "fallback transcript")
    }

    @Test func pullProgressFormatsPercentagesForPanelCopy() throws {
        let progress = OllamaPullProgress(
            status: "downloading",
            completedUnitCount: 25,
            totalUnitCount: 100
        )

        #expect(progress.userFacingDescription == "downloading 25%")
    }

    @Test func pointTagParserHandlesCrossScreenCoordinates() throws {
        let parseResult = CompanionManager.parsePointingCoordinates(
            from: "open the project navigator [POINT:120,40:project navigator:screen2]"
        )

        #expect(parseResult.spokenText == "open the project navigator")
        #expect(parseResult.coordinate == CGPoint(x: 120, y: 40))
        #expect(parseResult.elementLabel == "project navigator")
        #expect(parseResult.screenNumber == 2)
    }

    @Test func pointTagParserHandlesSameScreenCoordinates() throws {
        let parseResult = CompanionManager.parsePointingCoordinates(
            from: "open the project navigator [POINT:120,40:project navigator]"
        )

        #expect(parseResult.spokenText == "open the project navigator")
        #expect(parseResult.coordinate == CGPoint(x: 120, y: 40))
        #expect(parseResult.elementLabel == "project navigator")
        #expect(parseResult.screenNumber == nil)
    }

    @Test func pointTagParserHandlesNoPointingCase() throws {
        let parseResult = CompanionManager.parsePointingCoordinates(
            from: "html is the structure of a web page [POINT:none]"
        )

        #expect(parseResult.spokenText == "html is the structure of a web page")
        #expect(parseResult.coordinate == nil)
        #expect(parseResult.elementLabel == "none")
        #expect(parseResult.screenNumber == nil)
    }
}
