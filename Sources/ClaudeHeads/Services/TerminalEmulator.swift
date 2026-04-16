import AppKit
import CPTYHelpers
import Foundation
import SwiftTerm

// MARK: - TerminalBridge

/// Bridges a SwiftTerm `TerminalView` to a PTY master file descriptor, forwarding user
/// keystrokes to the child process and relaying size changes via TIOCSWINSZ / SIGWINCH.
final class TerminalBridge: NSObject, TerminalViewDelegate {

    /// The master side of the PTY. Set by `ProcessManager` after forking.
    var masterFD: Int32 = -1

    /// The child PID, used for sending SIGWINCH on size changes.
    var childPID: pid_t = -1

    /// Optional callback when the terminal title changes.
    var onTitleChange: ((String) -> Void)?

    /// Optional callback when the current directory changes (OSC 7).
    var onDirectoryChange: ((String?) -> Void)?

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard masterFD >= 0 else { return }

        let bytes = Array(data)
        bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var totalWritten = 0
            while totalWritten < bytes.count {
                let written = write(
                    masterFD,
                    baseAddress.advanced(by: totalWritten),
                    bytes.count - totalWritten
                )
                if written < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    break
                }
                totalWritten += written
            }
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard masterFD >= 0, newCols > 0, newRows > 0 else { return }

        // Update the PTY window size via C helper (ioctl is unavailable in Swift)
        pty_set_window_size(masterFD, UInt16(newRows), UInt16(newCols))

        // Notify the child process of the size change
        if childPID > 0 {
            kill(childPID, SIGWINCH)
        }
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        onTitleChange?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        onDirectoryChange?(directory)
    }

    func scrolled(source: TerminalView, position: Double) {
        // No-op: scrollback is handled by SwiftTerm internally.
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    func bell(source: TerminalView) {
        NSSound.beep()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let string = String(data: content, encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        // Not used.
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        // Visual update notifications; SwiftTerm handles redrawing.
    }
}

// MARK: - Terminal View Factory

/// Creates and configures a `TerminalView` with its companion `TerminalBridge`.
///
/// - Parameters:
///   - frame: The initial frame for the terminal view.
///   - settings: App settings used for font configuration.
/// - Returns: A tuple of the configured `TerminalView` and its `TerminalBridge`.
func makeTerminalView(
    frame: NSRect = NSRect(x: 0, y: 0, width: 600, height: 400),
    settings: AppSettings = .shared
) -> (view: TerminalView, bridge: TerminalBridge) {
    let terminalView = TerminalView(frame: frame)
    let bridge = TerminalBridge()

    // Configure font from app settings
    if let font = NSFont(name: settings.terminalFontName, size: settings.terminalFontSize) {
        terminalView.font = font
    } else {
        // Fallback to system monospaced font
        terminalView.font = NSFont.monospacedSystemFont(
            ofSize: settings.terminalFontSize,
            weight: .regular
        )
    }

    terminalView.terminalDelegate = bridge

    return (terminalView, bridge)
}
