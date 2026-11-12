import Foundation

/// What a tap or a hold on a pane's title label does; `WorkspaceView` applies it. Pure, tested.
///
/// Beside the Mac's menu bar a pane's titles fold to the shown tab's icon (and "+N"). One hold on
/// that icon opens its options with the titles shown in full; a tap on it (it's the selected
/// pane's) shows them in full; a double tap still toggles Fullscreen on This Device.
enum PaneLabelInteraction {
    /// A pane's label, or one of its tabs' labels.
    struct Target: Equatable, Sendable {
        var tile: String
        var tab: Int?
    }

    /// A tap that acted: for telling a double tap from two single taps.
    struct Tap: Equatable, Sendable {
        var target: Target
        var at: TimeInterval
        /// On the folded (icon only) label.
        var folded: Bool
    }

    enum TapAction: Equatable, Sendable {
        /// The second tap of a double tap: Fullscreen on This Device, or the layout back.
        case toggleFullscreen
        /// Show that tab; `expand`: show every title in full for a while.
        case showTab(Int, expand: Bool)
        /// Select the pane (typing goes there); `expand`: show every title in full for a while.
        case select(expand: Bool)
    }

    enum HoldEnd: Equatable, Sendable {
        /// A drag began from the hold: drop it where the finger is.
        case drop
        /// Released without moving: the label's options; `expand`: the titles were folded.
        case menu(expand: Bool)
        /// The system cancelled the hold mid-drag: the drag is cancelled, nothing is dropped.
        case cancelDrag
        case nothing
    }

    /// Matches UIKit's default double-tap timing.
    static let doubleTapInterval: TimeInterval = 0.35

    /// The first tap acts at once (no waiting to see whether another follows). The second tap
    /// counts on the same label, or anywhere on the same pane's titles when the first was on the
    /// folded icon: that tap unfolded them, so a different label may now be under the finger.
    /// `held`: a label is held right now (its hold or drag owns the touch): a tap does nothing.
    static func tap(_ target: Target, shown: Bool, highlighted: Bool, folded: Bool,
                    last: Tap?, now: TimeInterval, held: Bool) -> TapAction? {
        guard !held else { return nil }
        if let last, now >= last.at, now - last.at < doubleTapInterval,
           last.target == target || (last.folded && last.target.tile == target.tile) {
            return .toggleFullscreen
        }
        // Working with tabs keeps them all shown for a while; the selected pane's folded icon
        // shows its titles in full.
        let expand = target.tab != nil || (folded && highlighted)
        if let tab = target.tab, !shown { return .showTab(tab, expand: expand) }
        return .select(expand: expand)
    }

    /// The hold's gesture ended (`cancelled`: the system took the touch, so no `onEnded`).
    /// `heldHere`: this label is the one held. `folded`: it was held in the folded strip.
    static func holdEnded(cancelled: Bool, dragging: Bool, heldHere: Bool, folded: Bool) -> HoldEnd {
        if cancelled { return dragging ? .cancelDrag : .nothing }
        if dragging { return .drop }
        return heldHere ? .menu(expand: folded) : .nothing
    }

    /// Whether a pane's titles show folded (the shown tab's icon and "+N"). `heldFolded`: while a
    /// label of this pane is held (or dragged from), the form it was held in, kept until the
    /// finger lifts. Switching then would replace the view carrying the gesture, which cancels
    /// it: no menu and no drop, and the hold had to be repeated on the unfolded label.
    static func folded(sharesRow: Bool, hasWindows: Bool, expanded: Bool, held: Bool, dragging: Bool,
                       heldFolded: Bool?) -> Bool {
        if let heldFolded { return heldFolded }
        return sharesRow && hasWindows && !expanded && !held && !dragging
    }
}
