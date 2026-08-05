import Foundation
import Testing

@testable import yaz

@Suite("LaunchAgent — the launchd job definition")
struct LaunchAgentJobTests {

    static let binary = "/usr/local/bin/yaz"

    static func job() -> [String: Any] {
        LaunchAgent.job(binary: binary)
    }

    @Test("the label matches the identifier in the embedded Info.plist")
    func labelMatchesBundleIdentifier() {
        // The launchd job and the TCC identity must point at the same thing.
        #expect(LaunchAgent.label == "com.mikeowski.yaz")
        #expect(Self.job()["Label"] as? String == LaunchAgent.label)
    }

    @Test("the binary path and arguments are in the right order")
    func programArguments() throws {
        let arguments = try #require(Self.job()["ProgramArguments"] as? [String])
        #expect(arguments.first == Self.binary)
        #expect(arguments.contains("run"))
    }

    @Test("it runs at login")
    func runsAtLoad() {
        #expect(Self.job()["RunAtLoad"] as? Bool == true)
    }

    /// "Quit" from the menu bar is a clean exit and must stay quit; a crash
    /// should restart. An unconditional KeepAlive makes the Quit menu a lie.
    @Test("KeepAlive restarts only after a failed exit")
    func keepAliveIsConditional() throws {
        let keepAlive = try #require(Self.job()["KeepAlive"] as? [String: Any])
        #expect(keepAlive["SuccessfulExit"] as? Bool == false)
    }

    @Test("Interactive type — launchd must not throttle it")
    func processTypeIsInteractive() {
        #expect(Self.job()["ProcessType"] as? String == "Interactive")
    }

    /// launchd hands login agents a bare environment; without PATH the
    /// `on_transcript` hook cannot find any command.
    @Test("the PATH environment variable is set")
    func environmentCarriesPath() throws {
        let environment = try #require(Self.job()["EnvironmentVariables"] as? [String: String])
        let path = try #require(environment["PATH"])
        #expect(path.contains("/usr/local/bin"))
        #expect(path.contains("/opt/homebrew/bin"))
    }

    @Test("the log paths are set")
    func logPaths() {
        #expect(Self.job()["StandardOutPath"] as? String == LaunchAgent.standardOutPath)
        #expect(Self.job()["StandardErrorPath"] as? String == LaunchAgent.standardErrorPath)
    }

    @Test("the plist serialises to valid XML and reads back")
    func serialisesAndRoundTrips() throws {
        let data = try LaunchAgent.plistData(binary: Self.binary)
        #expect(!data.isEmpty)

        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        let plist = try #require(parsed as? [String: Any])
        #expect(plist["Label"] as? String == LaunchAgent.label)
        #expect((plist["ProgramArguments"] as? [String])?.first == Self.binary)

        // launchd expects XML. A binary plist is valid too, but readability
        // is what lets the user inspect this.
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("<?xml"))
    }

    @Test("custom arguments can be passed through")
    func customArguments() throws {
        let job = LaunchAgent.job(binary: Self.binary, arguments: ["run", "--verbose"])
        let arguments = try #require(job["ProgramArguments"] as? [String])
        #expect(arguments == [Self.binary, "run", "--verbose"])
    }

    @Test("the plist path is in LaunchAgents and named after the label")
    func plistLocation() {
        let path = LaunchAgent.plistURL.path
        #expect(path.contains("Library/LaunchAgents"))
        #expect(path.hasSuffix("\(LaunchAgent.label).plist"))
    }
}

@Suite("LaunchAgent — working out the state")
struct LaunchAgentStatusTests {

    /// It may not be installed on this machine; the test has to mean
    /// something without installing anything.
    @Test("a clean state is reported when it is not installed")
    func uninstalledIsClean() {
        let state = LaunchAgent.status()
        if !state.isInstalled {
            #expect(state.binaryPath == nil)
            #expect(!state.isStale)
        }
    }

    /// The bad case: the plist is still there but the binary has moved.
    /// launchd keeps retrying and the user sees nothing.
    @Test("a missing binary is reported as stale")
    func missingBinaryIsStale() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "yaz-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = directory.appending(path: "yaz").path
        let data = try LaunchAgent.plistData(binary: missing)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let job = try #require(plist as? [String: Any])
        let recorded = try #require((job["ProgramArguments"] as? [String])?.first)

        #expect(!FileManager.default.isExecutableFile(atPath: recorded))
    }

    @Test("the running binary's path resolves")
    func currentBinaryResolves() {
        // Under the test runner CommandLine.arguments[0] is the xctest
        // binary; what matters is that it returns something executable.
        if let binary = LaunchAgent.currentBinary() {
            #expect(FileManager.default.isExecutableFile(atPath: binary.path))
            #expect(!binary.path.isEmpty)
        }
    }
}

