import CWhisper
import Foundation

/// Thin wrapper over the whisper.cpp C API. Not thread-safe; call from one queue.
final class WhisperTranscriber {
    private let ctx: OpaquePointer
    private let language = strdup("en") // must outlive every whisper_full call
    /// Vocabulary hint (whisper "initial prompt") biasing decoding towards
    /// domain terms — fixes proper nouns like "Claude", "Jira", "Twitter feed".
    /// Mutated only on the transcription queue.
    private var vocabularyPrompt: UnsafeMutablePointer<CChar>?

    /// Replace the vocabulary at runtime. Call on the transcription queue.
    func setVocabulary(_ vocab: String) {
        free(vocabularyPrompt)
        vocabularyPrompt = vocab.isEmpty
            ? nil
            : strdup("Conversation about software development, mentioning: \(vocab).")
    }

    /// Loads (creating with defaults if absent) the user-editable vocabulary file.
    static func loadVocabulary() -> String {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Advisor", isDirectory: true)
        let file = dir.appendingPathComponent("vocabulary.txt")
        if let existing = try? String(contentsOf: file, encoding: .utf8) {
            return existing.split(whereSeparator: \.isNewline).joined(separator: ", ")
        }
        let defaults = """
            Claude
            Anthropic
            Jira
            Obsidian
            Vault
            Twitter feed
            whisper
            MCP
            """
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? defaults.write(to: file, atomically: true, encoding: .utf8)
        return defaults.split(whereSeparator: \.isNewline).joined(separator: ", ")
    }

    init(modelPath: String) throws {
        let vocab = Self.loadVocabulary()
        vocabularyPrompt = vocab.isEmpty
            ? nil
            : strdup("Conversation about software development, mentioning: \(vocab).")
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw AdvisorError.whisper("model not found at \(modelPath)")
        }
        let cparams = whisper_context_default_params()
        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw AdvisorError.whisper("failed to load model at \(modelPath)")
        }
        self.ctx = ctx
    }

    deinit {
        whisper_free(ctx)
        free(language)
        free(vocabularyPrompt)
    }

    /// Transcribe 16 kHz mono samples. Returns trimmed text ("" for non-speech).
    func transcribe(_ samples: [Float]) -> String {
        // Beam search (whisper-cli's default) — markedly better than greedy on
        // fast/overlapping speech; turbo on the M4 Max has the headroom.
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        // beam 2: most of the quality gain over greedy at a fraction of the
        // cost — beam 5 couldn't keep up with two continuous streams.
        params.beam_search.beam_size = 2
        // No multi-temperature retries: on noisy crosstalk the default fallback
        // re-decodes a segment up to 5×, which is what froze the pipeline.
        params.temperature_inc = 0
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.no_timestamps = true
        params.suppress_blank = true
        params.language = UnsafePointer(language)
        params.initial_prompt = UnsafePointer(vocabularyPrompt)
        params.n_threads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))

        let rc = samples.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard rc == 0 else { return "" }

        var text = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            if let seg = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: seg)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
