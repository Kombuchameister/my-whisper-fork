import Foundation
import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import GroqPlugin

final class GroqPluginTests: XCTestCase {
    func testCommandBudgetReachesGroqWithoutChangingOrdinaryWorkflowRequests() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "test-key"])
        let plugin = GroqPlugin()
        plugin.activate(host: host)
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: (0..<2).map { _ in
                .success(Data(#"{"choices":[{"message":{"content":"Ready"},"finish_reason":"stop"}]}"#.utf8),
                    Self.httpResponse(url: "https://api.groq.com/openai/v1/chat/completions", statusCode: 200))
            })
        }
        _ = try await PluginLLMRequestBudget.$maxOutputTokens.withValue(1_024) {
            try await plugin.process(systemPrompt: "Plan", userText: "Open Safari", model: "openai/gpt-oss-20b")
        }
        _ = try await plugin.process(systemPrompt: "Cleanup", userText: "hello", model: "openai/gpt-oss-20b")
        let requests = store.sessions.flatMap(\.requestedRequests)
        XCTAssertEqual(requests.count, 2)
        let bodies = try requests.map { try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap($0.httpBody)) as? [String: Any]) }
        XCTAssertEqual(bodies[0]["max_tokens"] as? Int, 1_024)
        XCTAssertEqual(bodies[1]["max_tokens"] as? Int, 4_096)
        XCTAssertEqual(bodies[0]["reasoning_effort"] as? String, "medium")
        XCTAssertNil(PluginLLMRequestBudget.maxOutputTokens)
    }

    func testBudgetedGroqErrorsAndTruncationDoNotRetry() async throws {
        for status in [200, 429] {
            PluginHTTPClientTestHarness.reset()
            let host = try PluginTestHostServices(secrets: ["api-key": "test-key"])
            let plugin = GroqPlugin()
            plugin.activate(host: host)
            let store = PluginHTTPClientSessionStore()
            PluginHTTPClientTestHarness.configure { _ in
                store.makeSession(outcomes: [.success(
                    Data(#"{"choices":[{"message":{"content":"partial plan"},"finish_reason":"length"}]}"#.utf8),
                    Self.httpResponse(url: "https://api.groq.com/openai/v1/chat/completions", statusCode: status)
                )])
            }
            do {
                _ = try await PluginLLMRequestBudget.$maxOutputTokens.withValue(1_024) {
                    try await plugin.process(systemPrompt: "Plan", userText: "Open Safari", model: "openai/gpt-oss-20b")
                }
                XCTFail("Expected an error")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(status == 429 ? "Rate limit" : "output limit"))
            }
            XCTAssertEqual(store.sessions.flatMap(\.requestedRequests).count, 1)
            XCTAssertNil(PluginLLMRequestBudget.maxOutputTokens)
        }
    }

    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testTranscribeUsesLongTimeoutForLargerAudioUploads() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "whisper-large-v3"],
            secrets: ["api-key": "groq-key"]
        )
        let plugin = GroqPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"hello","language":"en"}"#.utf8),
                    Self.httpResponse(
                        url: "https://api.groq.com/openai/v1/audio/transcriptions",
                        statusCode: 200
                    )
                ),
            ])
        }

        let audio = AudioData(samples: [0, 0, 0], wavData: Data("wav".utf8), duration: 1.0)
        let result = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil)

        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(store.sessions[0].requestedPaths, ["/openai/v1/audio/transcriptions"])
        let request = try XCTUnwrap(store.sessions[0].requestedRequests.first)
        XCTAssertEqual(request.timeoutInterval, 600)

        let body = try XCTUnwrap(request.httpBody)
        let bodyText = String(decoding: body.prefix(1_024), as: UTF8.self)
        XCTAssertTrue(bodyText.contains(#"filename="audio.m4a""#))
        XCTAssertTrue(bodyText.contains("Content-Type: audio/mp4"))
        XCTAssertFalse(bodyText.contains(#"filename="audio.wav""#))
    }

    func testTranscribeRetriesWithWavWhenGroqRejectsM4AUpload() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "whisper-large-v3"],
            secrets: ["api-key": "groq-key"]
        )
        let plugin = GroqPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"error":{"message":"could not process file - is it a valid media file?","type":"invalid_request_error"}}"#.utf8),
                    Self.httpResponse(
                        url: "https://api.groq.com/openai/v1/audio/transcriptions",
                        statusCode: 400
                    )
                ),
                .success(
                    Data(#"{"text":"hello","language":"de"}"#.utf8),
                    Self.httpResponse(
                        url: "https://api.groq.com/openai/v1/audio/transcriptions",
                        statusCode: 200
                    )
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(
            samples: samples,
            wavData: PluginWavEncoder.encode(samples),
            duration: 1.0
        )
        let result = try await plugin.transcribe(
            audio: audio,
            language: "de",
            translate: false,
            prompt: "TypeWhisper"
        )

        XCTAssertEqual(result.text, "hello")
        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(store.sessions[0].requestedPaths, [
            "/openai/v1/audio/transcriptions",
            "/openai/v1/audio/transcriptions",
        ])

        let firstBody = String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self)
        XCTAssertTrue(firstBody.contains(#"filename="audio.m4a""#))
        XCTAssertTrue(firstBody.contains("Content-Type: audio/mp4"))

        let retryBody = String(decoding: try XCTUnwrap(requests[1].httpBody), as: UTF8.self)
        XCTAssertTrue(retryBody.contains(#"filename="audio.wav""#))
        XCTAssertTrue(retryBody.contains("Content-Type: audio/wav"))
        XCTAssertTrue(retryBody.contains("name=\"model\"\r\n\r\nwhisper-large-v3"))
        XCTAssertTrue(retryBody.contains("name=\"language\"\r\n\r\nde"))
        XCTAssertTrue(retryBody.contains("name=\"prompt\"\r\n\r\nTypeWhisper"))
        XCTAssertEqual(requests[1].timeoutInterval, 600)
    }

    func testPreferredModelIdReflectsSelectedLLMModel() throws {
        let host = try PluginTestHostServices()
        let plugin = GroqPlugin()
        plugin.activate(host: host)

        XCTAssertNil(
            (plugin as? LLMModelSelectable)?.preferredModelId ?? nil,
            "preferredModelId must be nil until the user selects a model"
        )

        let target = try XCTUnwrap(plugin.supportedModels.first?.id)
        plugin.selectLLMModel(target)

        let preferred = (plugin as? LLMModelSelectable)?.preferredModelId
        XCTAssertEqual(preferred, target)
    }

    func testReasoningEffortCapabilityIsModelSpecific() throws {
        let plugin = GroqPlugin()
        let capability = try XCTUnwrap(plugin as? any LLMEffortControllableProvider)

        XCTAssertEqual(
            capability.supportedEfforts(for: "openai/gpt-oss-120b").map(\.id),
            ["low", "medium", "high"]
        )
        XCTAssertEqual(capability.defaultEffortId(for: "openai/gpt-oss-120b"), "medium")
        XCTAssertTrue(capability.supportedEfforts(for: "llama-3.3-70b-versatile").isEmpty)
    }

    func testWorkflowEffortOverridesGroqIntegrationDefaultInRequest() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                "selectedLLMModel": "openai/gpt-oss-120b",
                "reasoningEffort": "low",
            ],
            secrets: ["api-key": "groq-key"]
        )
        let plugin = GroqPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"choices":[{"message":{"content":"done"}}]}"#.utf8),
                    Self.httpResponse(url: "https://api.groq.com/openai/v1/chat/completions", statusCode: 200)
                ),
            ])
        }

        let capability = try XCTUnwrap(plugin as? any LLMEffortControllableProvider)
        _ = try await capability.process(
            systemPrompt: "System",
            userText: "Text",
            model: "openai/gpt-oss-120b",
            effort: "high"
        )

        let body = try XCTUnwrap(store.sessions.first?.requestedRequests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["reasoning_effort"] as? String, "high")
    }

    func testNilEffortUsesGroqIntegrationDefaultInRequest() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                "selectedLLMModel": "openai/gpt-oss-120b",
                "reasoningEffort": "low",
            ],
            secrets: ["api-key": "groq-key"]
        )
        let plugin = GroqPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"choices":[{"message":{"content":"done"}}]}"#.utf8),
                    Self.httpResponse(url: "https://api.groq.com/openai/v1/chat/completions", statusCode: 200)
                ),
            ])
        }

        let capability = try XCTUnwrap(plugin as? any LLMEffortControllableProvider)
        _ = try await capability.process(
            systemPrompt: "System",
            userText: "Text",
            model: nil,
            effort: nil
        )

        let body = try XCTUnwrap(store.sessions.first?.requestedRequests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "openai/gpt-oss-120b")
        XCTAssertEqual(json["reasoning_effort"] as? String, "low")
    }

    private static func httpResponse(url: String, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
