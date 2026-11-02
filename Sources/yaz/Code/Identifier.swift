import Foundation

/// Identifiers as a developer says them and as code spells them.
///
/// `getUserById` is spoken "get user by id"; `user_service` is "user
/// service". This type goes both ways: it splits an identifier into the words
/// a person says, and joins words back in a casing style.
enum Identifier {

    enum Style: String, CaseIterable, Sendable {
        case camel, pascal, snake, kebab, screaming

        /// What a developer says to ask for it.
        var spokenTrigger: String {
            switch self {
            case .camel: "camel case"
            case .pascal: "pascal case"
            case .snake: "snake case"
            case .kebab: "kebab case"
            case .screaming: "constant case"
            }
        }
    }

    /// The words of an identifier, lowercased: `getUserByID` → get, user,
    /// by, id; `HTTPServer` → http, server; `user_id` → user, id.
    static func words(_ identifier: String) -> [String] {
        var words: [String] = []
        var current = ""
        let chars = Array(identifier)
        for (i, ch) in chars.enumerated() {
            if ch == "_" || ch == "-" || ch == "." || ch == " " || ch == "/" {
                if !current.isEmpty { words.append(current); current = "" }
                continue
            }
            if ch.isUppercase, !current.isEmpty {
                let prev = chars[i - 1]
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                // fooBar | HTTPServer (split before S) | ID at the end stays whole
                if prev.isLowercase || prev.isNumber
                    || (prev.isUppercase && (next?.isLowercase ?? false)) {
                    words.append(current)
                    current = ""
                }
            }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }

    /// How a person says it: `getUserById` → "get user by id".
    static func spoken(_ identifier: String) -> String {
        words(identifier).joined(separator: " ")
    }

    /// True for identifiers of two or more words. A single word —
    /// `user`, `Session` — is an ordinary word, and putting it in the
    /// vocabulary would rewrite everyday speech.
    static func isCompound(_ identifier: String) -> Bool {
        words(identifier).count >= 2
    }

    /// Join words in a style: [user, name] → userName, UserName, user_name…
    static func join(_ words: [String], style: Style) -> String {
        let lower = words.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard let first = lower.first else { return "" }
        let capitalized = lower.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        switch style {
        case .camel: return first + capitalized.dropFirst().joined()
        case .pascal: return capitalized.joined()
        case .snake: return lower.joined(separator: "_")
        case .kebab: return lower.joined(separator: "-")
        case .screaming: return lower.joined(separator: "_").uppercased()
        }
    }
}
