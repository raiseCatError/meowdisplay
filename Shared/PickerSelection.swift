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
}
