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
        var args: [String] = []
        if claudeContinue { args.append("--continue") }
        if claudeSkipPermissions { args.append("--dangerously-skip-permissions") }
        if claudeRemoteControl { args.append("--remote-control") }
        let extra = defaultExtraArgs.trimmingCharacters(in: .whitespaces)
        if !extra.isEmpty {
            args.append(contentsOf: extra.components(separatedBy: .whitespaces).filter { !$0.isEmpty })
        }
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

private struct StoredSettings: Codable {
    let defaultExtraArgs: String
    let terminalFontName: String
    let terminalFontSize: CGFloat
    let headSize: HeadSize
    let snapDistance: CGFloat
    let launchAtLogin: Bool
    let showStatusIndicator: Bool?
    let claudeContinue: Bool?
    let claudeSkipPermissions: Bool?
    let claudeRemoteControl: Bool?
}
