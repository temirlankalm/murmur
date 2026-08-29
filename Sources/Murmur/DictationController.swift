import AppKit
import AVFoundation

/// Ties the whole loop together: key down → listen → key up → clean → paste.
@MainActor
final class DictationController {
    enum Status {
        case idle, listening, working
    }

    private let hotkey = HotkeyMonitor()
    private let audio = AudioCapture()
    private let overlay = Overlay()

    private var backend: SpeechBackend = Backends.make(Settings.shared.backend)
    private var backendKind: BackendKind = Settings.shared.backend

    private(set) var status: Status = .idle
    private var startedAt: Date?
    private var assetsReady = false
    /// Whether the mic actually opened for this press. A first press can spend
    /// minutes downloading a model and never get as far as recording.
    private var captureStarted = false
    /// Set by Esc. Checked after every await, so a cancel that lands mid-cleanup
    /// still prevents the paste.
    private var cancelled = false
    /// Bumped on every key press. A task from an earlier press must not touch
    /// anything once this has moved on — otherwise a slow model load lets a
    /// stale task open a second capture session mid-dictation.
    private var generation = 0
    private var wasTrusted = false
    private var trustWatch: Task<Void, Never>?
    private var idleUnload: Task<Void, Never>?

    /// Fires whenever status changes, so the menu bar icon can follow along.
    var onStatusChange: (Status) -> Void = { _ in }

    func start() {
        hotkey.onPress = { [weak self] action in self?.keyPressed(action) }
        hotkey.onRelease = { [weak self] action in self?.keyReleased(action) }
        hotkey.onCancel = { [weak self] in self?.cancelDictation() ?? false }
        armHotkey()

        wirePartials()
        audio.onLevel = { [weak self] level in
            guard let self, self.status == .listening else { return }
            self.lastLevel = level
            self.maxLevel = max(self.maxLevel, level)
            self.overlay.show(.listening(text: self.backend.currentText, level: level))
        }
    }

    func stop() {
        idleUnload?.cancel()
        idleUnload = nil
        trustWatch?.cancel()
        trustWatch = nil
        hotkey.stop()
    }

