import AppKit
import SwiftUI

/// Settings and history, in the two windows yaz has.
///
/// The config file stays the source of truth: this window reads and writes the
/// same `~/.config/yaz/config.json` a person can edit by hand. A UI that owned
/// its own store would mean two ways to configure the app that quietly
/// disagree.
@MainActor
final class SettingsWindowController {

    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private let model: SettingsModel

    /// Fired when a change needs the daemon restarted to take effect.
    var onNeedsRestart: (() -> Void)?

    init(model: SettingsModel = SettingsModel()) {
        self.model = model
    }

    func showSettings() {
        model.reload()
        if let settingsWindow {
            present(settingsWindow)
            return
        }
        let window = Self.makeWindow(
            title: "yaz — Ayarlar",
            size: NSSize(width: 520, height: 560),
            content: SettingsView(model: model))
        settingsWindow = window
        present(window)
    }

    func showHistory() {
        Task { await model.loadHistory() }
        if let historyWindow {
            present(historyWindow)
            return
        }
        let window = Self.makeWindow(
            title: "yaz — Geçmiş",
            size: NSSize(width: 620, height: 520),
            content: HistoryView(model: model))
        historyWindow = window
        present(window)
    }

    // MARK: -

    private static func makeWindow(
        title: String, size: NSSize, content: some View
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = title
        window.contentView = NSHostingView(rootView: content)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    /// yaz runs as `.accessory`, so it has no menu bar of its own and windows
    /// do not come forward on their own. Activating is required — and safe
    /// here, unlike during dictation, because the user just asked for a window.
    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Observable wrapper over the config file and the history log.
@MainActor
final class SettingsModel: ObservableObject {

    @Published var config: Config = .load()
    @Published var entries: [HistoryEntry] = []
    @Published var historySearch: String = ""
    @Published var saveError: String?
    @Published var savedAt: Date?

    /// New-term field in the vocabulary editor.
    @Published var newTerm: String = ""

    func reload() {
        config = .load()
    }

    func save() {
        do {
            try config.save()
            savedAt = Date()
            saveError = nil
        } catch {
            saveError = "\(error)"
        }
    }

    func addTerm() {
        let trimmed = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !config.vocabulary.contains(where: {
            $0.canonical.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) else {
            newTerm = ""
            return
        }
        config.vocabulary.append(VocabularyTerm(canonical: trimmed))
        newTerm = ""
        save()
    }

    func removeTerms(at offsets: IndexSet) {
        config.vocabulary.remove(atOffsets: offsets)
        save()
    }

    func loadHistory() async {
        let store = TranscriptHistory(limit: config.historyLimit, enabled: config.history)
        let query = historySearch.isEmpty ? nil : historySearch
        entries = await store.entries(limit: 300, matching: query)
    }

    func clearHistory() async {
        let store = TranscriptHistory(limit: config.historyLimit, enabled: config.history)
        await store.clear()
        entries = []
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Kısayol") {
                Picker("Bas-konuş tuşu", selection: $model.config.hotkey) {
                    ForEach(Hotkey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                if model.config.hotkey.conflictsWithSystemFnAction {
                    Label(
                        "Sistem Ayarları → Klavye → 🌐 tuşuna basınca → Hiçbir şey yapma",
                        systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Tanıma") {
                Picker("Motor", selection: $model.config.engine) {
                    ForEach(EngineChoice.allCases, id: \.self) { engine in
                        Text(engine.rawValue).tag(engine)
                    }
                }
                Picker("Whisper modeli", selection: $model.config.whisperModel) {
                    ForEach(WhisperModel.allCases, id: \.self) { whisper in
                        Text("\(whisper.rawValue) · ~\(whisper.sizeMB) MB").tag(whisper)
                    }
                }
                .disabled(model.config.engine != .whisper)

                TextField("Dil kodu", text: $model.config.language)
                if model.config.engine == .parakeet && model.config.language == "tr" {
                    Label("Parakeet Türkçe desteklemiyor", systemImage: "xmark.octagon")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Metin") {
                Picker("Yerleştirme", selection: $model.config.injectMode) {
                    ForEach(TextInjector.Mode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker("Son işleme", selection: $model.config.refine) {
                    ForEach(RefineMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                if model.config.refine == .llm {
                    Text("Dil modeli her ifadeye 0.3–1.4 sn ekler.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Sözlük") {
                Text("Türkçe konuşurken bozulan İngilizce terimler burada onarılır.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("Terim ekle (örn. pull request)", text: $model.newTerm)
                        .onSubmit { model.addTerm() }
                    Button("Ekle") { model.addTerm() }
                        .disabled(model.newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if model.config.vocabulary.isEmpty {
                    Text("henüz terim yok").font(.caption).foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(model.config.vocabulary, id: \.canonical) { term in
                            HStack {
                                Text(term.canonical)
                                if !term.aliases.isEmpty {
                                    Text("· \(term.aliases.joined(separator: ", "))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { model.removeTerms(at: $0) }
                    }
                    .frame(height: 120)
                }
            }

            Section("Gösterge ve geçmiş") {
                Toggle("Kayıt sırasında pil göster", isOn: $model.config.overlay)
                Toggle("Menü barında göster", isOn: $model.config.menuBar)
                Toggle("Geçmiş tut (yalnızca metin)", isOn: $model.config.history)
                if model.config.history {
                    Stepper(
                        "Saklanan kayıt: \(model.config.historyLimit)",
                        value: $model.config.historyLimit, in: 50...20000, step: 50)
                }
            }

            Section {
                HStack {
                    Button("Kaydet") { model.save() }
                        .keyboardShortcut(.defaultAction)
                    if let error = model.saveError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    } else if model.savedAt != nil {
                        Text("kaydedildi — daemon'ı yeniden başlat")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Dosyayı aç") {
                        NSWorkspace.shared.open(Config.path)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 520)
    }
}

// MARK: - History

private struct HistoryView: View {
    @ObservedObject var model: SettingsModel

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        formatter.locale = Locale(identifier: "tr_TR")
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Ara — metin veya uygulama", text: $model.historySearch)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.loadHistory() } }
                Button("Ara") { Task { await model.loadHistory() } }
                Button("Temizle", role: .destructive) {
                    Task { await model.clearHistory() }
                }
            }
            .padding(12)

            Divider()

            if model.entries.isEmpty {
                Spacer()
                Text(model.config.history ? "geçmiş boş" : "geçmiş kapalı")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(model.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(Self.formatter.string(from: entry.date))
                            if let app = entry.appName {
                                Text("· \(app)")
                            }
                            Text(String(format: "· %.1f sn", entry.seconds))
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.text, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Panoya kopyala")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Text(entry.text)
                            .textSelection(.enabled)

                        if !entry.corrections.isEmpty {
                            Text("sözlük: \(entry.corrections.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { await model.loadHistory() }
    }
}
