import Foundation
import SwiftUI

// MARK: - HeadState

enum HeadState: String, Codable, Sendable {
    case idle
    case running
    case finished
    case errored
}

// MARK: - HeadInstance

@Observable
final class HeadInstance: Identifiable {
    let id: UUID
    var name: String
    var folderPath: String
    var extraArgs: [String]
    var avatarImageData: Data?
    var position: CGPoint
    var screenID: UInt32
    var isPinned: Bool
    var state: HeadState
    var isWaving: Bool
    var snapGroupID: UUID?

    // Non-persisted runtime state
    var processID: pid_t?

    init(
        id: UUID = UUID(),
        name: String,
        folderPath: String,
        extraArgs: [String] = [],
        avatarImageData: Data? = nil,
        position: CGPoint = .zero,
        screenID: UInt32 = 0,
        isPinned: Bool = false,
        state: HeadState = .idle,
        isWaving: Bool = false,
        snapGroupID: UUID? = nil,
        processID: pid_t? = nil
    ) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
        self.extraArgs = extraArgs
        self.avatarImageData = avatarImageData
        self.position = position
        self.screenID = screenID
        self.isPinned = isPinned
        self.state = state
        self.isWaving = isWaving
        self.snapGroupID = snapGroupID
        self.processID = processID
    }
}

// MARK: - Codable

extension HeadInstance: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, folderPath, extraArgs, avatarImageData
        case position, screenID, isPinned, state, isWaving, snapGroupID
    }

    convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            folderPath: try container.decode(String.self, forKey: .folderPath),
            extraArgs: try container.decodeIfPresent([String].self, forKey: .extraArgs) ?? [],
            avatarImageData: try container.decodeIfPresent(Data.self, forKey: .avatarImageData),
            position: try container.decode(CGPoint.self, forKey: .position),
            screenID: try container.decode(UInt32.self, forKey: .screenID),
            isPinned: try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false,
            state: try container.decodeIfPresent(HeadState.self, forKey: .state) ?? .idle,
            isWaving: try container.decodeIfPresent(Bool.self, forKey: .isWaving) ?? false,
            snapGroupID: try container.decodeIfPresent(UUID.self, forKey: .snapGroupID)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(folderPath, forKey: .folderPath)
        try container.encode(extraArgs, forKey: .extraArgs)
        try container.encodeIfPresent(avatarImageData, forKey: .avatarImageData)
        try container.encode(position, forKey: .position)
        try container.encode(screenID, forKey: .screenID)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(state, forKey: .state)
        try container.encode(isWaving, forKey: .isWaving)
        try container.encodeIfPresent(snapGroupID, forKey: .snapGroupID)
    }
}

// MARK: - Hashable / Equatable

extension HeadInstance: Hashable {
    static func == (lhs: HeadInstance, rhs: HeadInstance) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
