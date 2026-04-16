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

    // MARK: - Persistence

    private static let userDefaultsKey = "com.claudeheads.appSettings"

    private init() {
        // Set defaults before attempting to load
        self.defaultExtraArgs = ""
        self.terminalFontName = "Menlo"
        self.terminalFontSize = 12
        self.headSize = .medium
        self.snapDistance = 60
        self.launchAtLogin = false

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
    }

    private func save() {
        let stored = StoredSettings(
            defaultExtraArgs: defaultExtraArgs,
            terminalFontName: terminalFontName,
            terminalFontSize: terminalFontSize,
            headSize: headSize,
            snapDistance: snapDistance,
            launchAtLogin: launchAtLogin
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
}
