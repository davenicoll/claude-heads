import Foundation

// MARK: - HookSettingsMerge

/// Pure text transformations on the contents of `~/.claude/settings.json` that add or
/// remove the Claude Heads hook entries while leaving every other byte of the file alone.
///
/// The file is committed to a git repository by many users, so it is never round-tripped
/// through `JSONSerialization` for writing (that would reorder keys and reformat). Instead
/// the text is scanned into a tree of byte ranges, `JSONSerialization` is used only to
/// decode individual string tokens and to validate, and the edit is a minimal splice:
///
/// - Install: the missing event entries are inserted immediately after the opening brace
///   of the top-level `"hooks"` object (or a whole `"hooks"` block after the file's opening
///   brace when there is none), formatted with the file's own indentation unit.
/// - Uninstall: exactly the command entries whose path ends in `.claude-heads/hooks/notify.sh`
///   are removed, together with the comma that joined them; a matcher group, event array or
///   the `"hooks"` object that we emptied is removed too, so installing and then uninstalling
///   gives back the original bytes.
///
/// Every result is re-parsed and compared against the original (minus our entries) before
/// it is returned, so a scanner bug can only ever produce a refusal, never a corrupt file.
enum HookSettingsMerge {

    /// The Claude Code hook events Claude Heads listens for, in the order they are inserted.
    static let events = ["Stop", "SubagentStart", "SubagentStop"]

    /// Any command whose path ends with this is treated as ours, whatever the home directory.
    static let scriptPathSuffix = ".claude-heads/hooks/notify.sh"

    /// Seconds Claude Code gives `notify.sh` before killing it.
    static let commandTimeout = 5

    enum Failure: Error, Equatable, CustomStringConvertible {
        case invalidJSON(String)
        case notAnObject
        case hooksNotAnObject
        case eventNotAnArray(String)
        case resultInvalid(String)

        var description: String {
            switch self {
            case .invalidJSON(let detail): "settings.json is not valid JSON (\(detail))"
            case .notAnObject: "settings.json does not contain a top-level object"
            case .hooksNotAnObject: "\"hooks\" is not an object"
            case .eventNotAnArray(let event): "\"hooks\".\"\(event)\" is not an array"
            case .resultInvalid(let detail): "refusing to write: \(detail)"
            }
        }
    }

