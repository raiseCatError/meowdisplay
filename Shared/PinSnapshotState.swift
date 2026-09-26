import Foundation

/// Pure ordering rules for `TrustStore`'s in-memory SPKI pin snapshot.
///
/// The snapshot mirrors the Keychain, but Keychain reads run with no lock
/// held, so an older read can reach its commit after a newer pin mutation
/// has already committed (e.g. a listener-start refresh that read pin P just
/// before `forget(P)` would re-add P). Every Keychain pin mutation therefore
/// calls `keychainDidMutate()` AFTER its Keychain writes and BEFORE reading
/// back; that bumps `revision` and invalidates every ticket issued earlier.
/// A refresh takes its ticket from `beginRefresh()` BEFORE reading the
/// Keychain, and `commit` drops its read if a mutation happened in between:
/// that read may predate the mutation's write, and the mutation commits its
/// own, later read-back.
///
/// No locking of its own: `TrustStore` holds exactly one and touches it only
/// under its snapshot lock.
struct PinSnapshotState: Sendable {
    struct Pin: Equatable, Sendable {
        let peerID: String
        let spki: Data
    }

    /// The revision a Keychain read was taken at. Only this type mints them.
    struct Ticket: Sendable {
        fileprivate let revision: UInt64
    }

    private(set) var pins: [Pin] = []
    /// Bumped by every Keychain pin mutation; never decreases.
    private var revision: UInt64 = 0

    /// Ticket for a refresh about to read the Keychain. Invalidates nothing.
    func beginRefresh() -> Ticket {
        Ticket(revision: revision)
    }

    /// A pin mutation finished writing the Keychain: invalidate every earlier
    /// ticket, and return the ticket for the mutation's own read-back.
    mutating func keychainDidMutate() -> Ticket {
        revision += 1
        return Ticket(revision: revision)
    }

    /// Replace the snapshot with `read` iff no mutation happened since
    /// `ticket` was issued. Returns false, leaving the snapshot untouched,
    /// for a stale read.
    @discardableResult
    mutating func commit(_ read: [Pin], readAt ticket: Ticket) -> Bool {
        guard ticket.revision == revision else { return false }
        pins = read
        return true
    }

    var allSPKIs: [Data] {
        pins.map(\.spki)
    }

    /// Which pinned peerID owns this SPKI; nil if it matches no current pin.
    func peerID(forSPKI spki: Data) -> String? {
        pins.first { $0.spki == spki }?.peerID
    }
}
