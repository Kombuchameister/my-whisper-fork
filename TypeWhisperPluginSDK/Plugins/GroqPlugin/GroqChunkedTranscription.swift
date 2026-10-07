import Foundation
import TypeWhisperPluginSDK

/// Splits long audio into uploads Groq accepts.
///
/// Groq rejects request bodies above its upload limit (25 MB on the free and developer
/// tiers) at its edge proxy with a 413, before the request reaches the API. The proxy
/// answers while the body is still being sent and closes the connection, so URLSession
/// reports `-1005 The network connection was lost` instead of the 413, and the request
/// never appears in the Groq dashboard. At the 48 kbit/s AAC upload rate the limit is
/// about 70 minutes of audio, so longer files are transcribed in chunks.
enum GroqChunkedTranscription {
    static let sampleRate = PluginAudioUploadEncoder.sampleRate
    /// Ten minutes is about 3.6 MB as AAC and 19.2 MB as the WAV fallback, so both upload
    /// formats stay under the limit.
    static let maxChunkDuration: TimeInterval = 600
    /// Each cut is placed at the quietest point in this window before the ten-minute
    /// mark, so words are rarely split between two requests.
    static let boundarySearchWindow: TimeInterval = 30
    static let analysisFrameDuration: TimeInterval = 0.1

    /// Sample ranges that cover `samples` without gaps, each at most `maxChunkDuration` long.
    static func chunkRanges(
        for samples: [Float],
        maxChunkDuration: TimeInterval = maxChunkDuration,
        boundarySearchWindow: TimeInterval = boundarySearchWindow
    ) -> [Range<Int>] {
        let maxChunkSamples = Int(maxChunkDuration * Double(sampleRate))
        guard maxChunkSamples > 0, samples.count > maxChunkSamples else {
            return [0..<samples.count]
        }

        let windowSamples = min(Int(boundarySearchWindow * Double(sampleRate)), maxChunkSamples / 2)
        var ranges: [Range<Int>] = []
        var start = 0
        while samples.count - start > maxChunkSamples {
            let latestCut = start + maxChunkSamples
            let cut = quietestCut(in: samples, from: latestCut - windowSamples, to: latestCut)
            ranges.append(start..<cut)
            start = cut
        }
        ranges.append(start..<samples.count)
        return ranges
    }

    /// The middle of the quietest analysis frame in `lower..<upper`.
    static func quietestCut(in samples: [Float], from lower: Int, to upper: Int) -> Int {
        let frameSamples = max(1, Int(analysisFrameDuration * Double(sampleRate)))
        guard upper - lower >= frameSamples else { return upper }

        var bestStart = upper - frameSamples
        var bestEnergy = Float.greatestFiniteMagnitude
        var frameStart = upper - frameSamples
        // Scan backwards so ties keep the cut as late, and the chunk as long, as possible.
        while frameStart >= lower {
            var energy: Float = 0
            for index in frameStart..<(frameStart + frameSamples) {
                energy += samples[index] * samples[index]
            }
            if energy < bestEnergy {
                bestEnergy = energy
                bestStart = frameStart
            }
            frameStart -= frameSamples
        }
        return bestStart + frameSamples / 2
    }

    /// Transcribes `audio` with one `upload` call per chunk, in order, and joins the results.
    /// Audio that fits in one chunk is passed to `upload` unchanged.
    static func transcribe(
        audio: AudioData,
        onSourceProgress: @Sendable (PluginTranscriptionSourceProgress) -> Bool,
        upload: (AudioData) async throws -> PluginTranscriptionResult
    ) async throws -> PluginTranscriptionResult {
        let ranges = chunkRanges(for: audio.samples)
        guard ranges.count > 1 else {
            return try await upload(audio)
        }

        let totalDuration = Double(audio.samples.count) / Double(sampleRate)
        var texts: [String] = []
        var segments: [PluginTranscriptionSegment] = []
        var detectedLanguage: String?

        for range in ranges {
            try Task.checkCancellation()
            let offset = Double(range.lowerBound) / Double(sampleRate)
            let chunkSamples = Array(audio.samples[range])
            let chunk = AudioData(
                samples: chunkSamples,
                wavData: PluginWavEncoder.encode(chunkSamples, sampleRate: sampleRate),
                duration: Double(chunkSamples.count) / Double(sampleRate)
            )

            let result = try await upload(chunk)

            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                texts.append(text)
            }
            segments += result.segments.map {
                PluginTranscriptionSegment(text: $0.text, start: $0.start + offset, end: $0.end + offset)
            }
            detectedLanguage = detectedLanguage ?? result.detectedLanguage

            let progress = PluginTranscriptionSourceProgress(
                processedDuration: Double(range.upperBound) / Double(sampleRate),
                totalDuration: totalDuration,
                previewText: text.isEmpty ? nil : text
            )
            guard onSourceProgress(progress) else {
                throw CancellationError()
            }
        }

        return PluginTranscriptionResult(
            text: texts.joined(separator: " "),
            detectedLanguage: detectedLanguage,
            segments: segments
        )
    }
}

extension GroqPlugin: SourceProgressTranscriptionEnginePlugin {
    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool,
        onSourceProgress: @Sendable @escaping (PluginTranscriptionSourceProgress) -> Bool
    ) async throws -> PluginTranscriptionResult {
        let result = try await transcribeInChunks(
            audio: audio,
            language: language,
            translate: translate,
            prompt: prompt,
            onSourceProgress: onSourceProgress
        )
        _ = onProgress(result.text)
        return result
    }
}
