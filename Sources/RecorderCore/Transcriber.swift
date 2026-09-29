import AVFoundation
import Foundation
import Speech

/// On-device transcription with word timings (macOS 26 SpeechAnalyzer).
@available(macOS 26.0, *)
public enum Transcriber {
    public enum Failure: LocalizedError {
        case unsupportedLanguage(String)

        public var errorDescription: String? {
            switch self {
            case let .unsupportedLanguage(id): "On-device transcription doesn't support \(id)."
            }
        }
    }

    /// Resolves a locale Apple's transcriber supports (e.g. en-GB for en_GB).
    public static func supportedLocale(for locale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    /// Transcribes an audio file. Downloads the language model first if needed; `progress` reports 0...1.
    public static func transcribe(audio url: URL, locale requested: Locale,
                                  progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Transcript {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw Failure.unsupportedLanguage(requested.identifier)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }

        let file = try AVAudioFile(forReading: url)
        let total = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Collect results concurrently while the analyzer reads the file.
        let collector = Task { () throws -> [Word] in
            var words: [Word] = []
            for try await result in transcriber.results {
                words += Self.words(from: result.text)
                if let last = words.last, total > 0 { progress(min(last.end / total, 0.99)) }
            }
            return words
        }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        let words = try await collector.value
        progress(1)
        return Transcript(locale: locale.identifier, words: words.sorted { $0.start < $1.start })
    }

    /// Splits a result into words. Each attributed run carries the audio time range of its text; a run holding
    /// several words shares its range between them in proportion to their length.
    static func words(from text: AttributedString) -> [Word] {
        var out: [Word] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let pieces = String(text[run.range].characters).split(whereSeparator: \.isWhitespace).map(String.init)
            guard !pieces.isEmpty else { continue }
            let start = range.start.seconds, dur = range.duration.seconds
            let totalChars = Double(pieces.reduce(0) { $0 + $1.count })
            var t = start
            for p in pieces {
                let d = totalChars > 0 ? dur * Double(p.count) / totalChars : dur / Double(pieces.count)
                out.append(Word(text: p, start: t, end: t + d))
                t += d
            }
        }
        // The first word of a result can be stretched back over leading silence; clamp any implausibly long word
        // to a generous spoken length ending where it really ends, so cuts land on the speech.
        for i in out.indices {
            let plausible = 0.3 + 0.1 * Double(out[i].text.count)
            if out[i].end - out[i].start > plausible { out[i].start = out[i].end - plausible }
        }
        // Punctuation sometimes arrives as its own run; attach it to the previous word.
        var merged: [Word] = []
        for w in out {
            if let last = merged.last, w.text.allSatisfy({ $0.isPunctuation }) {
                merged[merged.count - 1].text = last.text + w.text
                merged[merged.count - 1].end = max(last.end, w.end)
            } else {
                merged.append(w)
            }
        }
        return merged
    }
}
