import Foundation

/// User settings at `~/.config/yaz/config.json`.
///
/// parrot's architecture document describes a `config.toml` with `model`,
/// `hotkey` and `inject_mode` keys. No such file is ever read — there is no
/// `Config` type in the source at all. Everything is CLI flags, so a daemon
/// started by a LaunchAgent can only be reconfigured by editing the plist.
///
/// A malformed config is reported on stderr and then ignored. Silently falling
/// back to defaults would leave the user wondering why their hotkey did not
/// change.
struct Config: Sendable, Equatable {

    var engine: EngineChoice = .whisper
    var whisperModel: WhisperModel = .largeV3Turbo
    var language: String = "tr"
    var hotkey: Hotkey = .fn
    var injectMode: TextInjector.Mode = .paste
    /// Keep model weights loaded between utterances. Costs ~1.6 GB resident;
    /// saves ~7 s on the first press after an idle period.
    var keepModelLoaded: Bool = true
    /// Shell command run with the transcript as its only argument.
    var onTranscript: String?
    /// Technical terms to spell correctly. See `Vocabulary`.
    var vocabulary: [VocabularyTerm] = []
    /// Post-processing applied to the finished transcript. Defaults to the
    /// deterministic filter: it costs nothing and cannot change meaning.
    var refine: RefineMode = .fillers
    /// The on-screen pill shown while dictating. Push-to-talk's one honest
    /// failure mode is not knowing the microphone was live.
    var overlay: Bool = true
    /// The menu bar item. Off makes sense for a foreground terminal run, where
    /// the log already says what is happening.
    var menuBar: Bool = true
    /// Keep a text-only log of what was dictated, and into which app. No audio
    /// is ever stored.
    var history: Bool = true
    /// How many entries to keep before the oldest are dropped.
    var historyLimit: Int = TranscriptHistory.defaultLimit
    /// Drop recordings that are loud enough but hold no speech (a fan, a
    /// keyboard, a cough), using Silero VAD. See `VoiceActivityGate`.
    var vad: Bool = true
    /// Window speech probability that counts as speech.
    var vadThreshold: Float = VoiceActivityGate.defaultThreshold

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/yaz/config.json")

    /// Load from disk, falling back to defaults for anything absent.
    static func load(from url: URL = Config.path) -> Config {
        var config = Config()
        guard FileManager.default.fileExists(atPath: url.path) else { return config }

        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            log("warning: \(url.path) is not valid JSON — ignoring it")
            return config
        }

