import AppKit
import SwiftTerm
import SwiftUI

// MARK: - TerminalPopover

/// SwiftUI view shown inside an NSPopover when a non-pinned head is tapped.
struct TerminalPopover: View {
    let head: HeadInstance
    var onPin: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TerminalViewWrapper(head: head)

            Button(action: onPin) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("Pin terminal window")
            .padding(8)
        }
        .frame(width: 600, height: 400)
    }
}

// MARK: - TerminalViewWrapper

/// Bridges SwiftTerm's AppKit `TerminalView` into SwiftUI via NSViewRepresentable.
/// Creates a terminal view paired with a `TerminalBridge` for PTY I/O.
struct TerminalViewWrapper: NSViewRepresentable {
    let head: HeadInstance

    final class Coordinator {
        var bridge: TerminalBridge?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TerminalView {
        let (view, bridge) = makeTerminalView()
        context.coordinator.bridge = bridge
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        // Future: update font if settings change at runtime
        let settings = AppSettings.shared
        if let font = NSFont(name: settings.terminalFontName, size: settings.terminalFontSize) {
            nsView.font = font
        }
    }
}
