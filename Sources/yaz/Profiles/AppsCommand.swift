import AppKit
import ArgumentParser
import Foundation

struct Apps: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the per-app settings, or the bundle ids of running apps to add one.",
        discussion: """
            Profiles live under "apps" in ~/.config/yaz/config.json, by bundle id: \\
            { "apps": { "com.tinyspeck.slackmacgap": { "style": "chat" } } }. \\
            Keys: language, refine, numbers, voice_commands, screen_context, code, style.
            """)

    @Flag(help: "List running apps with their bundle ids.")
    var running = false

    @Option(help: "Show how this text comes out in the app with this bundle id.")
    var app: String?

    @Argument(help: "Text to try with --app.")
    var text: String?

    func run() throws {
        let config = Config.load()
        if running {
            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app -> (String, String)? in
                    guard let id = app.bundleIdentifier else { return nil }
                    return (app.localizedName ?? id, id)
                }
                .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
            for (name, id) in apps {
                let mark = config.apps[id] == nil ? "" : "  (has a profile)"
                print("\(name)  \(id)\(mark)")
            }
            return
        }
        if let app {
            let appConfig = config.forApp(app)
            print("settings in \(app): language \(appConfig.language), refine \(appConfig.refine.rawValue),"
                + " style \(appConfig.style.rawValue), numbers \(appConfig.numbers),"
                + " voice commands \(appConfig.voiceCommands), code \(appConfig.codeOverride.map(String.init) ?? "auto")")
            if let text {
                let code = appConfig.codeOverride ?? CodeContext.isCode(bundleID: app, extra: config.codeApps)
                let output = try runBlocking {
                    await TranscriptPipeline(config: appConfig).process(text, code: code)
                }
                print(output.text)
            }
            return
        }
        guard !config.apps.isEmpty else {
            print("no per-app settings. Add them under \"apps\" in \(Config.path.path);"
                + " yaz apps --running lists bundle ids")
            return
        }
        for (id, profile) in config.apps.sorted(by: { $0.key < $1.key }) {
            let settings = profile.json.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
            print("\(id): \(settings.joined(separator: ", "))")
        }
    }
}
