import AppKit
import CoreGraphics

/// Watches for the dictation key being held down, system-wide.
///
/// This is a passive listening tap: we never swallow the event, so holding
/// right ⌥ still behaves normally in whatever app has focus.
@MainActor
final class HotkeyMonitor {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    /// Esc while dictating. Return true if it was consumed, so we can keep the
    /// keystroke from also reaching whatever app is in front.
    var onCancel: () -> Bool = { false }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    private static let modifierNames: [Int64: String] = [
        54: "Right ⌘", 55: "Left ⌘", 56: "Left ⇧", 57: "Caps Lock",
        58: "Left ⌥", 59: "Left ⌃", 60: "Right ⇧", 61: "Right ⌥",
        62: "Right ⌃", 63: "fn"
    ]

    var isRunning: Bool { tap != nil }

    func start() {
        guard tap == nil else { return }

        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            let swallow = MainActor.assumeIsolated {
                monitor.handle(type: type, event: event)
            }
            // Everything passes through untouched except an Esc we acted on.
            return swallow ? nil : Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Not listen-only: we need to be able to swallow the cancel key.
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Murmur: could not create event tap — Accessibility permission missing?")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.source = source
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        isDown = false
    }

    /// The tap gets disabled by the system if we ever stall. Re-arm it.
    func reenableIfNeeded(type: CGEventType) {
        guard type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Returns true if the event should be swallowed.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenableIfNeeded(type: type)
            return false
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyDown {
            guard keyCode == 53 else { return false } // kVK_Escape
            return onCancel()
        }

        guard type == .flagsChanged else { return false }

        let trigger = Settings.shared.trigger
        guard keyCode == trigger.keyCode else {
            // Log the near-misses too. When someone says the hotkey does
            // nothing, the usual answer is that they're pressing a different
            // key from the configured one, and this is the only way to see it.
            // Modifier keycodes only — no characters are recorded.
            if Self.modifierNames[keyCode] != nil {
                Log.write("modifier \(Self.modifierNames[keyCode] ?? "?") (keycode \(keyCode)) — trigger is \(trigger.label) (keycode \(trigger.keyCode))")
            }
            return false
        }

        // On a flagsChanged for our key, the flag being set means "pressed".
        let pressed = event.flags.contains(trigger.flag)
        guard pressed != isDown else { return false }
        isDown = pressed
        pressed ? onPress() : onRelease()
        return false
    }
}
