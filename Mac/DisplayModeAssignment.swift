import CoreGraphics
import Foundation

// Per-device Mirror/Extend (issue #20). Every connected receiver already owns
// a full `MacSender` pipeline — its own virtual display, capture and encoder —
// so independence was never limited by the pipeline; it was limited by the
// Mac-wide `mode`/`mirrorDisplayUUID` settings that every pipeline was built
// from, and by `restartAll()` rebuilding every device whenever either changed.
// This file holds the decisions that replace that: which mode and Mirror
// source each device gets, and which sessions a change actually has to
// rebuild. Foundation/CoreGraphics only, like its siblings, so the
// multi-receiver combinations are unit testable without real displays.

/// One device's own Mirror capture-source choice. At the preference level,
/// `nil` means "follow this Mac's default" — distinct from `.automatic`,
/// which is an explicit per-device pick of Automatic.
enum MirrorSourcePreference: Equatable {
    case automatic
    case display(uuid: String)

    init(displayUUID: String?) {
        self = displayUUID.map { .display(uuid: $0) } ?? .automatic
    }

    var displayUUID: String? {
        if case .display(let uuid) = self { return uuid }
        return nil
    }
}

/// What one device chose for itself. A `nil` field follows the Mac-wide
/// default, so an existing install (no per-device record anywhere) behaves
/// exactly as it did when the mode was global.
struct DeviceDisplayModePreference: Equatable {
    var mode: CaptureMode?
    var mirrorSource: MirrorSourcePreference?

    static let followsDefault = DeviceDisplayModePreference(mode: nil, mirrorSource: nil)

    var isFollowingDefault: Bool { mode == nil && mirrorSource == nil }
}

/// Per-peer persistence, keyed by the receiver's stable install id — the same
/// cross-transport identity `ExtendDisplayShapeStore` and display arrangement
/// memory use, so a device keeps its mode across USB/LAN/Remote, reconnects
/// and sender restarts.
enum DeviceDisplayModeStore {
    static func load(peerID: String, defaults: UserDefaults = .standard) -> DeviceDisplayModePreference {
        guard let raw = defaults.dictionary(forKey: key(peerID)) else { return .followsDefault }
        let mode = (raw["mode"] as? String).flatMap(CaptureMode.init(rawValue:))
        let mirrorSource: MirrorSourcePreference? = {
            switch raw["mirrorSource"] as? String {
            case "automatic": return .automatic
            case "display": return (raw["mirrorDisplayUUID"] as? String).map { .display(uuid: $0) }
            default: return nil
            }
        }()
        return DeviceDisplayModePreference(mode: mode, mirrorSource: mirrorSource)
    }

    static func save(_ preference: DeviceDisplayModePreference, peerID: String,
                     defaults: UserDefaults = .standard) {
        guard !preference.isFollowingDefault else {
            remove(peerID: peerID, defaults: defaults)
            return
        }
        var raw: [String: Any] = [:]
        if let mode = preference.mode { raw["mode"] = mode.rawValue }
        switch preference.mirrorSource {
        case .automatic: raw["mirrorSource"] = "automatic"
        case .display(let uuid):
            raw["mirrorSource"] = "display"
            raw["mirrorDisplayUUID"] = uuid
        case nil: break
        }
        defaults.set(raw, forKey: key(peerID))
    }

    /// Forget removes the device's choice with the rest of its per-peer state.
    static func remove(peerID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(peerID))
    }

    private static func key(_ peerID: String) -> String { "displayMode.\(peerID)" }
}

/// The Mac-wide values a device without its own choice follows — the
/// pre-#20 global `mode`/`mirrorDisplayUUID` settings, unchanged in storage.
struct DisplayModeDefaults: Equatable {
    var mode: CaptureMode
    var mirrorDisplayUUID: String?
}