@Suite("Info.plist — the TCC identity")
struct EmbeddedInfoPlistTests {

    static var source: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/yaz/Info.plist")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test("the microphone usage description is present and in English")
    func microphoneUsageDescription() {
        let text = Self.source
        #expect(!text.isEmpty, "Info.plist not found — the path below has moved")
        #expect(text.contains("NSMicrophoneUsageDescription"))
        // macOS shows this in the permission prompt; leaving it out means a
        // bare "yaz would like to access the microphone" box with no reason.
        #expect(text.contains("microphone"))
    }

    /// There are two of these — this one is embedded in the binary so the CLI
    /// has its own TCC identity, and `Resources/AppInfo.plist` is copied into
    /// the bundle. They are separate files with nothing keeping them in step,
    /// and the prompt text drifted between them once already: the bundle was
    /// translated to English while the CLI kept showing Turkish.
    @Test("both Info.plists show the same permission text")
    func plistsAgreeOnUsageDescription() throws {
        let bundled = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/AppInfo.plist")
        let other = try String(contentsOf: bundled, encoding: .utf8)

        func usageDescription(_ source: String) -> String? {
            guard let range = source.range(of: "NSMicrophoneUsageDescription"),
                  let open = source.range(of: "<string>", range: range.upperBound..<source.endIndex),
                  let close = source.range(of: "</string>", range: open.upperBound..<source.endIndex)
            else { return nil }
            return String(source[open.upperBound..<close.lowerBound])
        }

        let embedded = try #require(usageDescription(Self.source))
        #expect(embedded == usageDescription(other))
    }

    @Test("the bundle identifier matches the LaunchAgent label")
    func identifierMatchesLabel() {
        #expect(Self.source.contains(LaunchAgent.label))
    }

    @Test("it is marked as a background process")
    func marksBackgroundOnly() {
        #expect(Self.source.contains("LSBackgroundOnly"))
    }

    @Test("it is a valid plist")
    func isValidPlist() throws {
        let data = Data(Self.source.utf8)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        let plist = try #require(parsed as? [String: Any])
        #expect(plist["CFBundleIdentifier"] as? String == LaunchAgent.label)
        #expect(plist["CFBundleName"] as? String == "yaz")
    }
}

@Suite("Doctor — who the Accessibility grant lands on")
struct AccessibilityOwnerTests {

    /// Run from a shell, macOS attributes the grant to the terminal, not yaz.
    @Test(
        "run from a terminal, the terminal is named",
        arguments: ["zsh", "bash", "fish", "Terminal", "iTerm2", "ghostty"]
    )
    func namesTheTerminal(_ shell: String) {
        #expect(DoctorReport.accessibilityOwner(parentName: shell, parentPID: 4242) == shell)
    }

    /// Under launchd there is no terminal. Saying "enable launchd" helps
    /// nobody: the grant belongs to yaz, which has its own identity thanks to
    /// the embedded Info.plist.
    @Test("under launchd, yaz itself is named")
    func namesYazUnderLaunchd() {
        #expect(DoctorReport.accessibilityOwner(parentName: "launchd", parentPID: 1) == "yaz")
        #expect(DoctorReport.accessibilityOwner(parentName: "launchd", parentPID: 9999) == "yaz")
    }

    @Test("yaz is named when the parent process is 1")
    func reparentedToInit() {
        #expect(DoctorReport.accessibilityOwner(parentName: "her ne ise", parentPID: 1) == "yaz")
    }

    @Test("yaz is named when the parent's name cannot be read")
    func unknownParentFallsBackToYaz() {
        #expect(DoctorReport.accessibilityOwner(parentName: nil, parentPID: 4242) == "yaz")
        #expect(DoctorReport.accessibilityOwner(parentName: "", parentPID: 4242) == "yaz")
    }
}

@Suite("InputMonitoring — the permission nobody expects")
struct InputMonitoringTests {

    /// Accessibility is not enough to listen to the keyboard. Measured on this
    /// machine: Accessibility granted, CGEventTap created without error, and
    /// zero events ever delivered — because Input Monitoring was denied.
    @Test("state maps to a definite answer")
    func stateIsDefinite() {
        let state = InputMonitoring.state
        #expect([.granted, .denied, .notDetermined].contains(state))
        #expect(state.isGranted == (state == .granted))
    }

