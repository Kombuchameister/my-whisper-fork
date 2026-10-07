import Foundation
import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import GroqPlugin

final class GroqChunkedTranscriptionTests: XCTestCase {
    private let rate = 16_000

    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testAudioWithinOneChunkIsUploadedUnchanged() async throws {
        let samples = [Float](repeating: 0.1, count: rate * 600)
        let audio = AudioData(samples: samples, wavData: Data("original".utf8), duration: 600)
        let uploads = UploadRecorder()

        let result = try await GroqChunkedTranscription.transcribe(audio: audio, onSourceProgress: { _ in true }) {
            uploads.record($0)
            return PluginTranscriptionResult(text: "whole", detectedLanguage: "en")
        }

        XCTAssertEqual(result.text, "whole")
        XCTAssertEqual(uploads.chunks.count, 1)
        XCTAssertEqual(uploads.chunks[0].wavData, Data("original".utf8))
    }

    func testChunkRangesCoverAudioWithoutGapsAndStayWithinLimit() {
        let samples = [Float](repeating: 0.2, count: rate * 60 * 25 + 123)
        let ranges = GroqChunkedTranscription.chunkRanges(for: samples)

        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, samples.count)
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(previous.upperBound, next.lowerBound)
        }
        for range in ranges {
            XCTAssertLessThanOrEqual(range.count, rate * 600)
        }
    }

    func testChunkBoundaryIsPlacedInTheQuietestPartOfTheSearchWindow() {
        var samples = [Float](repeating: 0.3, count: rate * 60 * 12)
        let silenceStart = rate * (9 * 60 + 45)
        for index in silenceStart..<(silenceStart + rate / 2) {
            samples[index] = 0
        }

        let ranges = GroqChunkedTranscription.chunkRanges(for: samples)

        XCTAssertEqual(ranges.count, 2)
        let cut = ranges[0].upperBound
        XCTAssertGreaterThanOrEqual(cut, silenceStart)
        XCTAssertLessThan(cut, silenceStart + rate / 2)
    }

    func testChunkResultsAreJoinedWithSegmentsShiftedToSourceTime() async throws {
        let samples = [Float](repeating: 0.2, count: rate * 60 * 25)
        let audio = AudioData(samples: samples, wavData: Data(), duration: 1_500)
        let uploads = UploadRecorder()
        let progress = ProgressRecorder()

        let result = try await GroqChunkedTranscription.transcribe(
            audio: audio,
            onSourceProgress: { progress.record($0) }
        ) { chunk in
            let index = uploads.record(chunk)
            return PluginTranscriptionResult(
                text: " part \(index) ",
                detectedLanguage: index == 0 ? "de" : "en",
                segments: [PluginTranscriptionSegment(text: "part \(index)", start: 1, end: 2)]
            )
        }

        XCTAssertEqual(result.text, "part 0 part 1 part 2")
        XCTAssertEqual(result.detectedLanguage, "de")
        let offsets = GroqChunkedTranscription.chunkRanges(for: samples).map { Double($0.lowerBound) / Double(rate) }
        XCTAssertEqual(result.segments.map(\.start), offsets.map { $0 + 1 })
        XCTAssertEqual(result.segments.map(\.end), offsets.map { $0 + 2 })
        XCTAssertEqual(uploads.chunks.map(\.samples.count).reduce(0, +), samples.count)
        XCTAssertEqual(progress.values.last?.processedDuration, 1_500)
        XCTAssertEqual(progress.values.map(\.totalDuration), [1_500, 1_500, 1_500])
    }

    func testDeclinedProgressCancelsRemainingChunks() async {
        let samples = [Float](repeating: 0.2, count: rate * 60 * 25)
        let audio = AudioData(samples: samples, wavData: Data(), duration: 1_500)
        let uploads = UploadRecorder()

        do {
            _ = try await GroqChunkedTranscription.transcribe(audio: audio, onSourceProgress: { _ in false }) {
                uploads.record($0)
                return PluginTranscriptionResult(text: "part")
            }
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(uploads.chunks.count, 1)
    }

    func testPluginSendsLongAudioAsSeparateGroqRequests() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "whisper-large-v3"],
            secrets: ["api-key": "groq-key"]
        )
        let plugin = GroqPlugin()
        plugin.activate(host: host)

        let url = "https://api.groq.com/openai/v1/audio/transcriptions"
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data(#"{"text":"first","language":"en","segments":[{"start":0,"end":3,"text":"first"}]}"#.utf8),
                         Self.httpResponse(url: url)),
                .success(Data(#"{"text":"second","language":"en","segments":[{"start":0,"end":3,"text":"second"}]}"#.utf8),
                         Self.httpResponse(url: url)),
            ])
        }

        let samples = [Float](repeating: 0.1, count: rate * 60 * 12)
        let audio = AudioData(samples: samples, wavData: Data(), duration: 720)
        let result = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil)

        XCTAssertEqual(result.text, "first second")
        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            let body = try XCTUnwrap(request.httpBody)
            XCTAssertLessThan(body.count, 25 * 1_000 * 1_000)
            XCTAssertTrue(String(decoding: body.prefix(1_024), as: UTF8.self).contains(#"filename="audio.m4a""#))
        }
        XCTAssertGreaterThan(result.segments[1].start, 500)
    }

    private static func httpResponse(url: String) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: url)!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

private final class UploadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AudioData] = []

    var chunks: [AudioData] { lock.withLock { storage } }

    @discardableResult
    func record(_ chunk: AudioData) -> Int {
        lock.withLock {
            storage.append(chunk)
            return storage.count - 1
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PluginTranscriptionSourceProgress] = []

    var values: [PluginTranscriptionSourceProgress] { lock.withLock { storage } }

    func record(_ progress: PluginTranscriptionSourceProgress) -> Bool {
        lock.withLock { storage.append(progress) }
        return true
    }
}
