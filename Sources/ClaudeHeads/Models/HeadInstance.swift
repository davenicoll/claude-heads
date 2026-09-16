import Foundation
import SwiftUI

// MARK: - HeadState

public enum HeadState: String, Codable, Sendable {
    case idle
    case running
    case finished
    case errored
}

// MARK: - BackgroundTask

/// One entry of the `background_tasks` array Claude Code includes in its `SubagentStop`
/// (and `Stop`) hook payloads: every background agent still known to the session.
/// `id` equals the `agent_id` of a subagent's own start/stop events; teammate entries
/// use unrelated ids and carry no `agent_type`.
public struct BackgroundTask: Hashable, Sendable {
    public let id: String
    /// The entry kind, e.g. `subagent` or `teammate`.
    public let type: String
    /// The short human description from the Agent call, if any.
    public let description: String?
    /// e.g. `running`.
    public let status: String
    /// The agent type of a `subagent` entry (`general-purpose`, `Explore`, ...); nil for teammates.
    public let agentType: String?

    public init(id: String, type: String, description: String?, status: String, agentType: String?) {
        self.id = id
        self.type = type
        self.description = description
        self.status = status
        self.agentType = agentType
    }

    public var isRunning: Bool { status == "running" }
    public var isSubagent: Bool { type == "subagent" }
}

// MARK: - SubagentInstance

/// A Claude Code subagent running under a head, reported by the SubagentStart hook.
/// Rendered as a small head orbiting its parent. Runtime-only, never persisted.
public struct SubagentInstance: Identifiable, Hashable, Sendable {
    /// The `agent_id` from the hook payload.
    public let id: String
    /// The `agent_type` from the hook payload (e.g. `Explore`, `general-purpose`). Claude
    /// Code sometimes sends the agent's name instead, and sometimes an empty string.
    public var type: String
    /// The task description from the Agent call, learned from a `background_tasks` list.
    public var description: String?
    public let startedAt: Date

    public init(id: String, type: String, description: String? = nil, startedAt: Date = Date()) {
        self.id = id
        self.type = type
        self.description = description
        self.startedAt = startedAt
    }

    /// Longest caption shown on the orbiting head before it is cut with an ellipsis.
    public static let labelLimit = 24

    /// The trimmed description, or nil when there is none worth showing.
    public var trimmedDescription: String? {
        guard let description else { return nil }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var trimmedType: String { type.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Short caption for the orbiting head: the description (truncated to `labelLimit`
    /// characters), else the agent type, else the first 8 characters of the agent id.
    public var label: String {
        if let description = trimmedDescription {
            return Self.truncate(description, to: Self.labelLimit)
        }
        if !trimmedType.isEmpty {
            return trimmedType
        }
        return String(id.prefix(8))
    }

    /// Tooltip text: the label, plus the untruncated description and the full agent type
    /// on their own lines whenever they add something the label does not already say.
    public var tooltip: String {
        var lines = [label]
        if let description = trimmedDescription, description != label {
            lines.append(description)
        }
        if !trimmedType.isEmpty, trimmedType != label {
            lines.append("Type: \(trimmedType)")
        }
        return lines.joined(separator: "\n")
    }

    /// Seed for the head's colour: the agent type when known (so every agent of one kind
    /// shares a colour), otherwise the label.
    public var colorKey: String {
        "subagent:" + (trimmedType.isEmpty ? label : trimmedType).lowercased()
    }

    /// Cuts `text` to at most `limit` characters (grapheme clusters), replacing the tail
    /// with a single ellipsis when it had to cut.
    public static func truncate(_ text: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces)
        return head + "\u{2026}"
    }

    /// Merges a `background_tasks` list into a head's children, preserving their order.
    ///
    /// Existing children matched by id pick up a non-empty `agent_type` and description;
    /// running `subagent` entries not yet known are appended (e.g. started before the app
    /// launched, or whose start marker was lost). Nothing is removed: on its own the list
    /// is only positive evidence, and teammate entries do not share ids with subagent
    /// events. Returns `children` unchanged (same array) when there is nothing to apply.
    public static func merging(_ children: [SubagentInstance], with tasks: [BackgroundTask]) -> [SubagentInstance] {
        var result = children
        var seen = Set<String>()
        var changed = false

        for task in tasks where !task.id.isEmpty && !seen.contains(task.id) {
            seen.insert(task.id)
            let type = task.agentType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let description = task.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if let index = result.firstIndex(where: { $0.id == task.id }) {
                if !type.isEmpty, result[index].type != type {
                    result[index].type = type
                    changed = true
                }
                if !description.isEmpty, result[index].description != description {
                    result[index].description = description
                    changed = true
                }
            } else if task.isSubagent, task.isRunning {
                result.append(SubagentInstance(
                    id: task.id,
                    type: type,
                    description: description.isEmpty ? nil : description
                ))
                changed = true
            }
        }
        return changed ? result : children
    }

    /// Reconciles a head's children when the parent's `Stop` hook fires.
    ///
    /// Stop fires at the end of every assistant turn while background agents keep running
    /// across turns, so it must not clear the ring. With a `background_tasks` list the
    /// list is authoritative: listed running entries are merged in (see `merging`) and
    /// every child not listed as running is removed. Without a list (`nil`) nothing
    /// changes; children then only leave on their own `SubagentStop`.
    public static func reconciling(
        _ children: [SubagentInstance],
        withStopTasks tasks: [BackgroundTask]?
    ) -> [SubagentInstance] {
        guard let tasks else { return children }
        let running = Set(tasks.filter(\.isRunning).map(\.id))
        return merging(children, with: tasks).filter { running.contains($0.id) }
    }
}

// MARK: - HeadInstance

@Observable
public final class HeadInstance: Identifiable {
    public let id: UUID
    public var name: String
    public var folderPath: String
    public var extraArgs: [String]
    public var avatarImageData: Data?
    public var position: CGPoint
    public var screenID: UInt32
    public var isPinned: Bool
    public var state: HeadState
    public var isWaving: Bool
    public var snapGroupID: UUID?

    // Non-persisted runtime state
    public var processID: pid_t?
    /// Subagents currently running under this head (SubagentStart .. SubagentStop).
    public var children: [SubagentInstance]

    public init(
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
        processID: pid_t? = nil,
        children: [SubagentInstance] = []
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
        self.children = children
    }
}

// MARK: - Codable

extension HeadInstance: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, folderPath, extraArgs, avatarImageData
        case position, screenID, isPinned, state, isWaving, snapGroupID
    }

    public convenience init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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
    public static func == (lhs: HeadInstance, rhs: HeadInstance) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
