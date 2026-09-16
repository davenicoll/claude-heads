import Foundation
import SwiftUI

// MARK: - HeadSize

enum HeadSize: String, Codable, CaseIterable, Sendable {
    case small
    case medium
    case large

    var diameter: CGFloat {
        switch self {
        case .small: 40
        case .medium: 60
        case .large: 80
        }
    }
}

// MARK: - AppSettings

@Observable
final class AppSettings {
    static let shared = AppSettings()

    var defaultExtraArgs: String {
        didSet { save() }
    }

    var terminalFontName: String {
        didSet { save() }
    }

    var terminalFontSize: CGFloat {
        didSet { save() }
    }

    var headSize: HeadSize {
        didSet { save() }
    }

    var snapDistance: CGFloat {
        didSet { save() }
    }

    var launchAtLogin: Bool {
        didSet { save() }
    }

    var showStatusIndicator: Bool {
        didSet { save() }
    }

    /// Draw a head's running Claude Code subagents as small heads orbiting it. Children are
    /// tracked regardless so turning this back on shows the current subagents immediately.
    var showSubagentChildren: Bool {
        didSet { save() }
    }

    var claudeContinue: Bool {
        didSet { save() }
    }

    var claudeSkipPermissions: Bool {
        didSet { save() }
    }

    var claudeRemoteControl: Bool {
        didSet { save() }
    }

    /// Builds the CLI arguments from settings flags + extra args
    var effectiveCLIArgs: [String] {
        Self.cliArguments(
            continue: claudeContinue,
            skipPermissions: claudeSkipPermissions,
            remoteControl: claudeRemoteControl,
            extraArgs: defaultExtraArgs
        )
    }

    /// Pure form of `effectiveCLIArgs`. `extraArgs` is split like a shell command line, so
    /// quoted arguments containing spaces survive as single argv entries.
    static func cliArguments(
        continue wantsContinue: Bool,
        skipPermissions: Bool,
        remoteControl: Bool,
        extraArgs: String
    ) -> [String] {
        var args: [String] = []
        if wantsContinue { args.append("--continue") }
        if skipPermissions { args.append("--dangerously-skip-permissions") }
        if remoteControl { args.append("--remote-control") }
        args.append(contentsOf: ShellWords.split(extraArgs))
        return args
    }

    // MARK: - Persistence

    private static let userDefaultsKey = "com.claudeheads.appSettings"

    private init() {
        self.defaultExtraArgs = ""
        self.terminalFontName = "Menlo"
        self.terminalFontSize = 12
        self.headSize = .medium
        self.snapDistance = 60
        self.launchAtLogin = false
        self.showStatusIndicator = false
        self.showSubagentChildren = true
        self.claudeContinue = true
        self.claudeSkipPermissions = false
        self.claudeRemoteControl = false

        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey),
              let stored = try? JSONDecoder().decode(StoredSettings.self, from: data)
        else { return }

        defaultExtraArgs = stored.defaultExtraArgs
        terminalFontName = stored.terminalFontName
        terminalFontSize = stored.terminalFontSize
        headSize = stored.headSize
        snapDistance = stored.snapDistance
        launchAtLogin = stored.launchAtLogin
        showStatusIndicator = stored.showStatusIndicator ?? false
        showSubagentChildren = stored.showSubagentChildren ?? true
        claudeContinue = stored.claudeContinue ?? true
        claudeSkipPermissions = stored.claudeSkipPermissions ?? false
        claudeRemoteControl = stored.claudeRemoteControl ?? false
    }

    private func save() {
        let stored = StoredSettings(
            defaultExtraArgs: defaultExtraArgs,
            terminalFontName: terminalFontName,
            terminalFontSize: terminalFontSize,
            headSize: headSize,
            snapDistance: snapDistance,
            launchAtLogin: launchAtLogin,
            showStatusIndicator: showStatusIndicator,
            showSubagentChildren: showSubagentChildren,
            claudeContinue: claudeContinue,
            claudeSkipPermissions: claudeSkipPermissions,
            claudeRemoteControl: claudeRemoteControl
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }
}

// MARK: - StoredSettings (Codable DTO)

/// Every field added after the first release is optional so settings written by an older
/// build still decode; `AppSettings.load()` supplies the default for a missing key.
struct StoredSettings: Codable {
    let defaultExtraArgs: String
    let terminalFontName: String
    let terminalFontSize: CGFloat
    let headSize: HeadSize
    let snapDistance: CGFloat
    let launchAtLogin: Bool
    let showStatusIndicator: Bool?
    let showSubagentChildren: Bool?
    let claudeContinue: Bool?
    let claudeSkipPermissions: Bool?
    let claudeRemoteControl: Bool?
}

// MARK: - ShellWords

/// Minimal POSIX-style word splitter for the "extra arguments" text field.
///
/// Supports whitespace separation, single quotes (literal), double quotes (with `\` escaping
/// `"`, `\`, `$` and backtick), and backslash escapes outside quotes. No expansion is performed.
/// An unterminated quote runs to the end of the string rather than being an error.
enum ShellWords {
    static func split(_ input: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var iterator = input.makeIterator()

        while let ch = iterator.next() {
            switch ch {
            case " ", "\t", "\n", "\r":
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            case "\\":
                inWord = true
                if let next = iterator.next() {
                    if next != "\n" { current.append(next) }
                } else {
                    // A dangling trailing backslash is literal, matching /bin/sh.
                    current.append("\\")
                }
            case "'":
                inWord = true
                while let next = iterator.next(), next != "'" {
                    current.append(next)
                }
            case "\"":
                inWord = true
                while let next = iterator.next(), next != "\"" {
                    guard next == "\\" else {
                        current.append(next)
                        continue
                    }
                    guard let escaped = iterator.next() else { break }
                    switch escaped {
                    case "\"", "\\", "$", "`":
                        current.append(escaped)
                    case "\n":
                        break
                    default:
                        current.append("\\")
                        current.append(escaped)
                    }
                }
            default:
                inWord = true
                current.append(ch)
            }
        }

        if inWord { words.append(current) }
        return words
    }
}
