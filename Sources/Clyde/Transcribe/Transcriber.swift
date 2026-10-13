import Foundation
import AVFAudio

/// A single transcription update. Volatile (isFinal == false) results are re-emitted "in place"
/// for the same in-progress utterance as more audio arrives, and should replace the previous
/// volatile text in the UI; once `isFinal` is true, that utterance is settled and the next
/// update for this speaker starts a new one — see MeetingContext.upsert for how that's tracked.
struct TranscriptionUpdate: Sendable {
    var text: String
    var isFinal: Bool
}

/// Abstraction over a live speech-to-text engine, so the on-device Apple implementation
/// (AppleTranscriber) can later be swapped for a cloud engine (Deepgram/AssemblyAI) or
/// WhisperKit without touching the audio pipeline or TranscriptStore.
protocol Transcriber: AnyObject, Sendable {
    /// Stream of transcription updates for whatever audio has been fed via `ingest`.
    var updates: AsyncStream<TranscriptionUpdate> { get }

    /// Prepare the engine (e.g. download/load models) without starting to consume audio yet.
    /// Call this well before a meeting starts to avoid first-utterance latency.
    func prepare() async throws

    /// Begin accepting audio buffers.
    func start() async throws

    /// Feed one buffer of audio. `buffer.format` need not match the engine's native format —
    /// implementations are responsible for converting to whatever format they require.
    func ingest(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?)

    /// Force any pending volatile results to finalize immediately (e.g. because the user just
    /// asked "what did they just say?" and we need settled text right now).
    func finalizeNow() async

    /// Stop accepting audio and end the `updates` stream.
    func stop() async
}