        config.apply(json, source: url.path)
        return config
    }

    /// Apply a parsed JSON object, warning about keys that are present but
    /// unusable. An unknown *value* is a typo worth reporting; an unknown
    /// *key* usually means a newer config against an older binary.
    mutating func apply(_ json: [String: Any], source: String) {
        func warn(_ key: String, _ value: Any, _ valid: [String]) {
            log("warning: \(source): \(key) = \"\(value)\" is not recognised"
                + " (valid: \(valid.joined(separator: ", ")))")
        }

        if let raw = json["engine"] as? String {
            if let value = EngineChoice(rawValue: raw) { engine = value }
            else { warn("engine", raw, EngineChoice.allCases.map(\.rawValue)) }
        }
        if let raw = json["whisper_model"] as? String {
            if let value = WhisperModel(rawValue: raw) { whisperModel = value }
            else { warn("whisper_model", raw, WhisperModel.allCases.map(\.rawValue)) }
        }
        if let raw = json["language"] as? String, !raw.isEmpty {
            language = raw
        }
        if let raw = json["hotkey"] as? String {
            if let value = Hotkey(rawValue: raw) { hotkey = value }
            else { warn("hotkey", raw, Hotkey.allCases.map(\.rawValue)) }
        }
        if let raw = json["inject_mode"] as? String {
            if let value = TextInjector.Mode(rawValue: raw) { injectMode = value }
            else { warn("inject_mode", raw, TextInjector.Mode.allCases.map(\.rawValue)) }
        }
        if let value = json["keep_model_loaded"] as? Bool {
            keepModelLoaded = value
        }
        if let raw = json["on_transcript"] as? String, !raw.isEmpty {
            onTranscript = raw
        }
        if let raw = json["refine"] as? String {
            if let value = RefineMode(rawValue: raw) { refine = value }
            else { warn("refine", raw, RefineMode.allCases.map(\.rawValue)) }
        }
        if let value = json["history"] as? Bool { history = value }
        if let value = json["history_limit"] as? Int, value > 0 { historyLimit = value }
        if let value = json["overlay"] as? Bool { overlay = value }
        if let value = json["menu_bar"] as? Bool { menuBar = value }
        if let value = json["vad"] as? Bool { vad = value }
        if let raw = json["vad_threshold"] {
            if let value = (raw as? NSNumber)?.doubleValue, value > 0, value < 1 {
                vadThreshold = Float(value)
            } else {
                log("warning: \(source): vad_threshold = \(raw) is not recognised"
                    + " (valid: a number between 0 and 1)")
            }
        }
        if let raw = json["vocabulary"] {
            vocabulary = Self.parseVocabulary(raw, source: source)
        }
    }

    /// Accepts either a plain list of strings or objects with aliases and a
    /// per-term threshold, so the common case stays a one-liner:
    ///
    /// ```json
    /// "vocabulary": ["Slack", "pull request", {"term": "CI", "aliases": ["si ay"]}]
    /// ```
    static func parseVocabulary(_ raw: Any, source: String) -> [VocabularyTerm] {
        guard let items = raw as? [Any] else {
            log("warning: \(source): vocabulary is not a list — ignoring it")
            return []
        }
        var terms: [VocabularyTerm] = []
        for item in items {
            if let text = item as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                terms.append(VocabularyTerm(canonical: trimmed))
            } else if let object = item as? [String: Any],
                      let canonical = object["term"] as? String,
                      !canonical.isEmpty {
                terms.append(VocabularyTerm(
                    canonical: canonical,
                    aliases: (object["aliases"] as? [String]) ?? [],
                    minSimilarity: object["min_similarity"] as? Double))
            } else {
                log("warning: \(source): unrecognised vocabulary entry — skipped")
            }
        }
        return terms
    }

    /// The voice check this config asks for, or `nil` when it is off.
    var voiceCheck: VoiceCheck? {
        guard vad else { return nil }
        return VoiceCheck(
            detector: SileroVoiceActivity.shared,
            gate: VoiceActivityGate(threshold: vadThreshold))
    }

    /// Build the engine this config selects.
    func makeEngine() -> any Transcriber {
        switch engine {
        case .whisper: WhisperTranscriber(model: whisperModel, language: language)
        case .parakeet: ParakeetTranscriber(version: .v3)
        }
    }

    /// Serialise back to the on-disk shape.
    ///
    /// Round-trips through the same key names `apply` reads, so a file written
    /// by the settings window is one a person can still edit by hand — the
    /// config file is the source of truth, and the UI is one way to edit it.
    func asJSON() -> [String: Any] {
        var json: [String: Any] = [
            "engine": engine.rawValue,
            "whisper_model": whisperModel.rawValue,
            "language": language,
            "hotkey": hotkey.rawValue,
            "inject_mode": injectMode.rawValue,
            "keep_model_loaded": keepModelLoaded,
            "refine": refine.rawValue,
            "overlay": overlay,
            "menu_bar": menuBar,
            "history": history,
            "history_limit": historyLimit,
            "vad": vad,
            "vad_threshold": Double(vadThreshold),
        ]
        if let onTranscript { json["on_transcript"] = onTranscript }
        if !vocabulary.isEmpty {
            json["vocabulary"] = vocabulary.map { term -> Any in
                // Keep the simple case simple: a plain string unless the term
                // actually carries aliases or an override.
                if term.aliases.isEmpty && term.minSimilarity == nil {
                    return term.canonical
                }
                var object: [String: Any] = ["term": term.canonical]
                if !term.aliases.isEmpty { object["aliases"] = term.aliases }
                if let minSimilarity = term.minSimilarity {
                    object["min_similarity"] = minSimilarity
                }
                return object
            }
        }
        return json
    }

    /// Write to disk, creating the directory if needed.
    func save(to url: URL = Config.path) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: asJSON(), options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// A commented example, written by `yaz config --init`.
    static let example = """
        {
          "engine": "whisper",
          "whisper_model": "large-v3-turbo",
          "language": "tr",
          "hotkey": "fn",
          "inject_mode": "paste",
          "keep_model_loaded": true,
          "refine": "fillers",
          "overlay": true,
          "menu_bar": true,
          "history": true,
          "history_limit": 2000,
          "vad": true,
          "vad_threshold": 0.3
        }

        """
}