/// What one session's pipeline is actually built with.
struct DeviceDisplayAssignment: Equatable {
    let mode: CaptureMode
    /// The Mirror source (`nil` = Automatic). Carried in Extend too, so a
    /// later switch back to Mirror needs no extra lookup, but ignored there.
    let mirrorDisplayUUID: String?
    /// Whether `mode` is the device's own choice rather than the Mac default.
    let modeIsDeviceChoice: Bool
    /// Whether `mirrorDisplayUUID` is the device's own choice.
    let mirrorSourceIsDeviceChoice: Bool

    /// Two assignments produce the same capture: the mode matches and, in
    /// Mirror only, so does the source. Who chose a value never matters.
    func capturesSame(as other: DeviceDisplayAssignment) -> Bool {
        mode == other.mode && (mode == .extend || mirrorDisplayUUID == other.mirrorDisplayUUID)
    }
}

enum DeviceDisplayModeResolution {
    static func resolve(preference: DeviceDisplayModePreference, defaults: DisplayModeDefaults,
                        videoEnabled: Bool) -> DeviceDisplayAssignment {
        let mode = VideoModePolicy.normalized(mode: preference.mode ?? defaults.mode, videoEnabled: videoEnabled)
        let mirrorDisplayUUID = preference.mirrorSource.map(\.displayUUID) ?? defaults.mirrorDisplayUUID
        return DeviceDisplayAssignment(mode: mode, mirrorDisplayUUID: mirrorDisplayUUID,
                                       modeIsDeviceChoice: preference.mode != nil,
                                       mirrorSourceIsDeviceChoice: preference.mirrorSource != nil)
    }
}

/// Why a device's mode request was refused. The session keeps its current
/// mode; nothing else is touched.
enum DisplayModeRejection: Equatable {
    /// Video is off, which only Mirror supports (`VideoModePolicy`).
    case videoOff
    /// Mirror needs a usable physical display (`MirrorUnavailableOfferPolicy`).
    case noPhysicalDisplay
    /// The session ended before the request was handled.
    case unknownSession
}

enum DisplayModeChangeOutcome: Equatable {
    /// The session already captures this way. A device-choice change may
    /// still have been persisted.
    case unchanged
    /// Rebuild only this session's pipeline with the new assignment.
    case rebuild(DeviceDisplayAssignment)
    case rejected(DisplayModeRejection)
}

/// The single authority for which mode and Mirror source every live session
/// uses. `SenderController` routes every mode-affecting event through it —
/// the Mac's default pickers, each device's own controls, a receiver's
/// `displayModeRequest`/`mirrorDisplayRequest`, session approval, Video Off —
/// and rebuilds exactly the sessions it names, so changing one device never
/// rebuilds or changes another.
///
/// Keyed by `DeviceSession.id`. A pipeline rebuilt for the same target keeps
/// its entry (that is what carries the assignment across the rebuild); an
/// entry ends with its session.
struct DisplayModeCoordinator {
    struct LiveSession: Equatable {
        var peerID: String?
        var assignment: DeviceDisplayAssignment
    }

    private(set) var defaults: DisplayModeDefaults
    private(set) var videoEnabled: Bool
    private(set) var live: [String: LiveSession] = [:]
    private let store: UserDefaults

    init(defaults: DisplayModeDefaults, videoEnabled: Bool, store: UserDefaults = .standard) {
        self.defaults = defaults
        self.videoEnabled = videoEnabled
        self.store = store
    }

    func preference(peerID: String?) -> DeviceDisplayModePreference {
        peerID.map { DeviceDisplayModeStore.load(peerID: $0, defaults: store) } ?? .followsDefault
    }

    /// What a device would get right now (also for a device that is offline).
    func resolvedAssignment(peerID: String?) -> DeviceDisplayAssignment {
        DeviceDisplayModeResolution.resolve(preference: preference(peerID: peerID), defaults: defaults,
                                            videoEnabled: videoEnabled)
    }

    func assignment(sessionID: String) -> DeviceDisplayAssignment? { live[sessionID]?.assignment }

