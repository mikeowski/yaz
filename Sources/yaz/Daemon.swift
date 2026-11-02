import AppKit
import Foundation

/// The dictation loop: hold the hotkey, speak, release, text appears.
///
/// Runs as an `.accessory` process — no dock icon, no menu bar entry — driving
/// an AppKit run loop, which `CGEventTap` requires.
@MainActor
final class Daemon {

    private let config: Config
    private let engine: any Transcriber
    private var monitor: HotkeyMonitor
    private var activeHotkey: Hotkey
    private let capture = AudioCapture()
    /// Rebuilt once the project index is ready (`projects`).
    private var pipeline: TranscriptPipeline
    private let history: TranscriptHistory
    private let overlay: RecordingOverlay?
    /// Created in `run()`, not in `init`.
    ///
    /// `NSStatusBar.system` reaches into AppKit's application object. Building
    /// a status item before `NSApplication.shared` has been touched and the
    /// activation policy set produces an item that either never appears or
    /// appears and ignores clicks — which is exactly what happened.
    fileprivate var menuBar: MenuBarController?
    private let settings = SettingsWindowController()
    private let verbose: Bool

    /// Set while a transcription is running so a second press cannot start a
    /// recording that would land in the middle of the previous one's paste.
    private var busy = false

    /// False until the model is loaded. The event tap is installed before the
    /// load so permission failures surface immediately, which leaves a window
    /// where a key press has nothing to transcribe into.
    private var ready = false

    /// Poll that watches for the Accessibility grant arriving.
    private var permissionPoll: Timer?

    /// Hold to talk, or tap twice for hands-free. Owns when a recording
    /// starts and stops; `handle(_:)` only feeds it key edges.
    private var ptt: PushToTalk

    /// The last text pasted, for "Paste Last Dictation".
    private var lastText: String?

    /// Live preview while recording (`live_text`).
    private var liveTimer: Timer?
    private var liveInFlight = false

    /// The project names (`projects`) and what was learned from the user's
    /// fixes (`learn`): the pipeline is rebuilt from these when either changes.
    private var projectIndex = ProjectIndex.empty
    private var learned = LearnedRules.load()
    /// Terms read from the screen when the key went down, for this dictation.
    private var screenTerms: Task<[VocabularyTerm], Never>?
    /// Pipelines for apps with a profile (`AppProfile`), by bundle id.
    private var profilePipelines: [String: TranscriptPipeline] = [:]
    /// The user's own evaluation cases (`PersonalCorpus`).
    private var personal = PersonalCorpus.load()
    /// How long a dictation is watched for fixes at most.
    private static let watchLimit: TimeInterval = 60
    /// Edits are done once the field has not changed for this long.
    private static let settleAfter: TimeInterval = 6
    /// An untouched dictation is kept as right after this long.
    private static let keptAfter: TimeInterval = 20

    init(config: Config, verbose: Bool) {
        self.config = config
        self.engine = config.makeEngine()
        self.monitor = HotkeyMonitor(hotkey: config.hotkey, debug: verbose)
        self.activeHotkey = config.hotkey
        self.pipeline = TranscriptPipeline(config: config, learned: learned)
        self.history = TranscriptHistory(limit: config.historyLimit, enabled: config.history)
        self.overlay = config.overlay ? RecordingOverlay() : nil
        self.verbose = verbose
        self.ptt = PushToTalk(handsFree: config.handsFree)
        capture.preferredDeviceUID = config.microphone
    }

