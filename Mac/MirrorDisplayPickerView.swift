import SwiftUI

/// Only meaningful for Mirror mode — Extend always uses MEOW's own virtual
/// display, so this view only ever appears when `controller.mode == .mirror`.
struct MirrorDisplayPickerView: View {
    @ObservedObject var controller: SenderController
    @State private var candidates: [MirrorDisplayCandidate] = []
    @State private var loaded = false

    private var selected: MirrorDisplayCandidate? {
        guard let uuid = controller.mirrorDisplayUUID else { return nil }
        return candidates.first { $0.persistentID == uuid }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Mirror Display", selection: Binding(
                // A remembered display that is disconnected (or not loaded
                // yet) has no tag; it shows as Automatic, which is what
                // capture uses meanwhile. The stored choice is kept.
                get: {
                    PickerSelection.valid(controller.mirrorDisplayUUID ?? "",
                                          among: candidates.compactMap(\.persistentID), fallback: "")
                },
                set: { controller.mirrorDisplayUUID = $0.isEmpty ? nil : $0 })) {
                Text("Automatic").tag("")
                ForEach(candidates) { candidate in
                    Text(candidate.label)
                        .tag(candidate.persistentID ?? "")
                        .disabled(candidate.persistentID == nil)
                }
            }
            if let selected {
                Text(selected.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if controller.mirrorDisplayUUID != nil, loaded {
                Text("Selected display isn't currently available — using Automatic until it reconnects.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .task {
            candidates = await MirrorDisplayCandidate.listCandidates()
            loaded = true
        }
    }
}
