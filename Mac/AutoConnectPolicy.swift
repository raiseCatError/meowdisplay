import Foundation

/// Small, transport-agnostic gate for automatic connection attempts.
/// `SenderController` remains the session owner; this type only answers
/// whether a discovered logical receiver may start a new attempt.
struct AutoConnectPolicy {
    struct Attempt: Equatable {
        let logicalID: String
        let generation: UInt64
    }

    private(set) var knownIdentifiers: Set<String>
    private(set) var suppressedIdentifiers: Set<String> = []
    private(set) var pairingIdentifiers: Set<String> = []
    private var attempts: [String: UInt64] = [:]
    private var nextGeneration: UInt64 = 0

    init(knownIdentifiers: Set<String> = []) {
        self.knownIdentifiers = knownIdentifiers
    }

    mutating func remember(_ identifiers: Set<String>) {
        knownIdentifiers.formUnion(identifiers)
    }

    /// Manual disconnect lasts for the current availability cycle. The
    /// controller supplies all known route/install aliases for the receiver.
    mutating func suppress(_ identifiers: Set<String>) {
        suppressedIdentifiers.formUnion(identifiers)
    }

    mutating func allowExplicitConnection(_ identifiers: Set<String>) {
        remember(identifiers)
        suppressedIdentifiers.subtract(identifiers)
    }

    mutating func beginPairing(_ identifiers: Set<String>) {
        pairingIdentifiers.formUnion(identifiers)
    }

    mutating func finishPairing(_ identifiers: Set<String>) {
        pairingIdentifiers.subtract(identifiers)
    }

    func isPairing(_ identifiers: Set<String>) -> Bool {
        !pairingIdentifiers.isDisjoint(with: identifiers)
    }

    /// Called after discovery has been stable for the controller's debounce.
    /// Once every alias for a suppressed receiver disappears, its suppression
    /// naturally falls away and a later appearance is a new availability cycle.
    mutating func updateAvailableIdentifiers(_ identifiers: Set<String>) {
        suppressedIdentifiers.formIntersection(identifiers)
    }

    mutating func beginAutomaticAttempt(
        logicalID: String,
        identifiers: Set<String>,
        hasSessionOwner: Bool
    ) -> Attempt? {
        guard !hasSessionOwner,
              attempts[logicalID] == nil,
              !knownIdentifiers.isDisjoint(with: identifiers),
              pairingIdentifiers.isDisjoint(with: identifiers),
              suppressedIdentifiers.isDisjoint(with: identifiers) else { return nil }
        return beginAttempt(logicalID: logicalID)
    }

    mutating func beginExplicitAttempt(logicalID: String, identifiers: Set<String>) -> Attempt {
        allowExplicitConnection(identifiers)
        attempts.removeValue(forKey: logicalID)
        return beginAttempt(logicalID: logicalID)
    }

    /// Rebuilds requested by an already-owned session (wake, settings) do not
    /// change trust or suppression; they only replace attempt ownership.
    mutating func beginContinuationAttempt(logicalID: String) -> Attempt {
        attempts.removeValue(forKey: logicalID)
        return beginAttempt(logicalID: logicalID)
    }

    func isCurrent(_ attempt: Attempt) -> Bool {
        attempts[attempt.logicalID] == attempt.generation
    }

    mutating func finish(_ attempt: Attempt) {
        guard isCurrent(attempt) else { return }
        attempts.removeValue(forKey: attempt.logicalID)
    }

    private mutating func beginAttempt(logicalID: String) -> Attempt {
        nextGeneration &+= 1
        let attempt = Attempt(logicalID: logicalID, generation: nextGeneration)
        attempts[logicalID] = attempt.generation
        return attempt
    }
}