    func run() throws {
        // Order matters: everything that can fail cheaply fails before the
        // 1.6 GB model load. Loading first means a missing Accessibility grant
        // costs the user seven seconds before they are told about it.
        try engine.validateLanguage(config.language)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        if config.menuBar {
            menuBar = MenuBarController(summary: Self.summary(of: config))
        }

        menuBar?.onQuit = { [weak self] in self?.shutdown() }
        menuBar?.onOpenSettings = { [settings] in settings.showSettings() }
        menuBar?.onOpenHistory = { [settings] in settings.showHistory() }
        menuBar?.onFixPermission = { [weak self] in self?.presentPermissionAlert() }
        menuBar?.onUseFallbackHotkey = { [weak self] in self?.switchToFallbackHotkey() }
        menuBar?.onPasteLast = { [weak self] in self?.pasteLast() }
        menuBar?.onUndoLast = { [weak self] in self?.undoLast() }

        // Sparkle runs only in the signed .app; `Updates` decides.
        if Updates.canUpdate {
            let updates = Updates.shared
            menuBar?.onCheckForUpdates = { updates.checkForUpdates() }
            updates.onAvailable = { [weak self] version in
                self?.menuBar?.setUpdateAvailable(version)
            }
            log("updates: \(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "")")
        }

        // macOS owns the globe key whenever a second keyboard layout or
        // Dictation is enabled, and then it consumes the press before any
        // session tap sees it — the hotkey does nothing, silently.
        if config.hotkey == .fn, case .fail = DoctorReport.fnKeyMapping().status {
            log("warning: the fn key is claimed by macOS — the hotkey will not reach yaz")
            log("  fix: System Settings → Keyboard → \"Press 🌐 key to\" → Do Nothing")
            log("  or:  menu bar → use right option")
            menuBar?.setHotkeyConflict(true)
        }
        capture.onLevel = { [overlay] level in overlay?.pushLevel(level) }

        // Launched as an app, a missing Accessibility grant must not be fatal.
        // The user double-clicked an icon; exiting silently would look like the
        // app is broken. Instead prompt as *yaz* — which is the whole point of
        // shipping a bundle — and wait for the grant to arrive.
        // Two permissions, not one. Accessibility lets yaz post the paste;
        // Input Monitoring lets it *see* the hotkey. Missing the second one
        // produces a tap that installs cleanly and never fires — which is
        // indistinguishable from a broken app.
        var awaitingPermission = false
        let hasAccessibility = HotkeyMonitor.hasAccessibilityPermission
        let inputState = InputMonitoring.state
        // Logged every launch: when the hotkey does nothing, the first thing
        // anyone needs is the app's own view of its permissions, not the
        // terminal's.
        log("permissions · accessibility=\(hasAccessibility)"
            + " inputMonitoring=\(inputState) bundled=\(AppEnvironment.isBundledApp)"
            + " path=\(Bundle.main.bundlePath)")

        let hasPermissions = hasAccessibility && inputState.isGranted

        if !hasPermissions && AppEnvironment.isBundledApp {
            awaitingPermission = true
            menuBar?.setNeedsPermission(true)
            if !HotkeyMonitor.hasAccessibilityPermission {
                HotkeyMonitor.requestAccessibilityPermission()
            }
            if !InputMonitoring.state.isGranted {
                InputMonitoring.request()
            }
            waitForPermissions()
        } else {
            try startMonitor()
        }

        // Load the model *inside* the run loop, not before it.
        //
        // `app.run()` is what makes the menu bar respond and timers fire, so
        // anything awaited before it happens with the UI frozen. On a first
        // launch Core ML compilation takes minutes — the whole time the icon
        // would be present and dead, which is indistinguishable from a broken
        // app. Loading as a task means the menu works immediately and says
        // what it is doing.
        menuBar?.note("loading model…")
        startModelLoad()
        startProjectIndex()

        if awaitingPermission {
            DispatchQueue.main.async { [weak self] in self?.presentPermissionAlert() }
        }

        installSignalHandlers()
        log("listening · hold \(config.hotkey.displayName) · \(config.injectMode.displayName) · ^C to quit")
        app.run()
    }

    // MARK: -