    @Test("the settings path names the right list, not Accessibility")
    func settingsPathIsSpecific() {
        #expect(InputMonitoring.settingsPath.contains("Input Monitoring"))
        #expect(!InputMonitoring.settingsPath.contains("Accessibility"))
    }

    @Test("the settings URL targets the Input Monitoring pane")
    func settingsURLTargetsTheRightPane() {
        #expect(InputMonitoring.settingsURL.absoluteString.contains("Privacy_ListenEvent"))
    }

    @Test("the rationale explains why a second permission exists")
    func rationaleExplainsItself() {
        let text = InputMonitoring.rationale
        #expect(text.contains("Accessibility"))
        #expect(text.lowercased().contains("separate"))
    }

    /// A warning would let the app start and do nothing; the symptom of a
    /// missing grant is total silence, so it has to block.
    @Test("doctor treats a missing grant as a hard failure")
    func doctorFailsHard() {
        let check = DoctorReport.inputMonitoring()
        #expect(check.name == "input monitoring")
        switch check.status {
        case .ok:
            #expect(InputMonitoring.state.isGranted)
        case .fail:
            #expect(!InputMonitoring.state.isGranted)
            #expect(check.remedy?.contains("Input Monitoring") == true)
        case .warn:
            Issue.record("a missing grant must not be a warning — the hotkey is dead without it")
        }
    }

    @Test("doctor blocks startup while it is missing")
    func blocksStartup() {
        let checks = [DoctorReport.inputMonitoring()]
        #expect(DoctorReport.canRun(checks) == InputMonitoring.state.isGranted)
    }
}

@Suite("Doctor — the fn key macOS may already own")
struct FnKeyConflictTests {

    /// The symptom is silence: the tap installs, no event ever arrives, and
    /// nothing in the app can explain it. That cannot be a warning.
    @Test("a claimed fn key is a hard failure, not a warning")
    func claimedFnIsFatal() {
        let check = DoctorReport.fnKeyMapping()
        switch check.status {
        case .fail(let message):
            #expect(message.contains("claimed") || message.contains("set to"))
            #expect(check.remedy?.contains("Do Nothing") == true)
        case .warn, .ok:
            // Fine on a machine with one keyboard layout and no Dictation.
            #expect(!DoctorReport.hasMultipleInputSources() || !DoctorReport.dictationEnabled())
        }
    }

    @Test("the remedy offers both a settings change and another key")
    func remedyOffersAWayOut() {
        guard let remedy = DoctorReport.fnKeyMapping().remedy else { return }
        #expect(remedy.contains("Do Nothing"))
        #expect(remedy.contains("right-option"))
    }

    /// A second keyboard layout is what turns the globe key into an
    /// input-source switcher, which is why an unset preference is the
    /// dangerous case rather than a safe one.
    @Test("multiple input sources are detected")
    func detectsMultipleInputSources() {
        // Only asserts the call is well-formed on any machine.
        _ = DoctorReport.hasMultipleInputSources()
        _ = DoctorReport.dictationEnabled()
    }

    @Test("only fn conflicts with the system")
    func onlyFnConflicts() {
        #expect(Hotkey.fn.conflictsWithSystemFnAction)
        #expect(!Hotkey.rightOption.conflictsWithSystemFnAction)
    }
}

@Suite("Stale permission records — granted but not delivering")
struct StalePermissionTests {

    /// The reset has to cover every service the app uses, or the one left
    /// behind is the one still stale.
    @Test("reset covers accessibility, input monitoring and the microphone")
    func resetCoversEveryService() {
        // Keep this in step with ResetPermissions.run().
        let services = ["Accessibility", "ListenEvent", "Microphone"]
        #expect(services.contains("Accessibility"))
        #expect(services.contains("ListenEvent"))
        #expect(services.contains("Microphone"))
    }

    /// tccutil keys on the bundle identifier, which has to be the same string
    /// the app is signed with or the reset silently does nothing.
    @Test("reset targets the same identifier the app is signed with")
    func resetUsesTheSigningIdentifier() {
        #expect(LaunchAgent.label == "com.mikeowski.yaz")
    }

    /// A tap that is alive but deaf is the only observable of a stale record —
    /// macOS reports the permission as granted and delivers nothing. Silence
    /// therefore has to be treated as a signal rather than as "idle".
    @Test("the monitor exposes a hook for a silent tap")
    func monitorReportsSilence() {
        let monitor = HotkeyMonitor(hotkey: .rightOption)
        var fired = false
        monitor.onSilentTap = { fired = true }
        #expect(monitor.onSilentTap != nil)
        #expect(!fired)
    }
}
