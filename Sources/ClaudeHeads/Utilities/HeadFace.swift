import Foundation

/// ASCII faces displayed on chat heads, mapped to Claude states.
enum HeadFace: String, CaseIterable {
    case lookR       = " ⚆_⚆"
    case lookL       = "☉_☉ "
    case lookRHappy  = " ◕‿◕"
    case lookLHappy  = "◕‿◕ "
    case sleep       = "⇀‿‿↼"
    case sleep2      = "≖‿‿≖"
    case awake       = "◕‿‿◕"
    case bored       = "-__-"
    case intense     = "°▃▃°"
    case cool        = "⌐■_■"
    case happy       = "•‿‿•"
    case grateful    = "^‿‿^"
    case excited     = "ᵔ◡◡ᵔ"
    case motivated   = "☼‿‿☼"
    case demotivated = "≖__≖"
    case smart       = "✜‿‿✜"
    case lonely      = "ب__ب"
    case sad         = "╥☁╥ "
    case angry       = "-_-'"
    case friend      = "♥‿‿♥"
    case broken      = "☓‿‿☓"
    case debug       = "#__#"
    case upload      = "1__0"
    case upload1     = "1__1"
    case upload2     = "0__1"

    /// Face for when claude just finished a task
    static let finished: HeadFace = .happy

    /// Face for errored state
    static let errored: HeadFace = .broken
}

// MARK: - FaceSequencer

/// Generates a random sequence of faces for a head, keeping L/R pairs together.
/// Each head gets its own sequencer instance.
///
/// Idle pool (each entry equally weighted):
///   - look R then L (pair)
///   - look L then R (pair)
///   - look R happy then L happy (pair)
///   - look L happy then R happy (pair)
///   - awake (single)
///   - happy (single)
///   - grateful (single)
///   - cool (single)
///   - bored (single)
///   - sleep (single)
///   - sleep2 (single)
class FaceSequencer {
    private var queue: [HeadFace] = []
    private var state: HeadState = .idle

    /// Each idle entry produces a sequence of faces for 2+ ticks
    private let idleEntries: [[HeadFace]] = [
        // L/R pairs — each is one entry, plays as R,R,L,L or L,L,R,R
        [.lookR, .lookR, .lookL, .lookL],
        [.lookL, .lookL, .lookR, .lookR],
        [.lookRHappy, .lookRHappy, .lookLHappy, .lookLHappy],
        [.lookLHappy, .lookLHappy, .lookRHappy, .lookRHappy],
        // Singles — hold for 2 ticks
        [.awake, .awake],
        [.happy, .happy],
        [.grateful, .grateful],
        [.cool, .cool],
        [.bored, .bored],
        [.sleep, .sleep],
        [.sleep2, .sleep2],
    ]

    private let runningEntries: [[HeadFace]] = [
        [.intense, .intense],
        [.smart, .smart],
        [.motivated, .motivated],
        [.cool, .cool],
        [.excited, .excited],
    ]

    private let sleepEntries: [[HeadFace]] = [
        [.sleep, .sleep, .sleep],
        [.sleep2, .sleep2, .sleep2],
        [.sleep, .sleep2, .sleep],
        [.bored, .bored, .sleep],
    ]

    private let lonelyEntries: [[HeadFace]] = [
        [.lonely, .lonely, .lonely],
        [.sad, .sad, .lonely],
        [.demotivated, .demotivated, .lonely],
        [.lonely, .sad, .demotivated],
    ]

    /// Idle duration thresholds
    private static let sleepThreshold: TimeInterval = 60       // 1 minute
    private static let lonelyThreshold: TimeInterval = 30 * 60 // 30 minutes

    /// When the head last became idle
    var idleSince: Date?

    func setState(_ newState: HeadState) {
        if newState != state {
            state = newState
            queue.removeAll()
            if newState == .idle {
                idleSince = Date()
            } else {
                idleSince = nil
            }
        }
    }

    /// Call when the user clicks the head — resets idle timer
    func wake() {
        idleSince = Date()
        queue.removeAll()
    }

    func next() -> HeadFace {
        if !queue.isEmpty {
            return queue.removeFirst()
        }

        switch state {
        case .idle:
            let idleDuration = -(idleSince ?? Date()).timeIntervalSinceNow
            if idleDuration >= Self.lonelyThreshold {
                queue = lonelyEntries.randomElement()!
            } else if idleDuration >= Self.sleepThreshold {
                queue = sleepEntries.randomElement()!
            } else {
                queue = idleEntries.randomElement()!
            }

        case .running:
            queue = runningEntries.randomElement()!

        case .finished:
            queue = [HeadFace.finished]

        case .errored:
            queue = [HeadFace.errored]
        }

        return queue.removeFirst()
    }
}