    /// A pipeline for `sessionID` is about to be built. A rebuild keeps the
    /// entry it already has; a new session resolves from the device's stored
    /// choice (or the Mac default).
    mutating func begin(sessionID: String, peerID: String?) -> DeviceDisplayAssignment {
        if var existing = live[sessionID] {
            if existing.peerID == nil { existing.peerID = peerID }
            live[sessionID] = existing
            return existing.assignment
        }
        let assignment = resolvedAssignment(peerID: peerID)
        live[sessionID] = LiveSession(peerID: peerID, assignment: assignment)
        return assignment
    }

    mutating func end(sessionID: String) {
        live.removeValue(forKey: sessionID)
    }

    /// Drops entries whose session no longer exists (a rebuild whose
    /// reconnect could not start).
    mutating func retain(sessionIDs: Set<String>) {
        live = live.filter { sessionIDs.contains($0.key) }
    }

    /// The receiver's hello authenticated its install id. A session that
    /// started without one (an unresolved USB device) used the Mac default;
    /// if this device has its own choice, it needs a rebuild to honor it.
    mutating func identify(sessionID: String, peerID: String) -> DisplayModeChangeOutcome {
        guard var entry = live[sessionID] else { return .rejected(.unknownSession) }
        guard entry.peerID == nil else { return .unchanged }
        entry.peerID = peerID
        let resolved = resolvedAssignment(peerID: peerID)
        let changed = !resolved.capturesSame(as: entry.assignment)
        entry.assignment = resolved
        live[sessionID] = entry
        return changed ? .rebuild(resolved) : .unchanged
    }

    /// The Mac's own pickers can show why a mode is unavailable; this is the
    /// authority they and every remote request share.
    static func rejection(for mode: CaptureMode, videoEnabled: Bool,
                          hasUsablePhysicalDisplay: Bool) -> DisplayModeRejection? {
        if !VideoModePolicy.allows(mode, videoEnabled: videoEnabled) { return .videoOff }
        if mode == .mirror,
           !MirrorUnavailableOfferPolicy.canEnterMirror(hasUsablePhysicalDisplay: hasUsablePhysicalDisplay) {
            return .noPhysicalDisplay
        }
        return nil
    }

    /// One device asks for a mode — its own control on this Mac, its
    /// receiver's request, Connect with Mirror/Extend, or session approval.
    /// Becomes that device's remembered choice; no other session changes.
    mutating func requestMode(_ mode: CaptureMode, sessionID: String,
                              hasUsablePhysicalDisplay: Bool) -> DisplayModeChangeOutcome {
        guard let entry = live[sessionID] else { return .rejected(.unknownSession) }
        if let rejection = Self.rejection(for: mode, videoEnabled: videoEnabled,
                                          hasUsablePhysicalDisplay: hasUsablePhysicalDisplay) {
            return .rejected(rejection)
        }
        var preference = preference(peerID: entry.peerID)
        preference.mode = mode
        return apply(preference, to: sessionID)
    }

    /// One device asks for a Mirror source (`nil`: follow the Mac default
    /// source again). Rebuilds only if that device is mirroring and the
    /// source actually changes.
    mutating func requestMirrorSource(_ source: MirrorSourcePreference?,
                                      sessionID: String) -> DisplayModeChangeOutcome {
        guard let entry = live[sessionID] else { return .rejected(.unknownSession) }
        var preference = preference(peerID: entry.peerID)
        preference.mirrorSource = source
        return apply(preference, to: sessionID)
    }

    /// The device's mode follows the Mac default again; its Mirror source
    /// choice is kept.
    mutating func followDefaultMode(sessionID: String) -> DisplayModeChangeOutcome {
        guard let entry = live[sessionID] else { return .rejected(.unknownSession) }
        var preference = preference(peerID: entry.peerID)
        preference.mode = nil
        return apply(preference, to: sessionID)
    }

    /// "Use Mac Default": the device drops its own choice and follows the
    /// default again.
    mutating func followDefault(sessionID: String) -> DisplayModeChangeOutcome {
        guard live[sessionID] != nil else { return .rejected(.unknownSession) }
        return apply(.followsDefault, to: sessionID)
    }

