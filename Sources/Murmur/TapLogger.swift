import AppKit
import CoreGraphics

/// Diagnostic-only tap that records every modifier event, so we can see what
/// the system actually delivers when a key is pressed.
@MainActor
final class TapLogger {
    private(set) var events: [String] = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func start() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let logger = Unmanaged<TapLogger>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { logger.record(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func record(type: CGEventType, event: CGEvent) {
        guard type == .flagsChanged else { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        events.append("keycode \(code)  flags 0x\(String(event.flags.rawValue, radix: 16))")
    }
}