    /// Prepare the engine off the main actor, then come back to report.
    ///
    /// `Task { }` inside a `@MainActor` type inherits the main actor, and the
    /// main actor is about to be occupied by `NSApplication.run()` for the life
    /// of the process. Such a task is enqueued and never gets a turn — the
    /// model silently never loaded and the daemon sat there "listening" with no
    /// engine behind it. `Task.detached` runs on the cooperative pool instead,
    /// and hops back here only to touch UI.
    private func startModelLoad() {
        let engine = self.engine
        let model = config.whisperModel
        let needsDownload = config.engine == .whisper
            && !ModelStore.status(for: model.whisperKitID).isComplete

        // The voice detector loads on its own. It is small, and until it is
        // ready the voice check passes everything, so it must not hold up
        // the speech model.
        if config.vad {
            Task.detached(priority: .utility) {
                await SileroVoiceActivity.shared.prepare()
                if await SileroVoiceActivity.shared.isReady {
                    log("✓ voice activity detector ready")
                }
            }
        }

        Task.detached(priority: .userInitiated) {
            // Fetch the weights first, with progress. Doing this inside
            // `prepare()` would work but say nothing: on a fresh machine the
            // menu would read "loading model…" for several minutes while 1.6 GB
            // moved silently, which reads as a hung app.
            if needsDownload {
                log(ModelDownloader.downloadNotice(for: model))
                await MainActor.run {
                    DaemonHolder.live?.menuBar?.note("downloading model…")
                }
                do {
                    try await ModelDownloader.ensure(model) { progress in
                        Task { @MainActor in
                            DaemonHolder.live?.menuBar?.note("downloading — \(progress.description)")
                        }
                    }
                    log("✓ model downloaded")
                } catch {
                    log("model download failed: \(error)")
                    await MainActor.run {
                        DaemonHolder.live?.menuBar?.note("model download failed")
                    }
                    return
                }
            }

            log("loading model…")
            let started = Date()
            do {
                try await engine.prepare()
            } catch {
                log("couldn't load the model: \(error)")
                await MainActor.run { DaemonHolder.live?.menuBar?.note("model failed to load") }
                return
            }
            let elapsed = Date().timeIntervalSince(started)
            log(String(format: "✓ %@ ready — %.1f s", engine.model, elapsed))
            await MainActor.run { DaemonHolder.live?.engineBecameReady() }
        }
    }

    /// Read the front window while the user speaks: the terms are ready by
    /// the time the key comes up.
    private func readScreenTerms() {
        screenTerms?.cancel()
        guard config.screenContext, Vocabulary.isSupported(language: config.language) else {
            screenTerms = nil
            return
        }
        if let front = AppEnvironment.frontmostApp()?.bundleID {
            FieldReader.enableAccessibility(bundleID: front)
        }
        let language = config.language
        let known = config.vocabulary + learned.terms
        screenTerms = Task.detached(priority: .userInitiated) {
            let text = ScreenReader.frontWindowText()
            let lexicon = Lexicon.forLanguage(language) ?? .turkish
            let candidates = ScreenContext.terms(in: text, lexicon: lexicon, excluding: known)
            return ScreenContext.vetted(candidates, language: language)
        }
    }

    /// Remove the last dictation from the focused field, through
    /// Accessibility, only if it still ends right at the cursor.
    private func undoLast() {
        guard let lastText else {
            menuBar?.note("nothing to remove")
            return
        }
        if FieldReader.deleteBeforeCaret(lastText) {
            log("↶ removed the last dictation")
            menuBar?.note("last dictation removed")
            self.lastText = nil
        } else {
            log("○ the last dictation is no longer right before the cursor, nothing removed")
            menuBar?.note("nothing removed: the text has changed")
        }
    }

    private func rebuildPipeline() {
        pipeline = TranscriptPipeline(config: config, project: projectIndex, learned: learned)
        profilePipelines = [:]
    }

    /// The settings and pipeline for dictating into `bundleID`: the main ones,
    /// or those of the app's profile.
    private func settings(for bundleID: String?) -> (config: Config, pipeline: TranscriptPipeline) {
        let appConfig = config.forApp(bundleID)
        guard let bundleID, appConfig != config else { return (config, pipeline) }
        if let cached = profilePipelines[bundleID] { return (appConfig, cached) }
        let made = TranscriptPipeline(config: appConfig, project: projectIndex, learned: learned)
        profilePipelines[bundleID] = made
        return (appConfig, made)
    }