    /// Returns the text with our entries present for every event. Unchanged text (returned
    /// as an identical string) means nothing needed doing.
    static func install(into text: String, scriptPath: String) -> Result<String, Failure> {
        var bytes = Array(text.utf8)
        let original = bytes
        let style = Style(detectingFrom: bytes)

        do {
            var missing = try eventsMissing(in: bytes)
            guard !missing.isEmpty else { return .success(text) }

            var doc = try Document(bytes)
            // 1. No "hooks" key at all: one block with every event, right after the root brace.
            guard let hooks = doc.hooksMember else {
                bytes = insert(into: doc.root, of: bytes, style: style) { depth in
                    style.hooksMember(events: missing, scriptPath: scriptPath, depth: depth)
                }
                try validateInstall(original: original, result: bytes)
                return .success(String(decoding: bytes, as: UTF8.self))
            }
            guard case .object(_, let hookMembers) = hooks.value else { throw Failure.hooksNotAnObject }

            // 2. Events that already have an array (without us): add a matcher group to each.
            //    Done first so the offsets of the "hooks" object are still valid afterwards.
            let existingArrays = Set(hookMembers.map(\.key))
            for event in missing where existingArrays.contains(event) {
                doc = try Document(bytes)
                guard let hooksValue = doc.hooksMember?.value,
                      case .object(_, let members) = hooksValue,
                      let member = members.last(where: { $0.key == event }) else { continue }
                guard case .array = member.value else { throw Failure.eventNotAnArray(event) }
                bytes = insert(into: member.value, of: bytes, style: style) { depth in
                    style.matcherGroup(scriptPath: scriptPath, depth: depth)
                }
            }
            missing.removeAll(where: existingArrays.contains)

            // 3. Events with no key yet: one block right after the "hooks" opening brace.
            if !missing.isEmpty {
                doc = try Document(bytes)
                guard let hooksValue = doc.hooksMember?.value else { throw Failure.hooksNotAnObject }
                bytes = insert(into: hooksValue, of: bytes, style: style) { depth in
                    style.eventMembers(missing, scriptPath: scriptPath, depth: depth)
                }
            }

            try validateInstall(original: original, result: bytes)
            return .success(String(decoding: bytes, as: UTF8.self))
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.invalidJSON(error.localizedDescription))
        }
    }

    /// Returns the text with every entry of ours removed. Unchanged text means there was
    /// nothing of ours in the file.
    static func uninstall(from text: String) -> Result<String, Failure> {
        var bytes = Array(text.utf8)
        let original = bytes

        do {
            try validateJSON(bytes)
            // Containers we emptied ourselves. Pre-existing empty arrays/objects are left alone.
            var emptiedGroups = Set<[Int]>()      // paths as [eventIndex, groupIndex]
            var emptiedEvents = Set<String>()
            var emptiedHooks = false

            // Each pass makes one splice and rescans, so no offset bookkeeping is needed.
            while true {
                let doc = try Document(bytes)
                guard let hooks = doc.hooksMember else { break }
                guard case .object(_, let hookMembers) = hooks.value else {
                    if original == bytes { throw Failure.hooksNotAnObject }
                    break
                }

                var edit: Range<Int>?
                search: for (eventIndex, member) in hookMembers.enumerated() where events.contains(member.key) {
                    guard case .array(_, let groups) = member.value else {
                        throw Failure.eventNotAnArray(member.key)
                    }
                    for (groupIndex, group) in groups.enumerated() {
                        guard case .object(_, let groupMembers) = group,
                              let inner = groupMembers.last(where: { $0.key == "hooks" }),
                              case .array(_, let commands) = inner.value else { continue }
                        for (commandIndex, command) in commands.enumerated() where isOurs(command, in: bytes) {
                            edit = removalRange(of: commandIndex, in: inner.value, itemRanges: commands.map(\.range))
                            if commands.count == 1 { emptiedGroups.insert([eventIndex, groupIndex]) }
                            break search
                        }
                        if commands.isEmpty, emptiedGroups.contains([eventIndex, groupIndex]) {
                            // Group whose only command was ours: remove the whole group.
                            edit = removalRange(of: groupIndex, in: member.value, itemRanges: groups.map(\.range))
                            emptiedGroups.remove([eventIndex, groupIndex])
                            if groups.count == 1 { emptiedEvents.insert(member.key) }
                            break search
                        }
                    }
                    if groups.isEmpty, emptiedEvents.contains(member.key) {
                        edit = removalRange(of: eventIndex, in: hooks.value, itemRanges: hookMembers.map(\.range))
                        emptiedEvents.remove(member.key)
                        if hookMembers.count == 1 { emptiedHooks = true }
                        break search
                    }
                }

                if edit == nil, hookMembers.isEmpty, emptiedHooks {
                    if let index = doc.rootMembers.lastIndex(where: { $0.key == "hooks" }) {
                        edit = removalRange(of: index, in: doc.root, itemRanges: doc.rootMembers.map(\.range))
                    }
                    emptiedHooks = false
                }

                guard let edit else { break }
                bytes.removeSubrange(edit)
            }

            if bytes == original { return .success(text) }
            try validateUninstall(original: original, result: bytes)
            return .success(String(decoding: bytes, as: UTF8.self))
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.invalidJSON(error.localizedDescription))
        }
    }

    /// The events (of `events`) that have no entry of ours in `text`.
    static func missingEvents(in text: String) -> Result<[String], Failure> {
        do {
            return .success(try eventsMissing(in: Array(text.utf8)))
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.invalidJSON(error.localizedDescription))
        }
    }

    // MARK: Inspection (JSONSerialization)

    /// Parses with `JSONSerialization` for the values and with `Document` for strictness:
    /// Foundation tolerates trailing commas, which Claude Code's parser does not, so a file
    /// only counts as valid when both accept it.
    private static func parseObject(_ bytes: [UInt8]) throws -> [String: Any] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(bytes))
        } catch {
            throw Failure.invalidJSON((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
                ?? error.localizedDescription)
        }
        guard let dict = object as? [String: Any] else { throw Failure.notAnObject }
        _ = try Document(bytes)
        return dict
    }

    private static func validateJSON(_ bytes: [UInt8]) throws {
        _ = try parseObject(bytes)
    }

    private static func eventsMissing(in bytes: [UInt8]) throws -> [String] {
        let root = try parseObject(bytes)
        guard let hooksAny = root["hooks"] else { return events }
        guard let hooks = hooksAny as? [String: Any] else { throw Failure.hooksNotAnObject }
        return try events.filter { event in
            guard let value = hooks[event] else { return true }
            guard let groups = value as? [Any] else { throw Failure.eventNotAnArray(event) }
            return !groups.contains { group in
                guard let group = group as? [String: Any],
                      let commands = group["hooks"] as? [Any] else { return false }
                return commands.contains { isOurs(command: ($0 as? [String: Any])?["command"]) }
            }
        }
    }

    /// True when a parsed command entry's `command` string is a path to our script.
    static func isOurs(command: Any?) -> Bool {
        guard let command = command as? String else { return false }
        let trimmed = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return trimmed.hasSuffix(scriptPathSuffix)
    }

    private static func isOurs(_ node: Node, in bytes: [UInt8]) -> Bool {
        guard case .object(_, let members) = node,
              let command = members.last(where: { $0.key == "command" }),
              case .scalar(let range) = command.value else { return false }
        return isOurs(command: try? JSONSerialization.jsonObject(
            with: Data(bytes[range]), options: .fragmentsAllowed))
    }

    /// `object` with every entry of ours (and any container that emptied as a result) removed.
    /// Used to prove an edit touched nothing else.
    static func strippedOfOurHooks(_ object: [String: Any]) -> [String: Any] {
        var root = object
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for event in events {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups = groups.compactMap { group in
                guard var commands = group["hooks"] as? [[String: Any]] else { return group }
                let before = commands.count
                commands.removeAll { isOurs(command: $0["command"]) }
                if commands.isEmpty, before > 0 { return nil }
                var group = group
                group["hooks"] = commands
                return group
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return root
    }

    private static func validateInstall(original: [UInt8], result: [UInt8]) throws {
        let missing: [String]
        do {
            missing = try eventsMissing(in: result)
        } catch {
            throw Failure.resultInvalid("\(error)")
        }
        guard missing.isEmpty else {
            throw Failure.resultInvalid("still missing \(missing.joined(separator: ", "))")
        }
        try validateOthersUnchanged(original: original, result: result)
    }

    private static func validateUninstall(original: [UInt8], result: [UInt8]) throws {
        let missing: [String]
        do {
            missing = try eventsMissing(in: result)
        } catch {
            throw Failure.resultInvalid("\(error)")
        }
        guard missing == events else {
            throw Failure.resultInvalid("entries survived removal")
        }
        try validateOthersUnchanged(original: original, result: result)
    }

    private static func validateOthersUnchanged(original: [UInt8], result: [UInt8]) throws {
        let before = strippedOfOurHooks(try parseObject(original))
        let after = strippedOfOurHooks(try parseObject(result))
        guard NSDictionary(dictionary: before).isEqual(to: after) else {
            throw Failure.resultInvalid("other settings would change")
        }
    }

    // MARK: Splicing

    /// Inserts the members/elements produced by `body` (given the container's nesting depth;
    /// already joined with commas and indented for depth + 1, no leading or trailing newline)
    /// as the first item(s) of `container`.
    private static func insert(into container: Node, of bytes: [UInt8], style: Style, body: (Int) -> String) -> [UInt8] {
        let range = container.range
        let depth = style.depth(of: range.lowerBound, in: bytes)
        let body = body(depth)
        var out = bytes
        if container.isEmpty {
            // "{}" -> "{\n  body\n}" (the inner whitespace, if any, is replaced).
            let text = style.newline + body + style.newline + style.indent(depth)
            out.replaceSubrange((range.lowerBound + 1)..<(range.upperBound - 1), with: Array(text.utf8))
        } else {
            // "{\n  a" -> "{\n  body,\n  a": the block goes exactly where the first item was,
            // followed by a comma and a fresh line, so the original whitespace after the
            // brace is untouched and `removalRange` for a first item deletes precisely this.
            let text = body.drop { $0 == " " || $0 == "\t" } + "," + style.newline + style.indent(depth + 1)
            out.insert(contentsOf: Array(text.utf8), at: firstItemStart(of: container))
        }
        return out
    }

    private static func firstItemStart(of container: Node) -> Int {
        switch container {
        case .object(_, let members): members[0].keyRange.lowerBound
        case .array(_, let elements): elements[0].range.lowerBound
        case .scalar(let range): range.lowerBound
        }
    }

    /// The byte range to delete to drop item `index` from `container`, the exact inverse of
    /// `insert`: a first item is removed together with the separator and whitespace before
    /// the next one, any other item together with the separator before it, and a sole item
    /// collapses the container to `{}`/`[]`.
    private static func removalRange(of index: Int, in container: Node, itemRanges: [Range<Int>]) -> Range<Int> {
        let bounds = container.range
        if itemRanges.count == 1 {
            return (bounds.lowerBound + 1)..<(bounds.upperBound - 1)
        }
        if index == 0 {
            return itemRanges[0].lowerBound..<itemRanges[1].lowerBound
        }
        return itemRanges[index - 1].upperBound..<itemRanges[index].upperBound
    }

    // MARK: Formatting

    /// Newline and indentation conventions detected from the file.
    struct Style {
        let unit: String
        let newline: String

        init(unit: String = "  ", newline: String = "\n") {
            self.unit = unit
            self.newline = newline
        }

        /// Uses the first indented line's leading whitespace as the unit (tabs stay tabs)
        /// and CRLF when the file uses it. Defaults to two spaces and LF. Works on bytes
        /// because Swift treats "\r\n" as a single Character.
        init(detectingFrom bytes: [UInt8]) {
            let cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
            let space = UInt8(ascii: " "), tab = UInt8(ascii: "\t")
            var usesCRLF = false
            var detected = "  "
            var found = false
            var index = 0
            while index < bytes.count {
                // One line per iteration.
                var end = index
                while end < bytes.count, bytes[end] != lf, bytes[end] != cr { end += 1 }
                if end < bytes.count, bytes[end] == cr, end + 1 < bytes.count, bytes[end + 1] == lf { usesCRLF = true }
                if !found {
                    var lead = index
                    while lead < end, bytes[lead] == space || bytes[lead] == tab { lead += 1 }
                    if lead > index, lead < end {
                        let leading = bytes[index..<lead]
                        detected = leading.contains(tab) ? "\t" : String(repeating: " ", count: leading.count)
                        found = true
                    }
                }
                if found, usesCRLF { break }
                index = end + 1
            }
            newline = usesCRLF ? "\r\n" : "\n"
            unit = detected
        }

        func indent(_ depth: Int) -> String { String(repeating: unit, count: depth) }

        /// Nesting depth of the container whose opening bracket is at `offset`: the number
        /// of brackets still open before it (0 for the root). Only used to indent new text.
        func depth(of offset: Int, in bytes: [UInt8]) -> Int {
            var depth = 0
            var inString = false
            var escaped = false
            for byte in bytes[..<offset] {
                if inString {
                    if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                } else {
                    switch byte {
                    case UInt8(ascii: "\""): inString = true
                    case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1
                    default: break
                    }
                }
            }
            return max(depth, 0)
        }

        /// `"hooks": { events... }` as a member of an object at `depth`.
        func hooksMember(events: [String], scriptPath: String, depth: Int) -> String {
            let inner = eventMembers(events, scriptPath: scriptPath, depth: depth + 1)
            return indent(depth + 1) + "\"hooks\": {" + newline + inner + newline + indent(depth + 1) + "}"
        }

        /// `"Stop": [ group ], "SubagentStart": [ group ]` as members of the hooks object at `depth`.
        func eventMembers(_ events: [String], scriptPath: String, depth: Int) -> String {
            events.map { event in
                indent(depth + 1) + "\"\(event)\": [" + newline
                    + matcherGroup(scriptPath: scriptPath, depth: depth + 1) + newline
                    + indent(depth + 1) + "]"
            }.joined(separator: "," + newline)
        }

        /// `{ "hooks": [ { "type": "command", "command": path, "timeout": 5 } ] }` as an
        /// element of an event array at `depth`.
        func matcherGroup(scriptPath: String, depth: Int) -> String {
            let d = depth + 1
            return [
                indent(d) + "{",
                indent(d + 1) + "\"hooks\": [",
                indent(d + 2) + "{",
                indent(d + 3) + "\"type\": \"command\",",
                indent(d + 3) + "\"command\": \(Self.quote(scriptPath)),",
                indent(d + 3) + "\"timeout\": \(HookSettingsMerge.commandTimeout)",
                indent(d + 2) + "}",
                indent(d + 1) + "]",
                indent(d) + "}",
            ].joined(separator: newline)
        }

        /// JSON string literal (no `\/` escaping, unlike JSONSerialization).
        static func quote(_ string: String) -> String {
            var out = "\""
            for scalar in string.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
                default: out.unicodeScalars.append(scalar)
                }
            }
            return out + "\""
        }
    }

    // MARK: Range scanner

    /// A JSON value with the byte range it occupies in the source (containers include
    /// their brackets, strings their quotes).
    indirect enum Node {
        case object(Range<Int>, [Member])
        case array(Range<Int>, [Node])
        case scalar(Range<Int>)

        var range: Range<Int> {
            switch self {
            case .object(let r, _), .array(let r, _), .scalar(let r): r
            }
        }

        var isEmpty: Bool {
            switch self {
            case .object(_, let members): members.isEmpty
            case .array(_, let elements): elements.isEmpty
            case .scalar: false
            }
        }
    }

    struct Member {
        let key: String
        let keyRange: Range<Int>
        let value: Node
        /// From the first byte of the key to the last byte of the value.
        var range: Range<Int> { keyRange.lowerBound..<value.range.upperBound }
    }

    /// The scanned file: root object plus a lookup for the `"hooks"` member. Duplicate keys
    /// resolve to the last occurrence, matching `JSON.parse` in Claude Code.
    struct Document {
        let root: Node
        let rootMembers: [Member]

        var hooksMember: Member? { rootMembers.last(where: { $0.key == "hooks" }) }

        init(_ bytes: [UInt8]) throws {
            var scanner = Scanner(bytes: bytes)
            scanner.skipBOM()
            scanner.skipWhitespace()
            let node = try scanner.value()
            scanner.skipWhitespace()
            guard scanner.atEnd else { throw Failure.invalidJSON("trailing characters") }
            guard case .object(_, let members) = node else { throw Failure.notAnObject }
            root = node
            rootMembers = members
        }
    }

    /// Minimal strict-JSON scanner recording byte ranges. Runs only on text that
    /// `JSONSerialization` has already accepted, so its own error paths are belt and braces.
    struct Scanner {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { i >= bytes.count }

        mutating func skipBOM() {
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
        }

        mutating func skipWhitespace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func value() throws -> Node {
            guard i < bytes.count else { throw Failure.invalidJSON("unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .scalar(try string())
            default:
                let start = i
                while i < bytes.count, !([0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]")].contains(bytes[i])) {
                    i += 1
                }
                let token = String(decoding: bytes[start..<i], as: UTF8.self)
                guard Self.isLiteralOrNumber(token) else { throw Failure.invalidJSON("unexpected token at \(start)") }
                return .scalar(start..<i)
            }
        }

        mutating func object() throws -> Node {
            let start = i
            i += 1
            var members: [Member] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") {
                i += 1
                return .object(start..<i, members)
            }
            while true {
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw Failure.invalidJSON("expected key at \(i)") }
                let keyRange = try string()
                guard let key = try? JSONSerialization.jsonObject(with: Data(bytes[keyRange]), options: .fragmentsAllowed) as? String else {
                    throw Failure.invalidJSON("bad key at \(keyRange.lowerBound)")
                }
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw Failure.invalidJSON("expected ':' at \(i)") }
                i += 1
                skipWhitespace()
                let value = try value()
                members.append(Member(key: key, keyRange: keyRange, value: value))
                skipWhitespace()
                guard i < bytes.count else { throw Failure.invalidJSON("unterminated object") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(start..<i, members) }
                throw Failure.invalidJSON("expected ',' or '}' at \(i)")
            }
        }

        mutating func array() throws -> Node {
            let start = i
            i += 1
            var elements: [Node] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") {
                i += 1
                return .array(start..<i, elements)
            }
            while true {
                skipWhitespace()
                elements.append(try value())
                skipWhitespace()
                guard i < bytes.count else { throw Failure.invalidJSON("unterminated array") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(start..<i, elements) }
                throw Failure.invalidJSON("expected ',' or ']' at \(i)")
            }
        }

        /// `true`, `false`, `null` or a JSON number; anything else (comments, `NaN`, bare
        /// words) is rejected.
        static func isLiteralOrNumber(_ token: String) -> Bool {
            if ["true", "false", "null"].contains(token) { return true }
            let number = try? NSRegularExpression(pattern: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#)
            let range = NSRange(token.startIndex..., in: token)
            return number?.firstMatch(in: token, range: range) != nil
        }

        /// Scans a string literal including both quotes, honouring backslash escapes.
        mutating func string() throws -> Range<Int> {
            let start = i
            i += 1
            while i < bytes.count {
                let byte = bytes[i]
                if byte == UInt8(ascii: "\\") {
                    i += 2
                    continue
                }
                i += 1
                if byte == UInt8(ascii: "\"") { return start..<i }
            }
            throw Failure.invalidJSON("unterminated string")
        }
    }
}

