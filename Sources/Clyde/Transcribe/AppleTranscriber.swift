import Foundation
import AVFAudio
import Speech
import CoreMedia

/// On-device live transcription using macOS 26's SpeechAnalyzer/SpeechTranscriber. One instance
/// is created per audio stream (mic, system audio) — running two instances is how the app gets
/// free "You" vs "Them" speaker attribution, since the API itself does not diarize.
///
/// Key correctness details (learned from Apple's docs and real-world reports, not just the
/// headline API surface):
///   - The transcriber requires audio in the exact format `bestAvailableAudioFormat` returns;
///     an `AVAudioConverter` bridges whatever format the tap/mic delivers (commonly 48kHz
///     stereo Float32) to that format. Feeding the wrong format is the #1 cause of silent
///     "no transcription ever arrives" bugs.
///   - Ending the input AsyncStream does not end the analysis session — the results loop would
///     hang forever without an explicit `finalizeAndFinishThroughEndOfInput()`.
///   - `modelRetention: .processLifetime` avoids a multi-second model reload delay if the user
///     starts a second meeting in the same app session.
final class AppleTranscriber: Transcriber, @unchecked Sendable {
    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    private let updateContinuation: AsyncStream<TranscriptionUpdate>.Continuation
    let updates: AsyncStream<TranscriptionUpdate>

    // Logged once each, not per-buffer: confirms the actual conversion formats in use, and
    // whether the analyzer has produced anything at all — cheap early signal if a future
    // format/permissions change silently breaks transcription again.
    private var didLogFormats = false
    private var didLogFirstResult = false
    private let debugLabel: String

    init(locale: Locale = .current, debugLabel: String = "") {
        self.locale = locale
        self.debugLabel = debugLabel
        var continuation: AsyncStream<TranscriptionUpdate>.Continuation!
        self.updates = AsyncStream { continuation = $0 }
        self.updateContinuation = continuation
    }

    func prepare() async throws {
        let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.transcribe.info("Downloading speech model for \(resolvedLocale.identifier, privacy: .public)…")
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .high, modelRetention: .processLifetime)
        )
        self.analyzer = analyzer
        self.analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    }

    func start() async throws {
        guard let analyzer, let transcriber else {
            throw TranscriberError.notPrepared
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation
        try await analyzer.start(inputSequence: stream)

        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    if !self.didLogFirstResult {
                        self.didLogFirstResult = true
                        Log.transcribe.info("[\(self.debugLabel, privacy: .public)] first SpeechTranscriber result received (isFinal=\(result.isFinal))")
                    }
                    self.updateContinuation.yield(
                        TranscriptionUpdate(
                            text: String(result.text.characters[...]),
                            isFinal: result.isFinal
                        )
                    )
                }
            } catch {
                Log.transcribe.error("[\(self.debugLabel, privacy: .public)] Transcriber results stream ended with error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func ingest(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        guard let inputContinuation, let analyzerFormat else { return }

        if !didLogFormats {
            didLogFormats = true
            Log.transcribe.info("[\(self.debugLabel, privacy: .public)] input format: \(buffer.format.sampleRate, privacy: .public)Hz \(buffer.format.channelCount, privacy: .public)ch -> analyzer format: \(analyzerFormat.sampleRate, privacy: .public)Hz \(analyzerFormat.channelCount, privacy: .public)ch")
        }

        let converted: AVAudioPCMBuffer
        if buffer.format == analyzerFormat {
            converted = buffer
        } else {
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
            }
            guard let converter else { return }

            let ratio = analyzerFormat.sampleRate / max(buffer.format.sampleRate, 1)
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }

            var error: NSError?
            var consumed = false
            converter.convert(to: out, error: &error) { _, inputStatus in
                if consumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if let error {
                Log.transcribe.error("[\(self.debugLabel, privacy: .public)] Audio conversion failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            converted = out
        }

        inputContinuation.yield(AnalyzerInput(buffer: converted))
    }

    func finalizeNow() async {
        guard let analyzer else { return }
        do {
            try await analyzer.finalize(through: analyzer.volatileRange?.end)
        } catch {
            Log.transcribe.error("finalizeNow failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() async {
        inputContinuation?.finish()
        inputContinuation = nil
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.transcribe.error("Finalize-on-stop failed: \(error.localizedDescription, privacy: .public)")
        }
        resultsTask?.cancel()
        resultsTask = nil
        updateContinuation.finish()
    }
}

enum TranscriberError: Error, LocalizedError {
    case notPrepared

    var errorDescription: String? {
        switch self {
        case .notPrepared: return "Transcriber was started before prepare() completed."
        }
    }
}
