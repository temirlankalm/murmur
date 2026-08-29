import Foundation
@preconcurrency import AVFoundation
import Speech
import FoundationModels
import ApplicationServices
import AppKit
@preconcurrency import WhisperKit

/// `Murmur --check` — prints what's working and what isn't.
/// Worth asking for in any bug report.
@MainActor
enum Diagnostics {
    static func run() async {
        print("Murmur diagnostics\n")

        line("macOS", ProcessInfo.processInfo.operatingSystemVersionString,
             ok: ProcessInfo.processInfo.isOperatingSystemAtLeast(
                OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)))

        line("Accessibility", AXIsProcessTrusted() ? "granted" : "not granted — dictation can't type",
             ok: AXIsProcessTrusted())

        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        line("Microphone", mic == .authorized ? "granted" : "not granted", ok: mic == .authorized)

        // MARK: Speech engine

        await Backends.loadCatalog()
        let kind = Settings.shared.backend
        let resolved = await Backends.resolveLocale(for: kind)
        let chosen = Settings.shared.localeIdentifier
        line("Engine", kind.label, ok: true)

        if chosen == Settings.autoDetectLocale && kind == .whisper {
            line("Locale", "detected per dictation (fallback \(resolved.identifier(.bcp47)))", ok: true)
        } else {
            let source = chosen.isEmpty ? "auto from \(Locale.preferredLanguages.first ?? "?")" : "chosen"
            line("Locale", "\(resolved.identifier(.bcp47)) (\(source))", ok: true)
        }

        switch kind {
        case .apple:
            let installed = await SpeechTranscriber.installedLocales
            let isInstalled = installed.contains { $0.identifier(.bcp47) == resolved.identifier(.bcp47) }
            line("Speech model", isInstalled ? "installed" : "not installed — downloads on first use", ok: true)
        case .whisper:
            let model = Settings.shared.whisperModel.isEmpty
                ? "\(WhisperBackend.defaultModel()) (auto)"
                : Settings.shared.whisperModel
            line("Whisper model", model, ok: true)
        }

        let apple = AppleBackend.supportedLocales.map { $0.identifier(.bcp47) }
        print("     Apple languages:   \(apple.joined(separator: ", "))")
        print("     Whisper languages: \(WhisperBackend.supportedLocales.count) available")
        if !apple.contains(where: { $0.split(separator: "-").first.map(String.init) == systemLanguage }) {
            print("     note: your system language (\(systemLanguage)) needs the Whisper engine")
        }

        // MARK: Cleanup

        switch SystemLanguageModel.default.availability {
        case .available:
            line("On-device LLM", "available", ok: true)
        case .unavailable(let reason):
            line("On-device LLM", "unavailable (\(reason)) — turn on Apple Intelligence, or use remote cleanup", ok: false)
        @unknown default:
            line("On-device LLM", "unknown", ok: false)
        }