// MARK: - HookInstaller

/// Keeps the Claude Code hooks Claude Heads needs installed in `~/.claude/settings.json`
/// while the app is running: installs them at launch (and when the setting is turned on)
/// and removes them again on quit (and when the setting is turned off). The edits are the
/// minimal splices from `HookSettingsMerge`, written atomically through any symlinks, with a
/// one-time backup of the original file next to it.
///
/// Hooks only apply to `claude` sessions started after they were written; the app spawns a
/// fresh process for every head so that is always the case for its own heads.
@Observable
final class HookInstaller {

    static let shared = HookInstaller()

    enum Status: Equatable {
        case installed
        case missing([String])
        case failed(String)

        var label: String {
            switch self {
            case .installed: "Installed"
            case .missing(let events): "Missing: " + events.joined(separator: ", ")
            case .failed(let reason): "Could not update settings.json: " + reason
            }
        }
    }

    /// Current state of the hooks in the settings file, refreshed after every operation.
    private(set) var status: Status = .missing(HookSettingsMerge.events)

    /// Name appended to the settings file for the one-time backup.
    static let backupSuffix = ".claude-heads.bak"

    let settingsFileURL: URL
    let scriptPath: String

    init(
        settingsFileURL: URL = Constants.claudeSettingsFile,
        scriptPath: String = Constants.hooksDirectory.appendingPathComponent("notify.sh").path
    ) {
        self.settingsFileURL = settingsFileURL
        self.scriptPath = scriptPath
        refreshStatus()
    }

