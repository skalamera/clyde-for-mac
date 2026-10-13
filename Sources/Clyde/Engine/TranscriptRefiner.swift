import Foundation

/// Post-meeting transcript cleanup: once the meeting ends (and before the note is saved), the
/// LLM rewrites the raw live transcript to (a) re-attribute the system-audio side to distinct,
/// consistent speakers from conversational context — live CoreML diarization proved unreliable
/// on real VoIP audio, but context ("thanks, Gina", question/answer turns, topic ownership)
/// usually identifies who's who far better — and (b) strip the speech-to-text junk: filler
/// words, noise fragments, and obvious mis-transcriptions, merging fragmented lines into
/// readable turns WITHOUT dropping any substance.
///
/// Long transcripts are processed in line-aligned chunks, sequentially, with the tail of the
/// previous refined chunk passed along so speaker labels stay consistent across chunk
/// boundaries. Best-effort: any failure falls back to the raw transcript for that chunk —
/// saving the note must never fail because cleanup did.
struct TranscriptRefiner {
    let router: LLMRouter

    /// Max characters of raw transcript per LLM request. Line-aligned; chosen well under model
    /// output limits since the refined output is roughly the same size as the input.
    private static let chunkCharacterLimit = 8000
    /// How many refined lines to carry into the next chunk's prompt for label continuity.
    private static let continuityTailLines = 8

    func refine(transcript: String, userContext: String) async -> String {
        let chunks = Self.splitIntoChunks(transcript)
        guard !chunks.isEmpty else { return transcript }

        var refinedChunks: [String] = []
        var previousTail = ""
        for chunk in chunks {
            do {
                let refined = try await refineChunk(chunk, previousTail: previousTail, userContext: userContext)
                refinedChunks.append(refined)
                previousTail = refined.split(separator: "\n").suffix(Self.continuityTailLines).joined(separator: "\n")
            } catch {
                Log.llm.error("Transcript refinement failed for a chunk — keeping raw text: \(error.localizedDescription, privacy: .public)")
                refinedChunks.append(chunk)
                previousTail = chunk.split(separator: "\n").suffix(Self.continuityTailLines).joined(separator: "\n")
            }
        }
        return refinedChunks.joined(separator: "\n")
    }

    private func refineChunk(_ chunk: String, previousTail: String, userContext: String) async throws -> String {
        var userMessage = ""
        if !userContext.isEmpty {
            userMessage += "Background the user provided about this meeting (context only, not part of the transcript):\n\(userContext)\n\n"
        }
        if !previousTail.isEmpty {
            userMessage += "END OF THE ALREADY-CLEANED PORTION (continue its speaker labels EXACTLY — same names/numbers for the same voices):\n\(previousTail)\n\n"
        }
        userMessage += "RAW TRANSCRIPT TO CLEAN:\n\(chunk)"

        var text = ""
        let stream = router.stream(
            system: Self.systemPrompt,
            messages: [.user(userMessage)],
            tools: [],
            model: router.effectiveModel(for: .chat),
            options: .refinement
        )
        for try await event in stream {
            if case .textDelta(let delta) = event { text += delta }
        }

        let cleaned = Self.stripCodeFences(text).trimmingCharacters(in: .whitespacesAndNewlines)
        // A refusal/apology/empty response instead of a transcript would corrupt the note —
        // heuristic: the output must be transcript-shaped (mostly "Label: text" lines).
        guard Self.looksLikeTranscript(cleaned) else {
            throw RefinerError.malformedOutput(String(cleaned.prefix(120)))
        }
        return cleaned
    }

    /// Line-aligned chunks, each at most `chunkCharacterLimit` characters.
    private static func splitIntoChunks(_ transcript: String) -> [String] {
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: true)
        var chunks: [String] = []
        var current = ""
        for line in lines {
            if !current.isEmpty && current.count + line.count + 1 > chunkCharacterLimit {
                chunks.append(current)
                current = ""
            }
            current += current.isEmpty ? String(line) : "\n\(line)"
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func stripCodeFences(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            trimmed = trimmed
                .replacingOccurrences(of: "```text", with: "")
                .replacingOccurrences(of: "```", with: "")
        }
        return trimmed
    }

    private static func looksLikeTranscript(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return false }
        let labeled = lines.filter { line in
            guard let colon = line.firstIndex(of: ":") else { return false }
            return line.distance(from: line.startIndex, to: colon) <= 40
        }
        return labeled.count * 3 >= lines.count * 2 // at least ~2/3 of lines are "Label: text"
    }

    private static let systemPrompt = """
    You are Clyde's transcript editor. You receive a chunk of a raw, live speech-to-text \
    transcript of a meeting that just ended, one line per utterance in the form "Label: text". \
    "You:" is the user themselves (captured from their own microphone — this attribution is \
    reliable; NEVER change it). All other labels ("Them:", "Speaker 1:", "Speaker 2:", …) are \
    other meeting participants captured from one shared audio stream, and those labels are \
    UNRELIABLE — the same person may appear under different labels and different people under \
    the same label.

    Rewrite the chunk with two goals:

    1. RE-ATTRIBUTE the non-"You" lines to distinct, consistent speakers using conversational \
    context: who asks vs. answers, who is addressed by name, topic ownership, and self-references. \
    Use a real name as the label when the conversation makes it clear (e.g. someone is addressed \
    by name and responds), otherwise "Speaker 1", "Speaker 2", … in order of first appearance. \
    Keep every label consistent within your output — and when an already-cleaned earlier portion \
    is provided, continue its exact labels for the same voices. If the chunk genuinely seems to \
    have only one other participant, one label is fine. When truly unsure which existing speaker \
    said a line, keep it with the previous speaker rather than inventing a new one.

    2. CLEAN the text: remove meaningless filler ("um", "uh", "like", "you know", "sort of" when \
    contentless), stutters and false starts; delete noise-only or hopelessly garbled fragments \
    that carry no meaning; fix obvious speech-to-text errors using context (e.g. "ad filter" → \
    "add filter", homophones, broken grammar mid-sentence); and merge consecutive fragmented \
    lines from the same speaker into coherent turns. NEVER summarize, paraphrase away, or drop \
    substance: every fact, number, name, decision, commitment, question, and answer must survive. \
    Keep the speakers' own wording and tone wherever it's already clear.

    Output ONLY the cleaned transcript lines, one per turn, in the form "Label: text" — no \
    commentary, no headers, no code fences.
    """
}

private enum RefinerError: Error, LocalizedError {
    case malformedOutput(String)
    var errorDescription: String? {
        switch self {
        case .malformedOutput(let prefix): return "Refiner returned non-transcript output: \(prefix)…"
        }
    }
}