    /// Read the field back a little after a paste and learn from what the
    /// user fixed. Nothing happens if they moved to another app: the focused
    /// field is then not the one yaz typed into.
    private func scheduleReadBack(
        pasted: String, corrections: [Vocabulary.Correction], in bundleID: String
    ) {
        FieldReader.enableAccessibility(bundleID: bundleID)
        Task { @MainActor [weak self] in
            // Watch the field while the user edits: one look later misses a
            // fix followed by Return. Stop when the dictation leaves the
            // field, the user leaves the app, edits settle, or a minute
            // passes; the last reading that held the dictation counts.
            var tracker = EditTracker(pasted: pasted)
            let started = Date()
            var lastChange = started
            var lastRegion: String?
            var readAnything = false
            try? await Task.sleep(for: .milliseconds(600))
            while Date().timeIntervalSince(started) < Self.watchLimit {
                guard AppEnvironment.frontmostApp()?.bundleID == bundleID else { break }
                let field = FieldReader.focusedText()
                if field != nil { readAnything = true }
                let status = tracker.observe(field)
                if status == .gone { break }
                if tracker.region != lastRegion {
                    lastRegion = tracker.region
                    lastChange = Date()
                }
                let quiet = Date().timeIntervalSince(lastChange)
                if status == .edited && quiet > Self.settleAfter { break }
                if status == .untouched && quiet > Self.keptAfter { break }
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, self.config.learn else { return }
            if !readAnything {
                log("○ learning: could not read the text field in \(bundleID) through Accessibility")
                return
            }
            // The personal set keeps sentences, so it follows the history
            // switch: no history, no stored text.
            let keepsCases = self.config.history

            // Left exactly as pasted: it was right, and must stay right.
            let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
            if tracker.wasKept {
                guard keepsCases else { return }
                var personal = self.personal
                personal.recordKept(trimmed)
                if personal != self.personal {
                    self.personal = personal
                    try? personal.save()
                }
                return
            }

            let edits = tracker.edits
            guard !edits.isEmpty else {
                if self.verbose { log("  learning: no word replaced") }
                return
            }

            // The gate scores the whole evaluation set: off the main thread.
            let learner = Learner(
                rules: self.learned, language: self.config.language,
                personal: keepsCases ? self.personal : PersonalCorpus())
            let userTerms = self.config.vocabulary
            let (rules, personal, events) = await Task.detached(priority: .utility) {
                var learner = learner
                let events = learner.observe(
                    edits: edits, corrections: corrections, userTerms: userTerms,
                    sentence: keepsCases ? trimmed : nil)
                return (learner.rules, learner.personal, events)
            }.value
            if keepsCases, personal != self.personal {
                self.personal = personal
                try? personal.save()
            }
            guard rules != self.learned else { return }
            self.learned = rules
            do {
                try self.learned.save()
            } catch {
                log("! could not save learned rules: \(error.localizedDescription)")
            }

            var changed = false
            for event in events {
                switch event {
                case let .noted(heard, meant, count):
                    log("• noted your fix: \(heard) -> \(meant) (\(count) of \(Learner.promoteAfter))")
                    self.menuBar?.note("noted: \(heard) → \(meant), once more to learn it")
                case let .learned(heard, meant):
                    log("✓ learned: \(heard) -> \(meant)")
                    self.menuBar?.note("learned: \(heard) → \(meant)")
                    changed = true
                case let .rejected(heard, meant, reason):
                    log("○ not learned: \(heard) -> \(meant), \(reason)")
                    self.menuBar?.note("not learned: \(heard) → \(meant)")
                case let .blocked(heard, term):
                    log("✓ will not turn \(heard) into \(term) again")
                    self.menuBar?.note("won't write \(term) for \(heard) again")
                    changed = true
                }
            }
            if changed { self.rebuildPipeline() }
        }
    }

    /// Index the project folders in the background, then swap in a pipeline
    /// that knows their names. Until then dictation works without them.
    private func startProjectIndex() {
        let paths = config.projects
        guard !paths.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            let started = Date()
            let index = ProjectIndex.scan(paths)
            let elapsed = Date().timeIntervalSince(started)
            await MainActor.run {
                guard let self else { return }
                self.projectIndex = index
                self.rebuildPipeline()
                log(String(
                    format: "✓ projects indexed — %d names, %d files in %.1f s",
                    min(index.identifiers.count, ProjectIndex.maxTerms), index.files.count, elapsed))
            }
        }
    }

    /// Called on the main actor once the engine is loaded.
    fileprivate func engineBecameReady() {
        ready = true
        if HotkeyMonitor.hasAccessibilityPermission {
            setIndicator(.idle)
            menuBar?.note("ready to listen")
        } else {
            menuBar?.setNeedsPermission(true)
        }
    }