    /// Records a choice for a device before any session exists for it
    /// (Connect with Mirror/Extend on a device with a known install id).
    mutating func setDeviceMode(_ mode: CaptureMode, peerID: String) {
        var preference = preference(peerID: peerID)
        preference.mode = mode
        DeviceDisplayModeStore.save(preference, peerID: peerID, defaults: store)
    }

    /// Records a one-off mode for a session that has no install id yet, so
    /// the pipeline about to be built for it (`begin`) uses it.
    mutating func stage(_ mode: CaptureMode, sessionID: String) {
        let base = live[sessionID]?.assignment ?? resolvedAssignment(peerID: nil)
        live[sessionID] = LiveSession(
            peerID: live[sessionID]?.peerID,
            assignment: DeviceDisplayAssignment(mode: VideoModePolicy.normalized(mode: mode, videoEnabled: videoEnabled),
                                                mirrorDisplayUUID: base.mirrorDisplayUUID,
                                                modeIsDeviceChoice: true,
                                                mirrorSourceIsDeviceChoice: base.mirrorSourceIsDeviceChoice))
    }

    /// The Mac's default mode changed. Returns only the sessions that follow
    /// the default and now capture differently.
    mutating func setDefaultMode(_ mode: CaptureMode) -> [String: DeviceDisplayAssignment] {
        defaults.mode = mode
        return reresolveAll()
    }

    /// The Mac's default Mirror source changed.
    mutating func setDefaultMirrorDisplay(_ uuid: String?) -> [String: DeviceDisplayAssignment] {
        defaults.mirrorDisplayUUID = uuid
        return reresolveAll()
    }

    /// Video Off. Video is Mac-wide; with a physical display to hand off to,
    /// every Extend session becomes Mirror in place (reclaiming its virtual
    /// display) and turning video back on never restores Extend implicitly —
    /// the pre-#20 behavior, now applied per device: the default becomes
    /// Mirror, and a device whose own choice was Extend now remembers Mirror.
    /// Headless, nothing changes mode. Returns the sessions the caller must
    /// transition in place (not rebuild).
    mutating func disableVideo(hasUsablePhysicalDisplay: Bool) -> [String] {
        videoEnabled = false
        guard MirrorUnavailableOfferPolicy.canEnterMirror(hasUsablePhysicalDisplay: hasUsablePhysicalDisplay) else {
            return []
        }
        defaults.mode = .mirror
        var transitioned: [String] = []
        for (sessionID, entry) in live.sorted(by: { $0.key < $1.key }) {
            if let peerID = entry.peerID {
                var preference = preference(peerID: peerID)
                if preference.mode == .extend {
                    preference.mode = .mirror
                    DeviceDisplayModeStore.save(preference, peerID: peerID, defaults: store)
                }
            }
            if entry.assignment.mode == .extend { transitioned.append(sessionID) }
            let resolved = resolveLive(entry)
            live[sessionID]?.assignment = resolved
        }
        return transitioned
    }

    /// Video On never restores Extend: nothing is rebuilt.
    mutating func enableVideo() {
        videoEnabled = true
    }

    /// The Mac default mode the Displays picker shows.
    var defaultMode: CaptureMode { defaults.mode }

    // MARK: - Private

    private func resolveLive(_ entry: LiveSession) -> DeviceDisplayAssignment {
        if entry.peerID == nil {
            // No install id: the session's staged one-off choice (if any) is
            // all it has; only the parts that follow the default re-resolve.
            let fromDefaults = resolvedAssignment(peerID: nil)
            let mode = entry.assignment.modeIsDeviceChoice
                ? VideoModePolicy.normalized(mode: entry.assignment.mode, videoEnabled: videoEnabled)
                : fromDefaults.mode
            return DeviceDisplayAssignment(mode: mode, mirrorDisplayUUID: fromDefaults.mirrorDisplayUUID,
                                           modeIsDeviceChoice: entry.assignment.modeIsDeviceChoice,
                                           mirrorSourceIsDeviceChoice: false)
        }
        return resolvedAssignment(peerID: entry.peerID)
    }

