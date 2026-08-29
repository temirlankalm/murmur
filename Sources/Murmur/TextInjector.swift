import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Gets text into whatever app the user was typing in.
///
/// Two strategies. Accessibility insertion is cleaner (no pasteboard churn,
/// no ⌘V in the target's undo stack) but plenty of apps — Electron, terminals,
/// some Java UIs — either lie about their text fields or ignore writes. So we
/// try AX first and fall back to a pasteboard round-trip.
@MainActor
enum TextInjector {

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func insert(_ text: String, forcePasteboard: Bool = false) {
        guard !text.isEmpty else { return }

        let target = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"

        // Accessibility insertion is cleaner, but a lot of apps — Electron
        // ones especially — accept the write, report success and do nothing
        // with it. There's no reliable way to verify synchronously, so it's
        // off by default: the pasteboard round-trip actually works everywhere.
        if !forcePasteboard, Settings.shared.useAccessibilityInsert,
           insertViaAccessibility(text) {
            Log.write("  injected via Accessibility → \(target)")
            return
        }
        insertViaPasteboard(text)
        Log.write("  injected via clipboard paste → \(target)")
    }

    /// Some apps refuse synthetic keystrokes while secure input is on — a
    /// password field left focused somewhere will do it system-wide.
    static var isSecureInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }

    // MARK: - Accessibility

    private static func insertViaAccessibility(_ text: String) -> Bool {
        guard isTrusted else { return false }

        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused,
              // Don't take the API's word for it — a force cast here would be a
              // crash in whatever app happens to return something else.
              CFGetTypeID(element) == AXUIElementGetTypeID() else { return false }
        let target = element as! AXUIElement

        // Only trust this path for elements that actually claim to be text.
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(target, kAXRoleAttribute as CFString, &role)
        let roleName = role as? String
        guard roleName == kAXTextFieldRole || roleName == kAXTextAreaRole else { return false }

        // Writing to the selected-text attribute replaces the selection, which
        // for a collapsed caret means "type here" — exactly what we want.
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(target, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }

        return AXUIElementSetAttributeValue(target, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    // MARK: - Pasteboard

    private static func insertViaPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        pressCommandV()

        // Give the target app a beat to actually read the pasteboard before
        // we put the user's clipboard back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            restore(saved, to: pasteboard)
        }
    }

    /// Select everything in the focused field. Used by the diagnostics only —
    /// real voice editing works on whatever the user has already selected.
    static func selectAll() {
        press(virtualKey: 0) // kVK_ANSI_A
    }

    /// Copy whatever is selected in the frontmost app.
    ///
    /// There's no reliable Accessibility route for this — the same apps that
    /// won't accept an AX write won't report their selection either — so it's
    /// ⌘C and a short wait for the pasteboard to change. The clipboard is put
    /// back afterwards.
    static func copySelection(timeout: TimeInterval = 0.5) async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount

        press(virtualKey: 8) // kVK_ANSI_C

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pasteboard.changeCount != before {
                let text = pasteboard.string(forType: .string)
                restore(saved, to: pasteboard)
                return text?.isEmpty == false ? text : nil
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        restore(saved, to: pasteboard)
        Log.write("  copySelection: pasteboard never changed (front app=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))")
        return nil
    }

    private static func pressCommandV() {
        press(virtualKey: 9) // kVK_ANSI_V
    }

    private static func press(virtualKey: CGKeyCode) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        // Don't let a still-held modifier from the trigger key leak in.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[String: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var copy: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy[type.rawValue] = data
                }
            }
            return copy
        }
    }

    private static func restore(_ snapshot: [[String: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items: [NSPasteboardItem] = snapshot.map { stored in
            let item = NSPasteboardItem()
            for (type, data) in stored {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
