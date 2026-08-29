import AppKit
import SwiftUI

enum OverlayState: Equatable {
    case hidden
    case listening(text: String, level: Float)
    case preparing(String)
    case working
    /// A transient message with no work behind it — "Cancelled", and friends.
    case notice(String)
    case error(String)
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var state: OverlayState = .hidden
}

/// The little pill that floats above everything while you're dictating.
/// Non-activating, so the app you're typing into never loses focus.
@MainActor
final class Overlay {
    private let model = OverlayModel()
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(_ state: OverlayState) {
        dismissTask?.cancel()
        model.state = state

        if case .hidden = state {
            panel?.orderOut(nil)
            return
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    /// Show something briefly, then fade out on its own.
    func flash(_ state: OverlayState, seconds: Double = 2.2) {
        show(state)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.show(.hidden)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
        return panel
    }

    private func position(_ panel: NSPanel) {
        // The screen under the pointer, not NSScreen.main — on a multi-display
        // setup "main" is wherever the menu bar lives, which may not be where
        // the user is typing.
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let screen else { return }
        panel.setContentSize(NSSize(width: 380, height: 56))
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 90
        )
        panel.setFrameOrigin(origin)
    }
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 12) {
            icon
            content
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .animation(.easeOut(duration: 0.18), value: model.state)
    }

    @ViewBuilder
    private var icon: some View {
        switch model.state {
        case .listening(_, let level):
            Waveform(level: level)
        case .working, .preparing:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
                .frame(width: 22)
        case .notice:
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
                .frame(width: 22)
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .listening(let text, _):
            Text(text.isEmpty ? "Listening…" : text)
                .font(.system(size: 13))
                .foregroundStyle(text.isEmpty ? .white.opacity(0.55) : .white)
                .lineLimit(1)
                .truncationMode(.head)
        case .working:
            Text("Cleaning up…")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
        case .preparing(let message):
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        case .notice(let message):
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        case .error(let message):
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .lineLimit(2)
        case .hidden:
            EmptyView()
        }
    }
}

/// Five bars that lean on the mic level. Cheap, but it reads as "live".
private struct Waveform: View {
    let level: Float
    private let weights: [Float] = [0.45, 0.8, 1.0, 0.7, 0.4]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(.white)
                    .frame(width: 2.5, height: height(for: weights[i]))
            }
        }
        .frame(width: 22, height: 24)
        .animation(.easeOut(duration: 0.09), value: level)
    }

    private func height(for weight: Float) -> CGFloat {
        let base: Float = 3
        return CGFloat(base + weight * level * 21)
    }
}