    /// Move to a key macOS does not claim, and persist the choice.
    private func switchToFallbackHotkey() {
        let fallback: Hotkey = .rightOption
        log("switching hotkey to \(fallback.rawValue)")

        monitor.stop()
        monitor = HotkeyMonitor(hotkey: fallback, debug: verbose)
        activeHotkey = fallback

        var updated = config
        updated.hotkey = fallback
        try? updated.save()

        do {
            try startMonitor()
            menuBar?.setHotkeyConflict(false)
            menuBar?.note("ready — hold \(fallback.displayName)")
            log("✓ hotkey is now \(fallback.displayName)")
        } catch {
            log("couldn't install the fallback hotkey: \(error)")
            menuBar?.note("hotkey unavailable")
        }
    }

    private func startMonitor() throws {
        monitor.onSilentTap = { [weak self] in
            self?.menuBar?.note("permissions look stale — run: yaz reset-permissions")
        }
        try monitor.start { [weak self] event in
            // The tap callback already hops to main; assume that rather than
            // scheduling another hop, so press/release ordering is preserved.
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    /// Poll until the grant lands, then start listening.
    ///
    /// `AXIsProcessTrusted` flips for the running process as soon as the user
    /// ticks the box, so polling means the app starts working without being
    /// quit and reopened — which is what every other dictation tool asks for
    /// and nobody enjoys.
    private func waitForPermissions() {
        // The timer is held on the actor rather than captured in its own
        // closure: Swift 6 will not let a task-isolated `Timer` cross into a
        // main-actor closure, and holding it here also keeps it alive.
        permissionPoll?.invalidate()
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard HotkeyMonitor.hasAccessibilityPermission,
                      InputMonitoring.state.isGranted else { return }
                self.permissionPoll?.invalidate()
                self.permissionPoll = nil
                do {
                    try self.startMonitor()
                    log("✓ permissions granted — listening")
                    self.menuBar?.setNeedsPermission(false)
                    self.menuBar?.note("ready to listen")
                    self.setIndicator(.idle)
                } catch {
                    log("couldn't install the hotkey: \(error)")
                    self.menuBar?.note("hotkey unavailable")
                }
            }
        }
        if let permissionPoll { RunLoop.main.add(permissionPoll, forMode: .common) }
    }

