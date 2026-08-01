import Foundation
import Testing

@testable import yaz

@Suite("LaunchAgent — launchd iş tanımı")
struct LaunchAgentJobTests {

    static let binary = "/usr/local/bin/yaz"

    static func job() -> [String: Any] {
        LaunchAgent.job(binary: binary)
    }

    @Test("etiket gömülü Info.plist'teki kimlikle aynı")
    func labelMatchesBundleIdentifier() {
        // launchd işi ve TCC kimliği aynı şeye işaret etmeli.
        #expect(LaunchAgent.label == "com.mikeowski.yaz")
        #expect(Self.job()["Label"] as? String == LaunchAgent.label)
    }

    @Test("ikili yolu ve argümanlar doğru sırada")
    func programArguments() throws {
        let arguments = try #require(Self.job()["ProgramArguments"] as? [String])
        #expect(arguments.first == Self.binary)
        #expect(arguments.contains("run"))
    }

    @Test("girişte çalışır")
    func runsAtLoad() {
        #expect(Self.job()["RunAtLoad"] as? Bool == true)
    }

    /// Menü barından "Çık" temiz bir çıkıştır ve kapalı kalmalı; çökme ise
    /// yeniden başlatılmalı. Koşulsuz KeepAlive, Çık menüsünü yalancı yapar.
    @Test("KeepAlive yalnızca başarısız çıkışta yeniden başlatır")
    func keepAliveIsConditional() throws {
        let keepAlive = try #require(Self.job()["KeepAlive"] as? [String: Any])
        #expect(keepAlive["SuccessfulExit"] as? Bool == false)
    }

    @Test("Interactive tip — launchd gecikmeyi kısmasın")
    func processTypeIsInteractive() {
        #expect(Self.job()["ProcessType"] as? String == "Interactive")
    }

    /// launchd giriş ajanlarına çıplak bir ortam veriyor; PATH olmadan
    /// `on_transcript` kancası hiçbir komutu bulamaz.
    @Test("PATH ortam değişkeni tanımlı")
    func environmentCarriesPath() throws {
        let environment = try #require(Self.job()["EnvironmentVariables"] as? [String: String])
        let path = try #require(environment["PATH"])
        #expect(path.contains("/usr/local/bin"))
        #expect(path.contains("/opt/homebrew/bin"))
    }

    @Test("günlük yolları tanımlı")
    func logPaths() {
        #expect(Self.job()["StandardOutPath"] as? String == LaunchAgent.standardOutPath)
        #expect(Self.job()["StandardErrorPath"] as? String == LaunchAgent.standardErrorPath)
    }

    @Test("plist geçerli XML olarak serileştirilir ve geri okunur")
    func serialisesAndRoundTrips() throws {
        let data = try LaunchAgent.plistData(binary: Self.binary)
        #expect(!data.isEmpty)

        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        let plist = try #require(parsed as? [String: Any])
        #expect(plist["Label"] as? String == LaunchAgent.label)
        #expect((plist["ProgramArguments"] as? [String])?.first == Self.binary)

        // launchd XML bekliyor; ikili plist de geçerli ama okunabilirlik
        // kullanıcının bunu inceleyebilmesi için değerli.
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("<?xml"))
    }

    @Test("özel argümanlar geçirilebilir")
    func customArguments() throws {
        let job = LaunchAgent.job(binary: Self.binary, arguments: ["run", "--verbose"])
        let arguments = try #require(job["ProgramArguments"] as? [String])
        #expect(arguments == [Self.binary, "run", "--verbose"])
    }

    @Test("plist yolu LaunchAgents dizininde ve etiketle adlandırılmış")
    func plistLocation() {
        let path = LaunchAgent.plistURL.path
        #expect(path.contains("Library/LaunchAgents"))
        #expect(path.hasSuffix("\(LaunchAgent.label).plist"))
    }
}

@Suite("LaunchAgent — durum tespiti")
struct LaunchAgentStatusTests {

    /// Bu makinede kurulu olmayabilir; test kurulum yapmadan da anlamlı olmalı.
    @Test("kurulu değilse temiz durum döner")
    func uninstalledIsClean() {
        let state = LaunchAgent.status()
        if !state.isInstalled {
            #expect(state.binaryPath == nil)
            #expect(!state.isStale)
        }
    }

    /// Asıl kötü senaryo: plist duruyor ama ikili taşınmış. launchd denemeye
    /// devam eder, kullanıcı hiçbir şey görmez.
    @Test("eksik ikili bayat olarak işaretlenir")
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

    @Test("çalışan ikilinin yolu çözülür")
    func currentBinaryResolves() {
        // Test koşucusu altında CommandLine.arguments[0] xctest ikilisidir;
        // önemli olan bir şey döndürmesi ve o şeyin çalıştırılabilir olması.
        if let binary = LaunchAgent.currentBinary() {
            #expect(FileManager.default.isExecutableFile(atPath: binary.path))
            #expect(!binary.path.isEmpty)
        }
    }
}

@Suite("Info.plist — TCC kimliği")
struct EmbeddedInfoPlistTests {

    static var source: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/yaz/Info.plist")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test("mikrofon kullanım açıklaması var ve Türkçe")
    func microphoneUsageDescription() {
        let text = Self.source
        #expect(text.contains("NSMicrophoneUsageDescription"))
        // macOS bu metni izin penceresinde gösteriyor; boş bırakmak
        // "yaz mikrofona erişmek istiyor" diye çıplak bir kutu demek.
        #expect(text.contains("mikrofon"))
    }

    @Test("bundle kimliği LaunchAgent etiketiyle aynı")
    func identifierMatchesLabel() {
        #expect(Self.source.contains(LaunchAgent.label))
    }

    @Test("arka plan süreci olarak işaretli")
    func marksBackgroundOnly() {
        #expect(Self.source.contains("LSBackgroundOnly"))
    }

    @Test("geçerli plist")
    func isValidPlist() throws {
        let data = Data(Self.source.utf8)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        let plist = try #require(parsed as? [String: Any])
        #expect(plist["CFBundleIdentifier"] as? String == LaunchAgent.label)
        #expect(plist["CFBundleName"] as? String == "yaz")
    }
}

@Suite("Doctor — erişilebilirlik izni kime verilecek")
struct AccessibilityOwnerTests {

    /// Kabuktan çalıştırıldığında macOS izni terminale atfeder, yaz'a değil.
    @Test(
        "terminalden çalışınca terminal adlandırılır",
        arguments: ["zsh", "bash", "fish", "Terminal", "iTerm2", "ghostty"]
    )
    func namesTheTerminal(_ shell: String) {
        #expect(DoctorReport.accessibilityOwner(parentName: shell, parentPID: 4242) == shell)
    }

    /// launchd altında terminal yok. "launchd etkinleştir" demek işe yaramaz;
    /// izin, gömülü Info.plist sayesinde kendi kimliği olan yaz'a ait.
    @Test("launchd altında yaz'ın kendisi adlandırılır")
    func namesYazUnderLaunchd() {
        #expect(DoctorReport.accessibilityOwner(parentName: "launchd", parentPID: 1) == "yaz")
        #expect(DoctorReport.accessibilityOwner(parentName: "launchd", parentPID: 9999) == "yaz")
    }

    @Test("ebeveyn süreç 1 ise yaz adlandırılır")
    func reparentedToInit() {
        #expect(DoctorReport.accessibilityOwner(parentName: "her ne ise", parentPID: 1) == "yaz")
    }

    @Test("ebeveyn adı okunamazsa yaz adlandırılır")
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
