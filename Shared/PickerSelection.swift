import Foundation

/// Keeps a SwiftUI `Picker` selection representable: a stored value whose
/// option is not currently offered (a forgotten peer, a disconnected
/// display, options still loading) is shown as `fallback` — itself a real
/// tag, such as "Select…" or "Automatic" — instead of a value with no tag.
/// Pure: used from a Binding getter, it never rewrites the stored value, so
/// a remembered choice reappears when its option does.
enum PickerSelection {
    static func valid<Value: Equatable>(_ stored: Value, among tags: [Value], fallback: Value) -> Value {
        tags.contains(stored) ? stored : fallback
    }

    /// The same for a ceiling picker whose tags are only the values that
    /// are reachable right now (Maximum FPS: a 60 Hz display, or an encode
    /// size too large for 120, hides the higher tiers). A stored ceiling
    /// that is not offered shows as the highest tag at or below it — the
    /// limit that actually applies, since everything above the offered
    /// tags is clamped away anyway — or as the lowest tag when it sits
    /// below them all. With no tags at all there is nothing valid to show,
    /// so `stored` comes back unchanged; callers offer at least one tag.
    static func ceiling<Value: Comparable>(_ stored: Value, among tags: [Value]) -> Value {
        if tags.contains(stored) { return stored }
        return tags.filter { $0 <= stored }.max() ?? tags.min() ?? stored
    }
}