    private func presentPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "yaz needs Accessibility permission"
        alert.informativeText = """
            Needed to watch the push-to-talk key and paste text at your cursor.

            Tick yaz in System Settings → Privacy & Security → Accessibility. \
            It starts working the moment you grant it — no need to restart the app.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }

    private func handle(_ event: HotkeyMonitor.Event) {
        let now = ProcessInfo.processInfo.systemUptime
        switch event {
        case .pressed:
            // A new recording needs the model and an idle pipeline; a press
            // that belongs to a recording in progress (the second tap, the
            // stop of a hands-free one) always goes through.
            if ptt.state == .idle {
                guard ready else {
                    log("  (model still loading)")
                    return
                }
                guard !busy else {
                    if verbose { log("  (previous transcription still running — not recording)") }
                    return
                }
            }
            apply(ptt.press(at: now))
        case .released:
            apply(ptt.release(at: now))
        }
    }

    private func apply(_ command: PushToTalk.Command) {
        switch command {
        case .start:
            do {
                try capture.start()
                readScreenTerms()
                log("● recording")
                if let wait = AgentHandoff.standard.pendingWait() {
                    overlay?.setDetail(wait.prompt.map { "agent: \($0)" } ?? "the answer goes to the agent")
                }
                setIndicator(.recording)
                startLivePreview()
            } catch {
                ptt.reset()
                log("couldn't start recording: \(error)")
                menuBar?.note("microphone unavailable")
            }
        case .lock:
            log("● recording hands-free — press the key again to stop")
            menuBar?.note("● recording hands-free")
            if !config.liveText { overlay?.setDetail("hands-free · press to stop") }
        case .stop:
            stopRecording()
        case .discard:
            stopLivePreview()
            _ = capture.stop()
            setIndicator(.idle)
            if verbose { log("○ a single tap — dropped") }
        case .none:
            break
        }
        // A tap waits for its second: close the window if none comes.
        if case .armed = ptt.state {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(PushToTalk.secondTapWindow + 0.05))
                guard let self else { return }
                self.apply(self.ptt.tick(at: ProcessInfo.processInfo.systemUptime))
            }
        }
    }

    private func stopRecording() {
        stopLivePreview()
        guard capture.isRecording else { return }
        let samples = capture.stop()
        let sawSignal = capture.didSeeSignal
        let hitLimit = capture.didHitLimit
        if hitLimit { log("warning: recording hit the length limit and was truncated") }
        setIndicator(.transcribing)
        busy = true
        Task { await self.finish(samples, sawSignal: sawSignal) }
    }

    // MARK: - Live preview

    /// About once a second, transcribe what has been said so far and show it
    /// in the pill. Raw Whisper output, no gates: it is only ever shown. The
    /// final transcript is a separate pass over the whole recording.
    private func startLivePreview() {
        guard config.liveText else { return }
        liveTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { self.refreshLivePreview() }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    private func stopLivePreview() {
        liveTimer?.invalidate()
        liveTimer = nil
        overlay?.setDetail(nil)
    }

    private func refreshLivePreview() {
        guard !liveInFlight, capture.isRecording else { return }
        let samples = capture.snapshot()
        // Under a second, Whisper returns nothing worth showing.
        guard Double(samples.count) >= AudioLoader.sampleRate else { return }
        liveInFlight = true
        let engine = self.engine
        Task.detached(priority: .utility) { [weak self] in
            var options = TranscribeOptions.raw
            options.timeout = .seconds(10)
            let text = try? await engine.transcribe(samples, options: options).text
            await MainActor.run {
                guard let self else { return }
                self.liveInFlight = false
                if self.capture.isRecording, let text {
                    self.overlay?.setDetail(LivePreview.tail(of: text))
                }
            }
        }
    }

    // MARK: - Paste last

    /// Paste the previous dictation again, into whatever is focused now. The
    /// menu is in the status bar and yaz never becomes active, so the app the
    /// user was in is still the one that receives it.
    private func pasteLast() {
        if let lastText {
            TextInjector.inject(lastText, mode: config.injectMode)
            return
        }
        Task { [history] in
            guard let text = await history.entries(limit: 1).first?.text else { return }
            await MainActor.run { TextInjector.inject(text, mode: Config.load().injectMode) }
        }
    }

    private func finish(_ samples: [Float], sawSignal: Bool) async {
        defer {
            busy = false
            setIndicator(.idle)
        }

        let started = Date()
        // The app being dictated into decides the settings: the overlay never
        // takes focus, so the front app is still the target.
        let (appConfig, activePipeline) = settings(for: AppEnvironment.frontmostApp()?.bundleID)
        do {
            var options = TranscribeOptions()
            options.voice = config.voiceCheck
            if appConfig.language != config.language { options.language = appConfig.language }
            let output = try await engine.transcribe(samples, options: options)
            let elapsed = Date().timeIntervalSince(started)

            switch output.quality.verdict {
            case .rejected(let reason):
                log("○ skipped: \(reason)")
                menuBar?.note("skipped — \(reason)")
                return
            case .lowConfidence(let reason):
                log("! \(reason)")
            case .good:
                break
            }

            // Vocabulary correction and refinement both run on the finished
            // transcript, because the ASR-level alternatives do not work on
            // this stack: Whisper returns empty output when given promptTokens,
            // and the on-device LLM cannot do fuzzy Turkish-phonetic matching.
            // Into an editor, a terminal or a coding agent: project names,
            // casing commands and file mentions apply. Read now — the cursor
            // is still in that app, the pill never takes focus.
            // "geri al" on its own is an instruction to yaz, not text.
            if appConfig.voiceCommands,
               let set = LanguagePack.forLanguage(appConfig.language)?.commands,
               let control = VoiceCommands.control(output.text, set: set) {
                screenTerms?.cancel()
                screenTerms = nil
                switch control {
                case .undoLast: undoLast()
                }
                return
            }

            let code = appConfig.codeOverride ?? CodeContext.isCode(
                bundleID: AppEnvironment.frontmostApp()?.bundleID, extra: config.codeApps)
            if appConfig.refine == .llm && !code { setIndicator(.refining) }
            let screen = await screenTerms?.value ?? []
            let context = appConfig.screenContext && appConfig.language == config.language ? screen : []
            screenTerms = nil
            if verbose, !context.isEmpty {
                log("  screen: \(context.count) terms (\(context.prefix(6).map(\.canonical).joined(separator: ", ")))")
            }
            let processed = await activePipeline.process(output.text, code: code, context: context)
            for change in processed.codeChanges {
                log("  code: \(change.from) → \(change.to)")
            }
            for change in processed.numberChanges {
                log("  number: \(change.from) → \(change.to)")
            }
            for command in processed.commands {
                log("  command: \(command)")
            }
            for correction in processed.corrections {
                log("  vocabulary: \(correction.from) → \(correction.to)")
            }
            if let rejection = processed.refinementRejected, verbose {
                log("  post-processing skipped: \(rejection)")
            }

            let total = Date().timeIntervalSince(started)
            log(String(format: "→ %.2f s (transcribe %.2f) · %@", total, elapsed, processed.text))

            // Read the frontmost app *before* pasting: the overlay never takes
            // focus, so at this instant it is still the window the cursor is
            // in — which is the only moment that answer is correct.
            let target = AppEnvironment.frontmostApp()

            // A coding agent asked for this answer (`yaz mcp`,
            // wait_for_dictation): it goes there, not into its input box.
            if let wait = AgentHandoff.standard.pendingWait(),
               (try? AgentHandoff.standard.deliver(processed.text, to: wait)) != nil {
                log("→ sent to the waiting agent")
                menuBar?.note("sent to the agent")
            } else {
                TextInjector.inject(processed.text, mode: config.injectMode)
                lastText = processed.text
                runHook(with: processed.text)
                if config.learn, Vocabulary.isSupported(language: appConfig.language),
                   appConfig.language == config.language,
                   let bundleID = target?.bundleID {
                    scheduleReadBack(
                        pasted: processed.text, corrections: processed.corrections, in: bundleID)
                }
            }

            let entry = HistoryEntry(
                date: Date(),
                text: processed.text,
                appName: target?.name,
                appBundleID: target?.bundleID,
                seconds: output.duration,
                engine: engine.name,
                model: engine.model,
                corrections: processed.corrections.map { "\($0.from) → \($0.to)" })
            Task { [history] in await history.record(entry) }

        } catch let error as YazError where error.isBenignInput {
            // Tapping the key by accident, or a moment of silence, is not a
            // failure worth shouting about.
            // A voice-check drop is always logged: if the threshold is wrong
            // for someone's microphone, the log is where they will see it.
            if case .noSpeechDetected = error {
                log("○ skipped: \(error.description)")
            } else if verbose {
                log("○ \(error.description)")
            }
            if !sawSignal && !samples.isEmpty {
                // Distinguish "you were quiet" from "the mic is dead".
                log("warning: no signal from the microphone — check the input device")
            }
        } catch {
            log("✗ \(error)")
        }
    }

    /// Push a state to every indicator that is switched on.
    private func setIndicator(_ state: IndicatorState) {
        menuBar?.update(state)
        if state.isVisible { overlay?.show(state) } else { overlay?.hide() }
    }

    private static func summary(of config: Config) -> String {
        "\(config.whisperModel.rawValue) · \(config.language) · \(config.hotkey.displayName)"
    }

    private func shutdown() {
        log("shutting down")
        monitor.stop()
        capture.stop()
        overlay?.hide()
        menuBar?.remove()
        NSApp.terminate(nil)
    }

    /// Fire the configured shell command with the transcript as its argument.
    /// Detached: a slow hook must not delay the next utterance.
    private func runHook(with text: String) {
        guard let command = config.onTranscript else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(command) \"$0\"", text]
        do {
            try process.run()
        } catch {
            log("on_transcript failed to launch: \(error)")
        }
    }

    private func installSignalHandlers() {
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { self.shutdown() }
        }
        source.resume()
        signal(SIGINT, SIG_IGN)
        // Keep the source alive for the process lifetime.
        Self.signalSources.append(source)
    }

    private nonisolated(unsafe) static var signalSources: [DispatchSourceSignal] = []
}
