import AppKit
import SwiftUI

/// A real window, because a menu bar icon is easy to lose — on a notched
/// MacBook with a full menu bar it can be invisible entirely. Re-opening
/// Murmur from Finder or Spotlight brings this up.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: SettingsModel

    init(controller: DictationController) {
        model = SettingsModel(controller: controller)
    }

    func show() {
        model.startPolling()

        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Murmur"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stopPolling()
        window = nil
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    private let controller: DictationController

    @Published var trigger: TriggerKey { didSet { Settings.shared.trigger = trigger } }
    @Published var activation: ActivationMode { didSet { Settings.shared.activation = activation } }
    @Published var editTrigger: String {
        didSet { Settings.shared.editTrigger = TriggerKey(rawValue: editTrigger) }
    }
    @Published var backend: BackendKind {
        didSet {
            guard backend != oldValue else { return }
            Settings.shared.backend = backend
            // The old language almost certainly isn't on the new engine's list.
            Settings.shared.localeIdentifier = ""
            locale = ""
            controller.invalidateAssets()
        }
    }
    @Published var locale: String {
        didSet {
            guard locale != oldValue else { return }
            Settings.shared.localeIdentifier = locale
            controller.invalidateAssets()
        }
    }
    @Published var cleanup: CleanupMode { didSet { Settings.shared.cleanup = cleanup } }
    @Published var playSounds: Bool { didSet { Settings.shared.playSounds = playSounds } }
    @Published var unloadAfterIdle: Bool { didSet { Settings.shared.unloadAfterIdle = unloadAfterIdle } }
    @Published var saveHistory: Bool {
        didSet {
            Settings.shared.saveHistory = saveHistory
            if !saveHistory { History.shared.clear() }
        }
    }
    @Published var vocabulary: String {
        didSet {
            Settings.shared.vocabulary = vocabulary
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }
    @Published var apiKey: String {
        didSet { Keychain.set(apiKey, for: RemoteCleanup.keychainAccount) }
    }
    @Published var baseURL: String { didSet { Settings.shared.remoteBaseURL = baseURL } }
    @Published var remoteModel: String { didSet { Settings.shared.remoteModel = remoteModel } }
    @Published var testResult: String?
    @Published var testing = false

    func apply(_ preset: CleanupPreset) {
        baseURL = preset.baseURL
        remoteModel = preset.model
        testResult = nil
    }

    func testEndpoint() {
        guard !testing else { return }
        testing = true
        testResult = nil
        Task {
            let outcome = await RemoteCleanup().test()
            testing = false
            testResult = outcome
        }
    }

    init(controller: DictationController) {
        self.controller = controller
        let settings = Settings.shared
        trigger = settings.trigger
        activation = settings.activation
        editTrigger = settings.editTrigger?.rawValue ?? "none"
        backend = settings.backend
        locale = settings.localeIdentifier
        cleanup = settings.cleanup
        playSounds = settings.playSounds
        unloadAfterIdle = settings.unloadAfterIdle
        saveHistory = settings.saveHistory
        vocabulary = settings.vocabulary.joined(separator: "\n")
        apiKey = Keychain.get(RemoteCleanup.keychainAccount) ?? ""
        baseURL = settings.remoteBaseURL
        remoteModel = settings.remoteModel
        // didSet doesn't fire during init, so this reflects reality without
        // overwriting a hand-edited endpoint.
        presetID = CleanupPreset.all.first { $0.baseURL == settings.remoteBaseURL }?.id ?? ""
    }

    var languages: [(id: String, name: String)] {
        Backends.languages(for: backend).map { locale in
            let id = locale.identifier(.bcp47)
            return (id, Locale.current.localizedString(forIdentifier: locale.identifier) ?? id)
        }
    }

    /// Which preset the current endpoint matches, so the picker reflects
    /// hand-edited values instead of lying about them.
    @Published var presetID: String = "" {
        didSet {
            guard let preset = CleanupPreset.all.first(where: { $0.id == presetID }) else { return }
            apply(preset)
        }
    }

    var selectedPreset: CleanupPreset? {
        CleanupPreset.all.first { $0.baseURL == baseURL }
    }

    @Published var statsSummary: String = Stats.shared.summary

    func resetStats() {
        Stats.shared.reset()
        statsSummary = Stats.shared.summary
    }

    var localCleanupAvailable: Bool { LocalCleanup.isAvailable }

    /// Permission state is granted in System Settings while this window is
    /// already on screen, so it has to be polled — a plain computed property
    /// would leave the window insisting the access is missing forever.
    @Published private(set) var hasAccessibility = TextInjector.isTrusted
    @Published private(set) var isArmed = false

    private var pollTask: Task<Void, Never>?

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let trusted = TextInjector.isTrusted
                let armed = self.controller.isArmed
                if trusted != self.hasAccessibility { self.hasAccessibility = trusted }
                if armed != self.isArmed { self.isArmed = armed }
                let summary = Stats.shared.summary
                if summary != self.statsSummary { self.statsSummary = summary }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Form {
                Section {
                    Picker("Dictate with", selection: $model.trigger) {
                        ForEach(TriggerKey.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Activation", selection: $model.activation) {
                        ForEach(ActivationMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Edit selection with", selection: $model.editTrigger) {
                        Text("Off").tag("none")
                        ForEach(TriggerKey.allCases.filter { $0 != model.trigger }, id: \.self) {
                            Text($0.label).tag($0.rawValue)
                        }
                    }
                    if model.editTrigger != "none" {
                        Text("Select text anywhere, hold this key and say what to do with it — \"make this formal\", \"translate to English\", \"shorter\". Needs a cleanup model.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Engine", selection: $model.backend) {
                        ForEach(BackendKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Language", selection: $model.locale) {
                        Text("Match my system language").tag("")
                        if model.backend == .whisper {
                            Text("Detect automatically").tag(Settings.autoDetectLocale)
                        }
                        Divider()
                        ForEach(model.languages, id: \.id) { Text("\($0.name) — \($0.id)").tag($0.id) }
                    }
                    if model.locale == Settings.autoDetectLocale {
                        Text("Whisper works the language out from what it hears. Slightly slower, and it can guess wrong on a very short phrase — but it handles switching languages mid-sentence.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Cleanup") {
                    Picker("Mode", selection: $model.cleanup) {
                        ForEach(CleanupMode.allCases, id: \.self) { mode in
                            Text(mode == .local && !model.localCleanupAvailable
                                 ? "\(mode.label) — unavailable"
                                 : mode.label).tag(mode)
                        }
                    }
                    if model.cleanup == .local && !model.localCleanupAvailable {
                        Text("Apple Intelligence is off, so transcripts are pasted as heard. Turn it on in System Settings, or use a remote API.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if model.cleanup == .remote {
                        Picker("Preset", selection: $model.presetID) {
                            Text("Custom").tag("")
                            ForEach(CleanupPreset.all) { Text($0.name).tag($0.id) }
                        }
                        if let note = model.selectedPreset?.note {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }

                        TextField("Endpoint", text: $model.baseURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        TextField("Model", text: $model.remoteModel)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        SecureField("API key — leave empty for a local server", text: $model.apiKey)

                        HStack {
                            Button(model.testing ? "Testing…" : "Test") { model.testEndpoint() }
                                .disabled(model.testing)
                            if let result = model.testResult {
                                Text(result).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                        Text("Any OpenAI-compatible endpoint works. The key is kept in your login keychain, never in preferences.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Custom vocabulary") {
                    TextEditor(text: $model.vocabulary)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 70)
                    Text("Names and jargon the transcriber mangles, one per line.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Play sounds", isOn: $model.playSounds)
                    Toggle("Save history", isOn: $model.saveHistory)
                    Toggle("Free memory when idle", isOn: $model.unloadAfterIdle)
                    Text("Drops the speech model after \(Settings.shared.idleMinutes) minutes without dictating, saving a few hundred MB. The next dictation reloads it while it records — nothing is lost, that one is just slower.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Usage") {
                    Text(model.statsSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Reset statistics") { model.resetStats() }
                        .controlSize(.small)
                }

                Section {
                    HStack {
                        Spacer()
                        Button("Quit Murmur") { NSApp.terminate(nil) }
                        Spacer()
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 460, height: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hold \(model.trigger.label) to dictate")
                .font(.system(size: 15, weight: .medium))
            Text(status)
                .font(.caption)
                .foregroundStyle(model.isArmed ? Color.secondary : Color.red)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var status: String {
        if !model.hasAccessibility {
            return "Needs Accessibility access in System Settings → Privacy & Security"
        }
        if !model.isArmed {
            return "Access granted, but the key watcher isn't running — quit and reopen Murmur"
        }
        return "Listening for the trigger key · Esc cancels a dictation"
    }
}
