import Foundation

/// Whether the text is going into code: an editor, a terminal or a coding
/// agent. Project names and identifier commands apply only there; in a mail
/// or a chat, "user service" stays two words.
enum CodeContext {

    /// Bundle identifiers of apps where developers write code or talk to
    /// coding agents. `code_apps` in the config adds more.
    static let knownApps: Set<String> = [
        // terminals
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty",
        "com.github.wez.wezterm", "co.zeit.hyper",
        // editors and IDEs
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "dev.zed.Zed-Preview",
        "com.exafunction.windsurf", "com.sublimetext.4", "com.panic.Nova", "com.vscodium",
        "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm", "com.jetbrains.goland", "com.jetbrains.rustrover",
        "com.jetbrains.CLion", "com.google.android.studio",
        // coding agents
        "com.anthropic.claudefordesktop", "com.openai.codex",
    ]

    static func isCode(bundleID: String?, extra: [String] = []) -> Bool {
        guard let bundleID else { return false }
        if knownApps.contains(bundleID) || extra.contains(bundleID) { return true }
        // every JetBrains IDE
        return bundleID.hasPrefix("com.jetbrains.")
    }
}
