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
            log("uyarı: \(url.path) geçerli JSON değil — yok sayılıyor")
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
            log("uyarı: \(source) içinde \(key) = \"\(value)\" tanınmadı"
                + " (geçerli: \(valid.joined(separator: ", ")))")
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
    }

    /// Build the engine this config selects.
    func makeEngine() -> any Transcriber {
        switch engine {
        case .whisper: WhisperTranscriber(model: whisperModel, language: language)
        case .parakeet: ParakeetTranscriber(version: .v3)
        }
    }

    /// A commented example, written by `yaz config --init`.
    static let example = """
        {
          "engine": "whisper",
          "whisper_model": "large-v3-turbo",
          "language": "tr",
          "hotkey": "fn",
          "inject_mode": "paste",
          "keep_model_loaded": true
        }

        """
}
