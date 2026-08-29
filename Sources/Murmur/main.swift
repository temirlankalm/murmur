import AppKit

func flagValue(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name),
          CommandLine.arguments.indices.contains(i + 1) else { return nil }
    return CommandLine.arguments[i + 1]
}

if let path = flagValue("--transcribe") {
    Task {
        await Diagnostics.transcribe(path: path,
                                     model: flagValue("--model"),
                                     language: flagValue("--language"))
        exit(0)
    }
    dispatchMain()
}

if let text = flagValue("--paste") {
    let delay = Double(flagValue("--delay") ?? "") ?? 4
    Task { await Diagnostics.testPaste(text, delay: delay); exit(0) }
    dispatchMain()
}

// These two drive a CFRunLoop directly — see Diagnostics.watchKeys.
if CommandLine.arguments.contains("--press") {
    let seconds = Double(flagValue("--press") ?? "") ?? 5
    MainActor.assumeIsolated { Diagnostics.pressTrigger(seconds: seconds) }
    exit(0)
}

if CommandLine.arguments.contains("--watch-keys") {
    let seconds = Double(flagValue("--watch-keys") ?? "") ?? 10
    MainActor.assumeIsolated { Diagnostics.watchKeys(seconds: seconds) }
    exit(0)
}

if CommandLine.arguments.contains("--test-hotkey") {
    MainActor.assumeIsolated { Diagnostics.testHotkey() }
    exit(0)
}

if CommandLine.arguments.contains("--dictate") {
    let seconds = Double(flagValue("--dictate") ?? "") ?? 5
    Task { @MainActor in await Diagnostics.selfTestCapture(seconds: seconds); exit(0) }
    dispatchMain()
}

if CommandLine.arguments.contains("--focus") {
    let delay = Double(flagValue("--focus") ?? "") ?? 4
    Task { await Diagnostics.inspectFocus(after: delay); exit(0) }
    dispatchMain()
}

if let instruction = flagValue("--test-edit") {
    let delay = Double(flagValue("--delay") ?? "") ?? 4
    Task { @MainActor in await Diagnostics.testEdit(instruction, delay: delay); exit(0) }
    dispatchMain()
}

if CommandLine.arguments.contains("--test-cleanup") {
    Task { @MainActor in await Diagnostics.testCleanup(); exit(0) }
    dispatchMain()
}

if CommandLine.arguments.contains("--models") {
    Task { @MainActor in Diagnostics.listModels(); exit(0) }
    dispatchMain()
}

if CommandLine.arguments.contains("--check") {
    // dispatchMain, not a semaphore: diagnostics hops to the main actor, so
    // blocking this thread would deadlock it.
    Task { await Diagnostics.run(); exit(0) }
    dispatchMain()
}

// Menu-bar only: no Dock icon, no main window.
// Top-level code isn't main-actor isolated, but by construction it is the
// main thread, so assert that once here rather than sprinkling hops around.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let delegate = AppDelegate()
    app.delegate = delegate
    // NSApplication holds its delegate weakly; this keeps ours alive.
    objc_setAssociatedObject(app, Unmanaged.passUnretained(app).toOpaque(), delegate, .OBJC_ASSOCIATION_RETAIN)

    app.run()
}
