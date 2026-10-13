import Foundation
import Observation

/// The rolling state of the current meeting: the merged, speaker-attributed transcript plus a
/// log of tool calls/results. Both the proactive analyzer and the chat view model read from
/// this to build LLM context; nothing else mutates the transcript directly.
@MainActor
@Observable
final class MeetingContext {
    /// Which physical audio stream a transcription update came from. Open-segment tracking is
    /// keyed by stream rather than by speaker label: with diarization, the system stream's
    /// label can CHANGE between a volatile update ("Them") and its final ("Speaker 2"), but
    /// it's still the same utterance from the same stream.
    enum AudioStream: Hashable, Sendable {
        case mic
        case system
    }

    private(set) var segments: [TranscriptSegment] = []
    /// Index of the currently-in-progress (not-yet-final) segment for each stream, if any.
    private var openSegmentIndex: [AudioStream: Int] = [:]

    /// Formatted summaries/action items from prior occurrences of the current meeting, if it's
    /// a recognized standing meeting — set by `AppModel.startMeeting()`, read by `ChatViewModel`
    /// and `ProactiveAnalyzer` when building their system prompts. Empty when there's no known
    /// series (e.g. the meeting wasn't started from a calendar event) or no prior occurrences.
    var priorMeetingContext: String = ""

    /// Whatever the user typed into the "tell Clyde about this meeting" modal before starting —
    /// who's involved, what it's about, anything to avoid Clyde making wrong assumptions from
    /// the transcript alone. Empty if they skipped it. Read by ChatViewModel, ProactiveAnalyzer,
    /// and MeetingSummarizer alongside `priorMeetingContext`.
    var userProvidedContext: String = ""

    /// Text of only the finalized segments, oldest-first, formatted for use as LLM context.
    var finalizedTranscriptText: String {
        segments
            .filter(\.isFinal)
            .map { "\($0.speaker.displayName): \($0.text)" }
            .joined(separator: "\n")
    }

    /// IDs of finalized segments the analyzer has already consumed. Tracked by identity rather
    /// than by count because segments don't always finalize in array order — a stale open
    /// segment can be closed in place (see `upsert`) after later segments already finalized.
    private var analyzedSegmentIDs: Set<String> = []

    func consumeNewFinalizedText() -> String? {
        let newOnes = segments.filter { $0.isFinal && !analyzedSegmentIDs.contains($0.id) }
        guard !newOnes.isEmpty else { return nil }
        for segment in newOnes { analyzedSegmentIDs.insert(segment.id) }
        return newOnes.map { "\($0.speaker.displayName): \($0.text)" }.joined(separator: "\n")
    }

    /// SpeechAnalyzer reports volatile (in-progress) results for an utterance, revising them —
    /// sometimes including the audio time range they cover — as it gets more context, then a
    /// final result once it settles. That range can shift slightly between a volatile guess and
    /// its corrected final version (e.g. it may reinterpret exactly where the utterance
    /// started), so keying segment identity off the reported range caused the same utterance to
    /// show up as two separate lines whenever the correction shifted it — one stuck showing the
    /// stale volatile guess, one final. Tracking "is there a currently-open, not-yet-final
    /// segment for this speaker" instead sidesteps that: at most one utterance can be in
    /// progress per speaker at a time regardless of how its reported range wobbles, and the next
    /// update after a final is unambiguously the start of a new one.
    /// If an open segment hasn't received an update in this long, the next update is treated as
    /// a NEW utterance rather than a continuation. Without this, a stray noise blip (a volatile
    /// "." from the mic that never gets finalized) leaves a segment open indefinitely, and real
    /// speech minutes later lands in it — showing up way back at the blip's position in the
    /// timeline instead of at the end. Volatile updates during actual speech arrive many times
    /// a second, so a multi-second gap reliably means the old segment is dead.
    private static let openSegmentStaleInterval: TimeInterval = 4

    /// When the last update to each stream's open segment arrived — for staleness, deliberately
    /// distinct from the segment's own `timestamp` (its position in the timeline).
    private var openSegmentLastUpdate: [AudioStream: Date] = [:]

    func upsert(_ update: TranscriptionUpdate, stream: AudioStream, speaker: Speaker) {
        if let index = openSegmentIndex[stream], !segments[index].isFinal {
            let lastUpdate = openSegmentLastUpdate[stream] ?? .distantPast
            if Date().timeIntervalSince(lastUpdate) <= Self.openSegmentStaleInterval {
                segments[index].text = update.text
                segments[index].isFinal = update.isFinal
                segments[index].speaker = speaker // diarizer may resolve "Them" → "Speaker N"
                openSegmentLastUpdate[stream] = Date()
                if update.isFinal {
                    openSegmentIndex.removeValue(forKey: stream)
                    openSegmentLastUpdate.removeValue(forKey: stream)
                }
                return
            }
            // Stale: close the abandoned segment where it sits and let this update start a new
            // one at the end of the timeline. Noise-only leftovers (e.g. a bare ".") are dropped
            // entirely rather than shown/fed to the LLM as a meaningless line.
            if Self.isNoiseOnly(segments[index].text) {
                removeSegment(at: index)
            } else {
                segments[index].isFinal = true
            }
            openSegmentIndex.removeValue(forKey: stream)
            openSegmentLastUpdate.removeValue(forKey: stream)
        }

        // Don't create a segment for noise-only text (stray punctuation from breaths/keyboard
        // sounds) — wait until a volatile update carries actual words.
        guard !Self.isNoiseOnly(update.text) else { return }

        let segment = TranscriptSegment(
            id: UUID().uuidString, speaker: speaker, text: update.text,
            isFinal: update.isFinal, timestamp: Date()
        )
        segments.append(segment)
        if !update.isFinal {
            openSegmentIndex[stream] = segments.count - 1
            openSegmentLastUpdate[stream] = Date()
        }
    }

    /// True for text with no letters or digits in it — bare punctuation like "." or "…" that
    /// the transcriber sometimes emits for non-speech sounds.
    private static func isNoiseOnly(_ text: String) -> Bool {
        !text.contains(where: { $0.isLetter || $0.isNumber })
    }

    private func removeSegment(at index: Int) {
        segments.remove(at: index)
        for (stream, openIndex) in openSegmentIndex {
            if openIndex == index {
                openSegmentIndex.removeValue(forKey: stream)
                openSegmentLastUpdate.removeValue(forKey: stream)
            } else if openIndex > index {
                openSegmentIndex[stream] = openIndex - 1
            }
        }
    }

    func reset() {
        segments.removeAll()
        openSegmentIndex.removeAll()
        openSegmentLastUpdate.removeAll()
        analyzedSegmentIDs.removeAll()
        priorMeetingContext = ""
        userProvidedContext = ""
    }
}
