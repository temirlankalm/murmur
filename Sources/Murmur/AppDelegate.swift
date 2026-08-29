import AppKit
import ServiceManagement
@preconcurrency import WhisperKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let controller = DictationController()
    private lazy var settingsWindow = SettingsWindow(controller: controller)

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        controller.onStatusChange = { [weak self] status in
            self?.updateIcon(for: status)
        }

        Task {
            await Backends.loadCatalog()
            _ = await AudioCapture.requestPermission()
            if !TextInjector.isTrusted {
                promptForAccessibility()
            }
            controller.start()
            controller.warmUp()
            rebuildMenu()

            let armed = controller.isArmed
            NSLog("Murmur: launched, status item = \(statusItem.button != nil), armed = \(armed)")

            if !Settings.shared.hasLaunched {
                Settings.shared.hasLaunched = true
                openSettings()
            } else {
                controller.announce(armed
                    ? "Murmur ready — hold \(Settings.shared.trigger.label) to dictate"
                    : "Murmur needs Accessibility access to work")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    /// Opening Murmur again — from Finder, Spotlight, the Dock — brings up the
    /// settings window. Without this there'd be no way back in if the menu bar
    /// icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return true
    }

    /// `open murmur://settings` from anywhere brings the window up.
    ///
    /// Needed because a menu-bar-only app gets no reopen event from `open
    /// Murmur.app`, so without this there is no way back in when the status
    /// icon is hidden — behind the notch, say.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "murmur" }) else { return }
        openSettings()
    }

    @objc func openSettings() {
        settingsWindow.show()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(for: .idle)

        let menu = NSMenu()
        // Rebuilt on every open so the checkmarks stay honest.
        menu.delegate = self
        statusItem.menu = menu
        populate(menu)
    }

    private func updateIcon(for status: DictationController.Status) {
        let name: String
        switch status {
        case .idle:      name = "waveform"
        case .listening: name = "waveform.circle.fill"
        case .working:   name = "ellipsis.circle"
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: "Murmur"
        )
        statusItem.button?.image?.isTemplate = true
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        populate(menu)
    }

    /// Rebuilds in place. Assigning a fresh NSMenu from inside
    /// `menuNeedsUpdate` breaks the menu that's mid-open.
    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: "Hold \(Settings.shared.trigger.label) to dictate · Esc cancels", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !TextInjector.isTrusted {
            menu.addItem(.separator())
            let warn = NSMenuItem(title: "⚠︎ Grant Accessibility access…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        // Trigger key
        let triggerItem = NSMenuItem(title: "Trigger key", action: nil, keyEquivalent: "")
        let triggerMenu = NSMenu()
        for key in TriggerKey.allCases {
            let item = NSMenuItem(title: key.label, action: #selector(pickTrigger(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            item.state = Settings.shared.trigger == key ? .on : .off
            triggerMenu.addItem(item)
        }
        triggerItem.submenu = triggerMenu
        menu.addItem(triggerItem)

        // Cleanup mode
        let cleanupItem = NSMenuItem(title: "Cleanup", action: nil, keyEquivalent: "")
        let cleanupMenu = NSMenu()
        for mode in CleanupMode.allCases {
            let item = NSMenuItem(title: mode.label, action: #selector(pickCleanup(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = Settings.shared.cleanup == mode ? .on : .off
            if mode == .local && !LocalCleanup.isAvailable {
                item.isEnabled = false
                item.title += " (unavailable)"
            }
            cleanupMenu.addItem(item)
        }
        cleanupMenu.addItem(.separator())
        let keyItem = NSMenuItem(title: "Set remote API key…", action: #selector(setRemoteKey), keyEquivalent: "")
        keyItem.target = self
        cleanupMenu.addItem(keyItem)
        cleanupItem.submenu = cleanupMenu
        menu.addItem(cleanupItem)

        // Speech engine
        let backendItem = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
        let backendMenu = NSMenu()
        for kind in BackendKind.allCases {
            let item = NSMenuItem(title: kind.label, action: #selector(pickBackend(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.state = Settings.shared.backend == kind ? .on : .off
            backendMenu.addItem(item)
        }
        if Settings.shared.backend == .whisper {
            backendMenu.addItem(.separator())
            let support = WhisperKit.recommendedModels()
            let header = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
            header.isEnabled = false
            backendMenu.addItem(header)

            let auto = NSMenuItem(title: "Automatic — \(WhisperBackend.defaultModel())", action: #selector(pickWhisperModel(_:)), keyEquivalent: "")
            auto.target = self
            auto.representedObject = ""
            auto.state = Settings.shared.whisperModel.isEmpty ? .on : .off
            backendMenu.addItem(auto)

            for model in support.supported where !support.disabled.contains(model) {
                let item = NSMenuItem(title: model, action: #selector(pickWhisperModel(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = model
                item.state = Settings.shared.whisperModel == model ? .on : .off
                backendMenu.addItem(item)
            }
        }
        backendItem.submenu = backendMenu
        menu.addItem(backendItem)

        // Language
        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        let auto = NSMenuItem(title: "Automatic", action: #selector(pickLocale(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = ""
        auto.state = Settings.shared.localeIdentifier.isEmpty ? .on : .off
        languageMenu.addItem(auto)
        languageMenu.addItem(.separator())
        for locale in Backends.languages(for: Settings.shared.backend) {
            let id = locale.identifier(.bcp47)
            let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? id
            let item = NSMenuItem(title: "\(name) — \(id)", action: #selector(pickLocale(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = Settings.shared.localeIdentifier == id ? .on : .off
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        // Sounds
        let sound = NSMenuItem(title: "Play sounds", action: #selector(toggleSounds), keyEquivalent: "")
        sound.target = self
        sound.state = Settings.shared.playSounds ? .on : .off
        menu.addItem(sound)

        let vocabulary = NSMenuItem(title: "Custom vocabulary…", action: #selector(editVocabulary), keyEquivalent: "")
        vocabulary.target = self
        menu.addItem(vocabulary)

        let history = NSMenuItem(title: "Save history", action: #selector(toggleHistory), keyEquivalent: "")
        history.target = self
        history.state = Settings.shared.saveHistory ? .on : .off
        menu.addItem(history)

        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        // Recent dictations
        let recent = History.shared.entries.prefix(5)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let historyItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            let historyMenu = NSMenu()
            for entry in recent {
                let preview = entry.cleaned.prefix(60)
                let item = NSMenuItem(title: String(preview), action: #selector(copyEntry(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.cleaned
                historyMenu.addItem(item)
            }
            historyMenu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear history", action: #selector(clearHistory), keyEquivalent: "")
            clear.target = self
            historyMenu.addItem(clear)
            historyItem.submenu = historyMenu
            menu.addItem(historyItem)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

    }

    // MARK: - Actions

    @objc private func pickTrigger(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = TriggerKey(rawValue: raw) else { return }
        Settings.shared.trigger = key
        rebuildMenu()
    }

    @objc private func pickCleanup(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = CleanupMode(rawValue: raw) else { return }
        Settings.shared.cleanup = mode
        rebuildMenu()
    }

    @objc private func pickBackend(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = BackendKind(rawValue: raw) else { return }
        guard kind != Settings.shared.backend else { return }
        Settings.shared.backend = kind
        // The old language choice probably doesn't exist on the new engine.
        Settings.shared.localeIdentifier = ""
        controller.invalidateAssets()
        rebuildMenu()
    }

    @objc private func pickWhisperModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? String else { return }
        Settings.shared.whisperModel = model
        controller.invalidateAssets()
        rebuildMenu()
    }

    @objc private func pickLocale(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.shared.localeIdentifier = id
        controller.invalidateAssets()
        rebuildMenu()
    }

    @objc private func toggleSounds() {
        Settings.shared.playSounds.toggle()
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Murmur: login item toggle failed — \(error.localizedDescription)")
        }
        rebuildMenu()
    }

    @objc private func toggleHistory() {
        Settings.shared.saveHistory.toggle()
        if !Settings.shared.saveHistory { History.shared.clear() }
        rebuildMenu()
    }

    @objc private func editVocabulary() {
        let alert = NSAlert()
        alert.messageText = "Custom vocabulary"
        alert.informativeText = "Names and jargon the transcriber keeps getting wrong, one per line. Used by the cleanup pass."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        text.string = Settings.shared.vocabulary.joined(separator: "\n")
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Settings.shared.vocabulary = text.string
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    @objc private func copyEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func clearHistory() {
        History.shared.clear()
        rebuildMenu()
    }

    @objc private func setRemoteKey() {
        let alert = NSAlert()
        alert.messageText = "Remote cleanup API key"
        alert.informativeText = "Stored in your login keychain. Endpoint: \(Settings.shared.remoteBaseURL)"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = Keychain.get(RemoteCleanup.keychainAccount) ?? ""
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Keychain.set(field.stringValue, for: RemoteCleanup.keychainAccount)
        }
    }

    @objc private func openAccessibilitySettings() {
        promptForAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func promptForAccessibility() {
        TextInjector.requestTrust()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }
}