    // MARK: Operations

    /// Re-reads the settings file and updates `status` without writing anything.
    @discardableResult
    func refreshStatus() -> Status {
        status = Self.inspect(text: readSettings() ?? "{}")
        return status
    }

    /// Ensures our entries exist for every event. Returns true when the file is in the
    /// desired state afterwards (including when nothing needed to change).
    @discardableResult
    func install() -> Bool {
        apply { HookSettingsMerge.install(into: $0, scriptPath: scriptPath) }
    }

    /// Removes every entry of ours. Returns true when none remain afterwards.
    @discardableResult
    func uninstall() -> Bool {
        apply(createIfMissing: false) { HookSettingsMerge.uninstall(from: $0) }
    }

    /// Removes stale entries of ours and writes fresh ones in a single edit, so a script
    /// path from an old home directory or a hand-edited entry is replaced.
    @discardableResult
    func reinstall() -> Bool {
        apply { text in
            HookSettingsMerge.uninstall(from: text).flatMap {
                HookSettingsMerge.install(into: $0, scriptPath: scriptPath)
            }
        }
    }

    // MARK: Private

    private static func inspect(text: String) -> Status {
        switch HookSettingsMerge.missingEvents(in: text) {
        case .success(let missing): missing.isEmpty ? .installed : .missing(missing)
        case .failure(let failure): .failed(failure.description)
        }
    }