    private mutating func reresolveAll() -> [String: DeviceDisplayAssignment] {
        var rebuilds: [String: DeviceDisplayAssignment] = [:]
        for (sessionID, entry) in live {
            let resolved = resolveLive(entry)
            if !resolved.capturesSame(as: entry.assignment) { rebuilds[sessionID] = resolved }
            live[sessionID]?.assignment = resolved
        }
        return rebuilds
    }

    private mutating func apply(_ preference: DeviceDisplayModePreference,
                                to sessionID: String) -> DisplayModeChangeOutcome {
        guard let entry = live[sessionID] else { return .rejected(.unknownSession) }
        let resolved: DeviceDisplayAssignment
        if let peerID = entry.peerID {
            DeviceDisplayModeStore.save(preference, peerID: peerID, defaults: store)
            resolved = resolvedAssignment(peerID: peerID)
        } else {
            // Nothing durable to key on: the choice lasts for this session.
            resolved = DeviceDisplayModeResolution.resolve(preference: preference, defaults: defaults,
                                                           videoEnabled: videoEnabled)
        }
        live[sessionID]?.assignment = resolved
        return resolved.capturesSame(as: entry.assignment) ? .unchanged : .rebuild(resolved)
    }
}

// MARK: - Mirror source resolution

/// A capturable display, reduced to what source selection needs —
/// `SCDisplay` itself can't be constructed in a test.
struct MirrorSourceCandidate: Equatable {
    let displayID: CGDirectDisplayID
    let persistentID: String?
}

enum MirrorSourceResolution: Equatable {
    /// The device's (or default's) explicit choice is present.
    case selected(CGDirectDisplayID)
    /// Automatic.
    case automatic(CGDirectDisplayID)
    /// The explicit choice is not connected; Automatic stands in until it
    /// returns (the choice itself is kept).
    case selectedUnavailable(uuid: String, fallback: CGDirectDisplayID)
    /// Nothing this session may mirror.
    case unavailable

    var displayID: CGDirectDisplayID? {
        switch self {
        case .selected(let id), .automatic(let id), .selectedUnavailable(_, let id): return id
        case .unavailable: return nil
        }
    }
}

enum MirrorSourceResolver {
    /// Automatic never picks another session's MeowDisplay virtual display:
    /// before #20 it was simply ScreenCaptureKit's first display, which with
    /// an Extend receiver connected could be that receiver's desktop. With no
    /// MeowDisplay displays present this is exactly the old first-display
    /// behavior. An explicit pick of a MeowDisplay display is honored — the
    /// user can deliberately mirror another device's extended desktop.
    static func automatic(in candidates: [MirrorSourceCandidate],
                          excluding meowDisplayIDs: Set<CGDirectDisplayID>) -> CGDirectDisplayID? {
        candidates.first { !meowDisplayIDs.contains($0.displayID) }?.displayID
    }

    static func resolve(selectedUUID: String?, in candidates: [MirrorSourceCandidate],
                        excluding meowDisplayIDs: Set<CGDirectDisplayID>) -> MirrorSourceResolution {
        if let selectedUUID {
            if let match = candidates.first(where: { $0.persistentID == selectedUUID }) {
                return .selected(match.displayID)
            }
            guard let fallback = automatic(in: candidates, excluding: meowDisplayIDs) else { return .unavailable }
            return .selectedUnavailable(uuid: selectedUUID, fallback: fallback)
        }
        return automatic(in: candidates, excluding: meowDisplayIDs).map { .automatic($0) } ?? .unavailable
    }

    /// Capture recovery reattaches to the display it was capturing while that
    /// display still exists; otherwise Automatic, under the same exclusion.
    static func recoveryDisplay(preferred: CGDirectDisplayID?, in candidates: [MirrorSourceCandidate],
                                excluding meowDisplayIDs: Set<CGDirectDisplayID>) -> CGDirectDisplayID? {
        if let preferred, candidates.contains(where: { $0.displayID == preferred }) { return preferred }
        return automatic(in: candidates, excluding: meowDisplayIDs)
    }
}

