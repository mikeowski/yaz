import Foundation

/// How text is finished for one app.
enum TextStyle: String, CaseIterable, Sendable {
    /// As written: sentences end with their full stop.
    case standard
    /// A chat message: a single sentence loses its final full stop, the way
    /// people write in Slack or Messages. Questions and exclamations keep
    /// theirs.
    case chat

    func apply(_ text: String) -> String {
        guard self == .chat else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("."), !trimmed.hasSuffix(".."), !trimmed.contains("\n") else { return text }
        // One sentence only: no full stop, question or exclamation mark
        // followed by a space before the end ("15.30." is still one).
        let body = trimmed.dropLast()
        let chars = Array(body)
        for (i, c) in chars.enumerated() where ".!?…".contains(c) {
            if i + 1 < chars.count, chars[i + 1].isWhitespace { return text }
        }
        return String(body)
    }
}

/// Settings that differ in one app: `"apps": { "com.tinyspeck.slackmacgap":
/// { "style": "chat", "refine": "off" } }` in the config file. Every field is
/// optional; what is absent comes from the main settings.
struct AppProfile: Sendable, Equatable {
    var language: String?
    var refine: RefineMode?
    var numbers: Bool?
    var voiceCommands: Bool?
    var screenContext: Bool?
    /// Force code mode on or off, whatever `CodeContext` says.
    var code: Bool?
    var style: TextStyle?

    static let keys = ["language", "refine", "numbers", "voice_commands", "screen_context", "code", "style"]

    init(
        language: String? = nil, refine: RefineMode? = nil, numbers: Bool? = nil,
        voiceCommands: Bool? = nil, screenContext: Bool? = nil, code: Bool? = nil,
        style: TextStyle? = nil
    ) {
        self.language = language
        self.refine = refine
        self.numbers = numbers
        self.voiceCommands = voiceCommands
        self.screenContext = screenContext
        self.code = code
        self.style = style
    }

    /// Read from the config file. An unknown value is reported through
    /// `warn` (key, value, valid values) and ignored.
    init(json: [String: Any], warn: (String, Any, [String]) -> Void) {
        if let raw = json["language"] as? String, !raw.isEmpty { language = raw }
        if let raw = json["refine"] as? String {
            if let value = RefineMode(rawValue: raw) { refine = value }
            else { warn("refine", raw, RefineMode.allCases.map(\.rawValue)) }
        }
        if let value = json["numbers"] as? Bool { numbers = value }
        if let value = json["voice_commands"] as? Bool { voiceCommands = value }
        if let value = json["screen_context"] as? Bool { screenContext = value }
        if let value = json["code"] as? Bool { code = value }
        if let raw = json["style"] as? String {
            if let value = TextStyle(rawValue: raw) { style = value }
            else { warn("style", raw, TextStyle.allCases.map(\.rawValue)) }
        }
        for key in json.keys where !Self.keys.contains(key) {
            warn(key, "…", Self.keys)
        }
    }

    var json: [String: Any] {
        var out: [String: Any] = [:]
        if let language { out["language"] = language }
        if let refine { out["refine"] = refine.rawValue }
        if let numbers { out["numbers"] = numbers }
        if let voiceCommands { out["voice_commands"] = voiceCommands }
        if let screenContext { out["screen_context"] = screenContext }
        if let code { out["code"] = code }
        if let style { out["style"] = style.rawValue }
        return out
    }

    var isEmpty: Bool { json.isEmpty }
}

extension Config {

    /// The settings for dictating into `bundleID`: the main ones with that
    /// app's profile on top.
    func forApp(_ bundleID: String?) -> Config {
        guard let bundleID, let profile = apps[bundleID] else { return self }
        var config = self
        if let value = profile.language { config.language = value }
        if let value = profile.refine { config.refine = value }
        if let value = profile.numbers { config.numbers = value }
        if let value = profile.voiceCommands { config.voiceCommands = value }
        if let value = profile.screenContext { config.screenContext = value }
        if let value = profile.style { config.style = value }
        config.codeOverride = profile.code
        return config
    }
}