        line("Cleanup", Settings.shared.cleanup.label, ok: true)
        if Settings.shared.cleanup == .remote {
            let hasKey = Keychain.get(RemoteCleanup.keychainAccount) != nil
            line("Remote key", hasKey ? "set" : "missing", ok: hasKey)
        }
        line("Trigger key", Settings.shared.trigger.label, ok: true)
    }

    /// `Murmur --focus [seconds]` — reports what the focused text field looks
    /// like to the Accessibility API, so we can tell why an app won't accept
    /// text. Never prints field contents, only whether they exist.
    static func inspectFocus(after seconds: Double) async {
        print("Focus the field you want to test — inspecting in \(Int(seconds))s…")
        try? await Task.sleep(for: .seconds(seconds))

        guard AXIsProcessTrusted() else {
            print("Accessibility not granted.")
            return
        }

        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused,
              CFGetTypeID(element) == AXUIElementGetTypeID() else {
            print("No focused UI element.")
            return
        }
        let target = element as! AXUIElement

        var pid: pid_t = 0
        AXUIElementGetPid(target, &pid)
        let app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "unknown"

        func string(_ name: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(target, name as CFString, &value) == .success else { return nil }
            return value as? String
        }

        let role = string(kAXRoleAttribute as String) ?? "—"
        let subrole = string(kAXSubroleAttribute as String) ?? "—"
        let value = string(kAXValueAttribute as String)

        var settable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(target, kAXSelectedTextAttribute as CFString, &settable)

        var names: CFArray?
        AXUIElementCopyAttributeNames(target, &names)
        let attributes = (names as? [String]) ?? []

        print("  app:            \(app)")
        print("  role:           \(role)")
        print("  subrole:        \(subrole)")
        // Deliberately not printing contents — only whether there are any.
        print("  value:          \(value == nil ? "not exposed" : "\(value!.count) chars")")
        print("  selectedText settable: \(settableResult == .success ? String(settable.boolValue) : "error \(settableResult.rawValue)")")
        print("  attributes:     \(attributes.joined(separator: ", "))")

        let axEligible = (role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String))
            && settableResult == .success && settable.boolValue
        print("")
        print("  → Murmur would use: \(axEligible ? "Accessibility insert" : "clipboard paste")")
    }

    /// `Murmur --paste <text> [--delay 4]` — exercises the injection path
    /// exactly as a real dictation would, so we can tell whether an app
    /// accepts text without having to speak into it.
    @MainActor
    static func testPaste(_ text: String, delay: Double) async {
        print("Focus the target field — pasting in \(Int(delay))s…")
        try? await Task.sleep(for: .seconds(delay))
        print("secure input enabled: \(TextInjector.isSecureInputEnabled)")
        TextInjector.insert(text, forcePasteboard: CommandLine.arguments.contains("--clipboard"))
        print("Sent.")
        // Give the pasteboard restore its moment before we exit.
        try? await Task.sleep(for: .seconds(1.5))
    }

    /// `Murmur --dictate [seconds]` — runs mic → transcribe with no hotkey and
    /// no injection, and reports the peak input level so we can tell whether
    /// the microphone is actually hearing anything.
    @MainActor
    static func selfTestCapture(seconds: Double) async {
        let kind = Settings.shared.backend
        let backend = Backends.make(kind)
        let locale = await Backends.resolveLocale(for: kind)
        print("engine: \(kind.rawValue), locale: \(locale.identifier(.bcp47))")

        do {
            try await backend.prepare(locale: locale) { print("  \($0)") }
            try await backend.begin(locale: locale)

            let audio = AudioCapture()
            var peak: Float = 0
            var capturedForLevelCheck: [Float] = []
            let resampler = AudioResampler(to: AudioResampler.whisperFormat)
            audio.onLevel = { peak = max(peak, $0) }
            try audio.start { buffer in
                backend.append(buffer)
                if let converted = resampler.resample(buffer) {
                    capturedForLevelCheck.append(contentsOf: AudioResampler.samples(of: converted))
                }
            }

            print("recording for \(Int(seconds))s — say something…")
            try? await Task.sleep(for: .seconds(seconds))
            audio.stop()

            let text = await backend.finish()
            print(String(format: "peak input level: %.3f%@", peak,
                         peak < 0.01 ? "  ← microphone heard nothing" : ""))
            if kind == .whisper {
                print(String(format: "loudest 100ms window: %.5f (speech gate needs > 0.004)",
                             WhisperBackend.loudestWindow(capturedForLevelCheck)))
            }
            print("transcript: \(text.isEmpty ? "(empty)" : text)")
        } catch {
            print("failed: \(error.localizedDescription)")
        }
    }

    /// `Murmur --test-hotkey` — synthesises a press of the trigger key and
    /// reports whether the event tap saw it.
    @MainActor
    static func testHotkey() {
        let monitor = HotkeyMonitor()
        var sawPress = false
        var sawRelease = false
        monitor.onPress = { _ in sawPress = true }
        monitor.onRelease = { _ in sawRelease = true }
        monitor.start()

        guard monitor.isRunning else {
            print("event tap could NOT be created — Accessibility permission is not really in effect")
            return
        }
        print("event tap created")

        let trigger = Settings.shared.trigger
        func post(down: Bool) {
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let event = CGEvent(source: source) else { return }
            event.type = .flagsChanged
            event.setIntegerValueField(.keyboardEventKeycode, value: trigger.keyCode)
            event.flags = down ? trigger.flag : []
            event.post(tap: .cghidEventTap)
        }

        post(down: true)
        CFRunLoopRunInMode(.defaultMode, 0.7, false)
        post(down: false)
        CFRunLoopRunInMode(.defaultMode, 0.5, false)

        print("trigger: \(trigger.label)")
        print("press seen:   \(sawPress)")
        print("release seen: \(sawRelease)")
        monitor.stop()
    }

    /// `Murmur --watch-keys [seconds]` — prints every modifier event the tap
    /// sees. Ground truth for "the hotkey does nothing".
    /// Note: this spins a real CFRunLoop rather than awaiting. Event tap
    /// sources are attached to the main CFRunLoop, and `dispatchMain()` runs
    /// the GCD main queue instead — under which the tap never fires at all.
    @MainActor
    static func watchKeys(seconds: Double) {
        let tapped = TapLogger()
        guard tapped.start() else {
            print("event tap could NOT be created — Accessibility is not really in effect")
            return
        }
        print("watching for \(Int(seconds))s — press and release your trigger key…")
        print("(trigger is \(Settings.shared.trigger.label), keycode \(Settings.shared.trigger.keyCode))")
        fflush(stdout)
        CFRunLoopRunInMode(.defaultMode, seconds, false)
        tapped.stop()
        print("saw \(tapped.events.count) modifier events")
        for line in tapped.events.prefix(40) { print("  \(line)") }
    }

    /// `Murmur --press <seconds>` — holds the trigger key for real, so a
    /// running Murmur performs a full dictation we can then read in the log.
    @MainActor
    static func pressTrigger(seconds: Double) {
        let trigger = Settings.shared.trigger
        func post(down: Bool) {
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let event = CGEvent(source: source) else { return }
            event.type = .flagsChanged
            event.setIntegerValueField(.keyboardEventKeycode, value: trigger.keyCode)
            event.flags = down ? trigger.flag : []
            event.post(tap: .cghidEventTap)
        }
        print("holding \(trigger.label) for \(seconds)s…")
        post(down: true)
        CFRunLoopRunInMode(.defaultMode, seconds, false)
        post(down: false)
        CFRunLoopRunInMode(.defaultMode, 0.3, false)
        print("released")
    }

    /// `Murmur --test-cleanup` — same round-trip as the Test button.
    @MainActor
    static func testCleanup() async {
        print("endpoint: \(Settings.shared.remoteBaseURL)")
        print("model:    \(Settings.shared.remoteModel)")
        print("key:      \(Keychain.get(RemoteCleanup.keychainAccount)?.isEmpty == false ? "set" : "none (fine for a local server)")")
        print(await RemoteCleanup().test())
    }

    /// `Murmur --test-edit "make this formal"` — selects all in the frontmost
    /// app and runs the voice-edit path with the instruction typed instead of
    /// spoken. Exercises everything but the microphone.
    @MainActor
    static func testEdit(_ instruction: String, delay: Double) async {
        print("focus the text you want rewritten — starting in \(Int(delay))s…")
        try? await Task.sleep(for: .seconds(delay))

        TextInjector.selectAll()
        try? await Task.sleep(for: .milliseconds(200))

        guard let selection = await TextInjector.copySelection() else {
            print("nothing selected — the app returned no text")
            return
        }
        print("selection: \(selection.count) chars — \(selection.prefix(60))")

        do {
            let rewritten = try await Cleanup.provider(for: Settings.shared.cleanup)
                .rewrite(selection, instruction: instruction)
            print("rewritten: \(rewritten)")
            TextInjector.insert(rewritten)
            print("injected")
        } catch {
            print("failed: \(error.localizedDescription)")
        }
    }

    static func listModels() {
        let support = WhisperKit.recommendedModels()
        print("recommended default: \(support.default)")
        print("disabled: \(support.disabled)")
        for m in support.supported { print("  \(m)") }
    }

    /// `Murmur --transcribe <file> [--model <name>] [--language <code>]`
    /// Runs an audio file through the Whisper backend. Handy for checking the
    /// engine works without wiring up a microphone.
    static func transcribe(path: String, model: String?, language: String?) async {
        let name = model ?? (Settings.shared.whisperModel.isEmpty
            ? WhisperBackend.defaultModel()
            : Settings.shared.whisperModel)
        FileHandle.standardError.write("Loading \(name)…\n".data(using: .utf8)!)

        do {
            let config = WhisperKitConfig(model: name, downloadBase: WhisperBackend.downloadBase,
                                          tokenizerFolder: WhisperBackend.downloadBase
                                              .appendingPathComponent("tokenizers"),
                                          verbose: false, logLevel: .error,
                                          prewarm: false, load: true, download: true)
            let kit = try await WhisperKit(config)
            let options = DecodingOptions(
                verbose: false, task: .transcribe, language: language ?? "en",
                temperature: 0, detectLanguage: language == nil,
                skipSpecialTokens: true, withoutTimestamps: true
            )
            // Report the level too, so we can see how real speech compares
            // with the silence gate's floor.
            if let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
               let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
               (try? file.read(into: input)) != nil {
                let resampler = AudioResampler(to: AudioResampler.whisperFormat)
                if let converted = resampler.resample(input) {
                    let samples = AudioResampler.samples(of: converted)
                    let level = WhisperBackend.loudestWindow(samples)
                    FileHandle.standardError.write(String(
                        format: "loudest 100ms window: %.5f (gate floor 0.004) → %@\n",
                        level, WhisperBackend.hasSpeech(samples) ? "passes" : "REJECTED"
                    ).data(using: .utf8)!)
                }
            }

            let started = Date()
            let results = try await kit.transcribe(audioPath: path, decodeOptions: options)
            let elapsed = Date().timeIntervalSince(started)
            print(results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces))
            FileHandle.standardError.write(String(format: "(%.1fs)\n", elapsed).data(using: .utf8)!)
        } catch {
            FileHandle.standardError.write("failed: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    private static var systemLanguage: String {
        (Locale.preferredLanguages.first ?? "en").split(separator: "-").first.map(String.init) ?? "en"
    }

    private static func line(_ label: String, _ value: String, ok: Bool) {
        print("  \(ok ? "✓" : "✗") \(label.padding(toLength: 15, withPad: " ", startingAt: 0)) \(value)")
    }
}