// MARK: - Live virtual displays

/// The vendor-local identity macOS keys a virtual display's saved state on.
struct VirtualDisplayIdentity: Hashable {
    let serial: UInt32
    let productID: UInt32
}

/// Every MeowDisplay virtual display alive in this process, and which
/// session owns it. Lets Mirror's Automatic exclude other devices' extended
/// desktops, lets a new Extend display skip an identity another live session
/// already holds (instead of retrying creation into a refusal for ~16 s),
/// and gives teardown a checkable record. `VirtualDisplay` registers on
/// successful creation and unregisters on release, so every teardown path is
/// covered by the object's own lifetime.
final class VirtualDisplayRegistry: @unchecked Sendable {
    static let shared = VirtualDisplayRegistry()

    struct Entry: Equatable {
        let displayID: CGDirectDisplayID
        let identity: VirtualDisplayIdentity
        let owner: ObjectIdentifier?
    }

    private let lock = NSLock()
    /// Keyed by the registering `VirtualDisplay` instance, not its display
    /// ID: a late release of an old display must never remove a newer one
    /// that WindowServer gave the same ID.
    private var entries: [ObjectIdentifier: Entry] = [:]

    func register(_ instance: ObjectIdentifier, displayID: CGDirectDisplayID,
                  identity: VirtualDisplayIdentity, owner: ObjectIdentifier?) {
        lock.lock()
        defer { lock.unlock() }
        entries[instance] = Entry(displayID: displayID, identity: identity, owner: owner)
    }

    func unregister(_ instance: ObjectIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: instance)
    }

    var displayIDs: Set<CGDirectDisplayID> {
        lock.lock()
        defer { lock.unlock() }
        return Set(entries.values.map(\.displayID))
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Whether a live display owned by someone other than `owner` already
    /// uses `identity`. A session's own (lingering) display is not a
    /// collision — the existing retry window handles that.
    func isClaimed(_ identity: VirtualDisplayIdentity, byOtherThan owner: ObjectIdentifier?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.contains { $0.identity == identity && (owner == nil || $0.owner != owner) }
    }

    func displayIDs(ownedBy owner: ObjectIdentifier) -> Set<CGDirectDisplayID> {
        lock.lock()
        defer { lock.unlock() }
        return Set(entries.values.filter { $0.owner == owner }.map(\.displayID))
    }
}

/// Which identity offsets an Extend setup tries, in order. macOS refuses to
/// create a display whose identity a live display already holds, so probing
/// one held by ANOTHER live session would only burn the retry window before
/// moving on. Those are skipped up front; a session's own lingering display
/// is not (its serial frees up within the retry window). A skipped offset is
/// a live collision, not saved-state poisoning, so it is never persisted.
enum VirtualDisplayIdentityPlanner {
    static let baseProductID: UInt32 = 0x4F53

    static func identity(serial: UInt32, offset: UInt32) -> VirtualDisplayIdentity {
        VirtualDisplayIdentity(serial: serial &+ offset, productID: baseProductID &+ offset)
    }

    static func offsets(serial: UInt32, baseOffset: UInt32, probes: UInt32 = 3,
                        isClaimedByAnotherSession: (VirtualDisplayIdentity) -> Bool) -> [UInt32] {
        var offsets: [UInt32] = []
        var candidate = baseOffset
        // Bounded: never more than `probes` attempts, and never scanning
        // further than a few identities past them for free ones.
        var scanned: UInt32 = 0
        while UInt32(offsets.count) < probes, scanned < probes &* 4 {
            if !isClaimedByAnotherSession(identity(serial: serial, offset: candidate)) {
                offsets.append(candidate)
            }
            candidate &+= 1
            scanned += 1
        }
        return offsets
    }
}