    /// Runs `merge` on the file's text and writes the result if it changed, updating `status`.
    private func apply(createIfMissing: Bool = true, _ merge: (String) -> Result<String, HookSettingsMerge.Failure>) -> Bool {
        let fm = FileManager.default
        let existing = readSettings()
        if existing == nil, fm.fileExists(atPath: resolvedFileURL.path) {
            // The file is there but could not be read as UTF-8 text: never touch it.
            status = .failed("could not read \(settingsFileURL.path)")
            NSLog("[HookInstaller] \(status.label)")
            return false
        }
        if existing == nil, !createIfMissing {
            status = .missing(HookSettingsMerge.events)
            return true
        }
        let original = existing ?? "{}"

        switch merge(original) {
        case .failure(let failure):
            status = .failed(failure.description)
            NSLog("[HookInstaller] \(status.label)")
            return false

        case .success(let updated):
            if updated != original {
                do {
                    if existing != nil { try backupIfNeeded() }
                    try writeSettings(updated + (existing == nil ? "\n" : ""))
                } catch {
                    status = .failed(error.localizedDescription)
                    NSLog("[HookInstaller] \(status.label)")
                    return false
                }
            }
            status = Self.inspect(text: readSettings() ?? "{}")
            return true
        }
    }

    /// The settings file with every symlink resolved (`~/.claude` is commonly a symlink into
    /// a dotfiles repository, and the file itself may be one). Writing here means the atomic
    /// rename replaces the real file, not the link.
    private var resolvedFileURL: URL {
        settingsFileURL.resolvingSymlinksInPath()
    }

    private func readSettings() -> String? {
        guard let data = fm.contents(atPath: resolvedFileURL.path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private var fm: FileManager { .default }

    private func backupIfNeeded() throws {
        let source = resolvedFileURL
        let backup = source.appendingPathExtension(String(Self.backupSuffix.dropFirst()))
        guard !fm.fileExists(atPath: backup.path) else { return }
        try fm.copyItem(at: source, to: backup)
    }

    /// Writes `text` to a temporary file in the same directory and renames it over the real
    /// file, preserving the original's permissions, so a reader never sees a partial file.
    private func writeSettings(_ text: String) throws {
        let target = resolvedFileURL
        let directory = target.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let temp = directory.appendingPathComponent(".settings.json.claude-heads-\(UUID().uuidString).tmp")
        try Data(text.utf8).write(to: temp, options: [])
        if let permissions = try? fm.attributesOfItem(atPath: target.path)[.posixPermissions] {
            try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
        }
        guard rename(temp.path, target.path) == 0 else {
            let error = errno
            try? fm.removeItem(at: temp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error), userInfo: [
                NSLocalizedDescriptionKey: "rename failed: \(String(cString: strerror(error)))",
            ])
        }
    }
}