    /// Drop the model after a spell of no dictation, so an app that sits in the
    /// menu bar all day isn't holding a few hundred MB it isn't using. The next
    /// press reloads it while recording, so nothing is lost — just slower once.
    private func scheduleUnload() {
        idleUnload?.cancel()
        guard Settings.shared.unloadAfterIdle else { return }

        let minutes = max(1, Settings.shared.idleMinutes)
        idleUnload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled, let self, self.status == .idle else { return }
            await self.backend.unloadModel()
            guard self.status == .idle else { return }
            self.assetsReady = false
            Log.write("model unloaded after \(minutes) min idle")
        }
    }

    /// Load the speech model before it's needed.
    ///
    /// Whisper takes seconds to load into memory, and the first key press used
    /// to be swallowed by that wait — which reads exactly like "it doesn't
    /// work". Do it at launch and on engine changes instead.
    func warmUp() {
        guard !assetsReady, status == .idle else { return }
        let kind = backendKind
        Task { [weak self] in
            guard let self else { return }
            let locale = await Backends.resolveLocale(for: kind)
            do {
                try await self.backend.prepare(locale: locale) { _ in }
                // Guard against the engine being switched mid-load.
                if self.backendKind == kind {
                    self.assetsReady = true
                    NSLog("Murmur: \(kind.rawValue) model ready")
                    self.scheduleUnload()
                }
            } catch {
                NSLog("Murmur: warm-up failed — \(error.localizedDescription)")
            }
        }
    }

    /// Flash a message on screen. Used at launch so you can tell Murmur is
    /// alive even when the menu bar is full and its icon is hidden.
    func announce(_ message: String, seconds: Double = 4) {
        overlay.flash(.notice(message), seconds: seconds)
    }

    /// Creating the event tap needs Accessibility permission, which the user
    /// grants in System Settings while we're already running. Keep trying, so
    /// Murmur comes alive the moment they flip the switch — no relaunch.
    private func armHotkey() {
        hotkey.start()
        wasTrusted = TextInjector.isTrusted
        startTrustWatch()
    }

    /// Watches the Accessibility grant for the life of the app.
    ///
    /// Two cases to survive. Launching before the grant exists: keep retrying
    /// so Murmur wakes up the moment the switch is flipped, with no relaunch.
    /// And the grant being revoked and re-given while running: that kills the
    /// existing tap without telling us, so rebuild it on the transition rather
    /// than trusting `isRunning`.
    private func startTrustWatch() {
        guard trustWatch == nil else { return }
        trustWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }

                let trusted = TextInjector.isTrusted
                let regained = trusted && !self.wasTrusted
                self.wasTrusted = trusted

                if regained {
                    // Permission was just (re)granted — the old tap is dead.
                    self.hotkey.stop()
                    self.hotkey.start()
                    self.onStatusChange(self.status)
                } else if trusted && !self.hotkey.isRunning {
                    self.hotkey.start()
                    if self.hotkey.isRunning { self.onStatusChange(self.status) }
                }
            }
        }
    }

    /// Call after changing language or engine, so the right model gets loaded.
    func invalidateAssets() {
        assetsReady = false
        // Never swap the engine out from under a dictation in flight.
        guard status == .idle else { return }
        if backendKind != Settings.shared.backend {
            backendKind = Settings.shared.backend
            backend = Backends.make(backendKind)
            wirePartials()
        }
        warmUp()
    }

    private func wirePartials() {
        backend.onPartial = { [weak self] text in
            guard let self, self.status == .listening else { return }
            self.overlay.show(.listening(text: text, level: self.lastLevel))
        }
    }

    var isArmed: Bool { hotkey.isRunning }

    private var lastLevel: Float = 0
    private var maxLevel: Float = 0
    private var context: DictationContext?
    private var mode: HotkeyMonitor.Action = .dictate
    private var selection: String?

    // MARK: - Key routing

    /// Hold-to-talk and tap-to-toggle differ only in what a press means when
    /// something is already running.
    private func keyPressed(_ action: HotkeyMonitor.Action) {
        switch Settings.shared.activation {
        case .hold:
            beginDictation(mode: action)
        case .toggle:
            if status == .listening { endDictation() } else { beginDictation(mode: action) }
        }
    }

    private func keyReleased(_ action: HotkeyMonitor.Action) {
        // In toggle mode the release is meaningless; the next press ends it.
        guard Settings.shared.activation == .hold else { return }
        endDictation()
    }

    // MARK: - The loop

    private func beginDictation(mode: HotkeyMonitor.Action = .dictate) {
        let context = DictationContext.current()
        Log.write("key down (status=\(status), front app=\(context.appName) [\(context.kind.rawValue)])")
        guard status == .idle else { Log.write("  ignored — not idle"); return }
        idleUnload?.cancel()
        setStatus(.listening)
        startedAt = Date()
        lastLevel = 0
        captureStarted = false
        cancelled = false
        maxLevel = 0
        // Captured now, not at injection: this is the app you meant to talk to.
        self.context = context
        self.mode = mode
        self.selection = nil
        overlay.setPlaceholder(mode == .edit ? "Say what to do with the selection…" : "Listening…")
        overlay.show(.listening(text: "", level: 0))
        if Settings.shared.playSounds { NSSound(named: "Pop")?.play() }

        generation += 1
        let generation = self.generation

        if mode == .edit {
            Task { @MainActor in
                // Read the selection before the user starts talking — by the
                // time they finish, focus or selection may well have moved.
                selection = await TextInjector.copySelection()
                if selection == nil, status == .listening {
                    Log.write("  edit aborted — nothing selected")
                    setStatus(.idle)
                    overlay.flash(.notice("Select some text first"), seconds: 2)
                }
            }
        }

        Task { @MainActor in
            do {
                let locale = await Backends.resolveLocale(for: backendKind)
                guard generation == self.generation, status == .listening else { return }

                // A streaming engine needs its model before it can take audio.
                // A batch one can buffer while the model loads, so don't make
                // the user lose the sentence they're already saying.
                if backend.needsModelBeforeCapture, !assetsReady {
                    try await backend.prepare(locale: locale) { [weak self] message in
                        guard let self, self.status == .listening else { return }
                        self.overlay.show(.preparing(message))
                    }
                    assetsReady = true
                    guard generation == self.generation, status == .listening else { return }
                }

                try await backend.begin(locale: locale)
                guard generation == self.generation, status == .listening else {
                    _ = await backend.finish()
                    return
                }

                overlay.show(.listening(text: "", level: lastLevel))
                try audio.start { [weak self] buffer in
                    self?.backend.append(buffer)
                }
                captureStarted = true
                Log.write("  capture started (engine=\(backendKind.rawValue), locale=\(locale.identifier(.bcp47)))")

                // Finish loading in the background; finish() waits on it.
                if !assetsReady {
                    try await backend.prepare(locale: locale) { _ in }
                    if generation == self.generation { assetsReady = true }
                }
            } catch {
                guard generation == self.generation else { return }
                Log.write("  ERROR during start: \(error.localizedDescription)")
                await fail(error.localizedDescription)
            }
        }
    }

    private func endDictation() {
        Log.write("key up (status=\(status), captureStarted=\(captureStarted), peakLevel=\(String(format: "%.3f", maxLevel)))")
        guard status == .listening else { Log.write("  ignored — not listening"); return }
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        audio.stop()

        // Never got as far as recording — the model was still being fetched.
        guard captureStarted else {
            Log.write("  dropped — model was still loading")
            setStatus(.idle)
            overlay.flash(.notice("Still getting ready — try again in a moment"), seconds: 2.5)
            return
        }

        // A quick brush against the key isn't a dictation.
        guard duration >= Settings.shared.minimumHold else {
            Log.write("  dropped — held only \(String(format: "%.2f", duration))s")
            setStatus(.idle)
            overlay.show(.hidden)
            Task { _ = await backend.finish() }
            return
        }

        setStatus(.working)
        overlay.show(.working)
        let generation = self.generation

        Task {
            let raw = await backend.finish()
            guard generation == self.generation else { Log.write("  superseded"); return }
            Log.write("  transcript: \(raw.isEmpty ? "(EMPTY)" : "\(raw.count) chars — \(raw.prefix(60))")")
            guard !cancelled else { Log.write("  cancelled"); return }
            guard !raw.isEmpty else {
                setStatus(.idle)
                // Distinguish "you said nothing" from "the mic barely heard
                // you" — a low input volume looks identical otherwise, and
                // sends people hunting through the wrong settings.
                let tooQuiet = maxLevel < 0.08
                overlay.flash(.error(tooQuiet
                    ? "Too quiet — raise input volume in Sound settings"
                    : "Didn't catch that."), seconds: tooQuiet ? 3 : 1.4)
                Log.write(tooQuiet
                    ? "  nothing transcribed — input level only \(String(format: "%.3f", maxLevel))"
                    : "  nothing transcribed")
                return
            }

            var cleaned = raw
            let cleanupMode = Settings.shared.cleanup

            if self.mode == .edit {
                guard let selection else {
                    setStatus(.idle)
                    overlay.flash(.notice("Nothing was selected"), seconds: 2)
                    return
                }
                do {
                    cleaned = try await Cleanup.provider(for: cleanupMode)
                        .rewrite(selection, instruction: raw)
                    Log.write("  rewrote \(selection.count) chars → \(cleaned.count)")
                } catch {
                    // Unlike cleanup, there's no safe fallback here: pasting
                    // the raw instruction would destroy the selected text.
                    Log.write("  rewrite failed: \(error.localizedDescription)")
                    setStatus(.idle)
                    overlay.flash(.error(error.localizedDescription), seconds: 4)
                    return
                }
            } else if cleanupMode != .off {
                do {
                    let started = Date()
                    cleaned = try await Cleanup.provider(for: cleanupMode)
                        .clean(raw, vocabulary: Settings.shared.vocabulary, context: context)
                    Log.write(String(format: "  cleanup took %.1fs", Date().timeIntervalSince(started)))
                } catch {
                    // Cleanup is a nicety. Never lose the words over it.
                    Log.write("  cleanup failed, pasting raw — \(error.localizedDescription)")
                    cleaned = raw
                }
            }

            // Esc may have landed while the cleanup model was still thinking.
            guard !cancelled else { return }

            Stats.shared.record(text: cleaned, duration: duration)

            if Settings.shared.saveHistory {
                History.shared.add(Dictation(date: Date(), raw: raw, cleaned: cleaned, duration: duration))
            }

            setStatus(.idle)
            overlay.show(.hidden)
            Log.write("  injecting \(cleaned.count) chars")
            TextInjector.insert(cleaned)
            Log.write("  done")
            if Settings.shared.playSounds { NSSound(named: "Tink")?.play() }
        }
    }

    /// Esc while dictating: throw the audio away and type nothing.
    /// Returns whether we actually had something to cancel — if not, Esc is
    /// none of our business and must reach the app in front.
    private func cancelDictation() -> Bool {
        let wasListening = status == .listening
        guard wasListening || status == .working else { return false }

        cancelled = true
        generation += 1
        audio.stop()
        setStatus(.idle)
        overlay.flash(.notice("Cancelled"), seconds: 1.2)

        // If we were already working, endDictation's task owns the teardown —
        // calling finish() again would run Whisper's inference a second time.
        if wasListening {
            Task { _ = await backend.finish() }
        }
        return true
    }

    private func fail(_ message: String) async {
        audio.stop()
        _ = await backend.finish()
        setStatus(.idle)
        overlay.flash(.error(message), seconds: 3)
    }

    private func setStatus(_ new: Status) {
        status = new
        onStatusChange(new)
        // Every route back to idle schedules the unload — there are several
        // (empty transcript, too short a press, an error, Esc), and hanging it
        // off the happy path alone left the model resident after any of them.
        if case .idle = new { scheduleUnload() }
    }
}
