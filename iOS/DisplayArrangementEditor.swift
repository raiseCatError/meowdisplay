import SwiftUI

// Full-screen editor for the Mac's display arrangement (PROTOCOL.md 6.10, Display arrangement),
// opened from the Stage Peek gallery's arrangement map. Drags go through
// `DisplayArrangementEdit` (snapping, validation); Apply sends the request, and the Mac asks its
// owner, applies for a short while and reverts unless Keep is tapped here. Nothing on this
// device changes the Mac without that answer on the Mac.

struct DisplayArrangementEditor: View {
    @ObservedObject var model: WorkspaceModel
    let onClose: () -> Void
    @State private var edit: DisplayArrangementEdit
    /// The dragged display and its origin when the finger went down.
    @State private var drag: (id: UInt32, start: CGPoint)?
    /// Held while a finger drags, so the picture doesn't rescale under it.
    @State private var frozenCamera: OverviewCamera?
    /// The catalog changed under an unsent edit: it started over from the new arrangement.
    @State private var restarted = false

    /// Finger distance (view points) within which a display snaps to a neighbour.
    private static let snapViewDistance: CGFloat = 28

    init(model: WorkspaceModel, overview: DisplayOverviewModel, onClose: @escaping () -> Void) {
        self._model = ObservedObject(wrappedValue: model)
        self.onClose = onClose
        self._edit = State(initialValue: DisplayArrangementEdit(model: overview))
    }

    private var status: DisplayArrangeStatus? { model.displayArrangeStatus }
    private var busy: Bool { status?.isInProgress ?? false }
    private var problem: DisplayArrangementProblem? { edit.validate() }
    private var canApply: Bool {
        !busy && edit.isChanged && problem == nil && model.canArrangeDisplays && model.canControlMac
    }

    var body: some View {
        VStack(spacing: 0) {
            DisplayArrangementEditorHeader(
                canApply: canApply, finished: isFinishedChange,
                onCancel: cancel, onApply: apply)
            canvas
            DisplayArrangementEditorFooter(
                status: status, problem: edit.isChanged ? problem : nil, restarted: restarted,
                needsControl: !model.canControlMac,
                onKeep: { model.keepDisplayArrangement() },
                onRevert: { model.revertDisplayArrangement() })
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { model.displayArrangementEditorOpen = true; model.clearDisplayArrangeStatus() }
        // Closed some other way (the peek went away): never leave a request or an unkept
        // arrangement behind it.
        .onDisappear {
            model.displayArrangementEditorOpen = false
            if busy { model.revertDisplayArrangement() }
        }
        .onChange(of: model.catalog?.displays ?? []) { displays in catalogChanged(displays) }
        .onChange(of: status) { newStatus in
            switch newStatus {
            case .finished(.kept, _): edit.acceptKeptArrangement()
            case .finished(.reverted, _): edit.reset()
            default: break
            }
        }
    }

    /// Kept or reverted: the editor's starting point is no longer the Mac's arrangement.
    private var isFinishedChange: Bool {
        if case .finished(let state, _) = status { return state == .kept || state == .reverted }
        return false
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let camera = frozenCamera ?? Self.camera(for: edit, in: geometry.size)
            let flagged = Self.flaggedIDs(edit.isChanged ? problem : nil)
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(edit.displays) { display in
                    tile(display, camera: camera, viewport: geometry.size, flagged: flagged.contains(display.id))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .padding(.horizontal, 12)
    }

    private func tile(_ display: ArrangementDisplay, camera: OverviewCamera, viewport: CGSize, flagged: Bool) -> some View {
        let rect = camera.viewRect(world: display.frame, viewport: viewport)
        let movable = display.isMovable && !busy
        return DisplayArrangementEditorTile(display: display, flagged: flagged, lifted: drag?.id == display.id,
                                            movable: display.isMovable, showsName: rect.height >= 30)
            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
            .position(x: rect.midX, y: rect.midY)
            .gesture(dragGesture(for: display, camera: camera), including: movable ? .all : .subviews)
    }

    private func dragGesture(for display: ArrangementDisplay, camera: OverviewCamera) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if drag?.id != display.id {
                    model.clearDisplayArrangeStatus()
                    restarted = false
                    drag = (display.id, display.frame.origin)
                    frozenCamera = camera
                }
                guard let start = drag?.start else { return }
                let scale = CGFloat((frozenCamera ?? camera).scale)
                let proposed = CGPoint(x: start.x + value.translation.width / scale,
                                       y: start.y + value.translation.height / scale)
                edit.move(display.id, to: proposed, snapDistance: Self.snapViewDistance / scale)
            }
            .onEnded { _ in
                drag = nil
                withAnimation(.easeOut(duration: 0.25)) { frozenCamera = nil }
            }
    }

    private func apply() {
        restarted = false
        model.clearDisplayArrangeStatus()
        model.requestDisplayArrangement(edit)
    }

    /// Cancel/Done: an unanswered request is withdrawn and an unkept arrangement put back.
    private func cancel() {
        model.revertDisplayArrangement()
        onClose()
    }

    /// A new catalog: once nothing is under way, the edit starts again from the Mac's real
    /// arrangement (an edit of an older one would be refused as stale anyway).
    private func catalogChanged(_ displays: [CatalogDisplayItem]) {
        guard !busy, drag == nil else { return }
        let overview = DisplayOverviewModel(catalog: displays)
        guard overview.drawnDisplays.count >= 2, overview.hasArrangement else { return }
        let next = DisplayArrangementEdit(model: overview)
        guard next.original.sorted(by: { $0.id < $1.id }) != edit.original.sorted(by: { $0.id < $1.id }) else { return }
        restarted = edit.isChanged && !isFinishedChange
        edit = next
    }

    /// Fit-all around where the displays started and where they are now.
    private static func camera(for edit: DisplayArrangementEdit, in size: CGSize) -> OverviewCamera {
        OverviewCamera.fitAll(bounds: edit.bounds.union(edit.originalBounds), viewport: size, margin: 0.12)
    }

    private static func flaggedIDs(_ problem: DisplayArrangementProblem?) -> Set<UInt32> {
        switch problem {
        case .overlap(let a, let b): return [a, b]
        case .disconnected(let id), .notMovable(let id), .invalidOrigin(let id), .mirrorMember(let id),
             .unknownDisplay(let id):
            return [id]
        case .empty, .noMainDisplay, nil: return []
        }
    }
}

/// Presents the editor full screen while `overview` is set (the gallery's Arrange…).
struct DisplayArrangementEditorPresentation: ViewModifier {
    @ObservedObject var model: WorkspaceModel
    @Binding var overview: DisplayOverviewModel?

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: Binding(get: { overview != nil }, set: { if !$0 { overview = nil } })) {
            if let start = overview {
                DisplayArrangementEditor(model: model, overview: start, onClose: { overview = nil })
            }
        }
    }
}

// MARK: - Pieces

/// Cancel (Done once the Mac kept or reverted it), the title, Apply.
private struct DisplayArrangementEditorHeader: View {
    let canApply: Bool
    let finished: Bool
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        HStack {
            Button(finished ? String(localized: "Done") : String(localized: "Cancel"), action: onCancel)
            Spacer()
            Text("Arrange Displays (Beta)").font(.headline)
            Spacer()
            Button("Apply", action: onApply)
                .fontWeight(.semibold)
                .disabled(!canApply)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// One display: its name, the main display's menu bar cue, red when it is what makes the
/// arrangement invalid. Another device's MeowDisplay screen is dashed and can't be dragged.
private struct DisplayArrangementEditorTile: View {
    let display: ArrangementDisplay
    let flagged: Bool
    let lifted: Bool
    let movable: Bool
    let showsName: Bool

    private var title: String {
        if display.isOwn { return UIDevice.current.userInterfaceIdiom == .pad ? String(localized: "This iPad") : String(localized: "This iPhone") }
        if display.isMeow { return String(localized: "MeowDisplay") }
        return display.name.isEmpty ? String(localized: "Display") : display.name
    }

    private var stroke: Color {
        if flagged { return .red }
        return lifted ? meowAccent : Color.white.opacity(0.5)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        shape.fill(flagged ? Color.red.opacity(0.25) : Color.white.opacity(display.isMeow ? 0.06 : 0.14))
            .overlay(alignment: .top) { if display.isMain { Rectangle().fill(Color.white.opacity(0.6)).frame(height: 3) } }
            .clipShape(shape)
            .overlay(shape.strokeBorder(stroke, style: StrokeStyle(lineWidth: lifted || flagged ? 2 : 1, dash: movable ? [] : [4, 3])))
            .overlay { if showsName { label } }
            .scaleEffect(lifted ? 1.02 : 1)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(display.isMain ? String(localized: "\(title), main display") : title)
            .accessibilityHint(movable ? String(localized: "Drag to move it.") : String(localized: "Can't be moved from here."))
    }

    private var label: some View {
        VStack(spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            if display.mirrorMemberIDs.count > 0 {
                Text("Mirrored").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(4)
    }
}

/// What's wrong with the layout, or where the request is: Confirm on your Mac, the Keep /
/// Revert banner with its countdown, then the outcome.
private struct DisplayArrangementEditorFooter: View {
    let status: DisplayArrangeStatus?
    let problem: DisplayArrangementProblem?
    let restarted: Bool
    let needsControl: Bool
    let onKeep: () -> Void
    let onRevert: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            content
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .frame(minHeight: 96)
    }

    @ViewBuilder private var content: some View {
        switch status {
        case .sending?, .awaitingMacConfirm?:
            HStack(spacing: 8) {
                ProgressView()
                Text("Confirm on your Mac…")
            }
            Button("Cancel Request", action: onRevert).font(.footnote)
        case .applied(let revertAt)?:
            DisplayArrangementKeepBanner(revertAt: revertAt, onKeep: onKeep, onRevert: onRevert)
        case .keeping?:
            HStack(spacing: 8) { ProgressView(); Text("Keeping…") }
        case .reverting?:
            HStack(spacing: 8) { ProgressView(); Text("Reverting…") }
        case .finished(let state, let reason)?:
            Text(Self.outcome(state, reason: reason))
                .multilineTextAlignment(.center)
                .foregroundStyle(state == .kept ? Color.primary : Color.secondary)
        case nil:
            idle
        }
    }

    @ViewBuilder private var idle: some View {
        if let problem {
            Label(Self.text(for: problem), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        } else if restarted {
            Text("The Mac's displays changed, so the arrangement started over.").foregroundStyle(.secondary)
        } else if needsControl {
            Text("Request Control to rearrange the Mac's displays.").foregroundStyle(.secondary)
        } else {
            Text("Drag a display to move it. The Mac asks before anything changes.").foregroundStyle(.secondary)
        }
    }

    static func text(for problem: DisplayArrangementProblem) -> String {
        switch problem {
        case .overlap: return String(localized: "Displays can't overlap.")
        case .disconnected: return String(localized: "Each display must touch another along an edge.")
        case .notMovable: return String(localized: "Another device's MeowDisplay screen can't be moved from here.")
        case .mirrorMember: return String(localized: "Mirrored displays move together.")
        case .invalidOrigin: return String(localized: "A display can't go there.")
        case .noMainDisplay, .unknownDisplay, .empty: return String(localized: "This arrangement can't be applied.")
        }
    }

    static func outcome(_ state: DisplayArrangeState, reason: String?) -> String {
        switch state {
        case .kept:
            return String(localized: "The new arrangement is kept.")
        case .reverted:
            switch reason {
            case DisplayArrangeReason.timeout?: return String(localized: "Not kept in time: the previous arrangement is back.")
            case DisplayArrangeReason.sessionEnded?: return String(localized: "The connection ended: the Mac put the previous arrangement back.")
            case DisplayArrangeReason.control?: return String(localized: "Control ended: the previous arrangement is back.")
            default: return String(localized: "The previous arrangement is back.")
            }
        case .denied:
            switch reason {
            case DisplayArrangeReason.declined?: return String(localized: "Not allowed on the Mac.")
            case DisplayArrangeReason.timeout?: return String(localized: "Nobody answered on the Mac.")
            case DisplayArrangeReason.control?: return String(localized: "Request Control first.")
            case DisplayArrangeReason.busy?: return String(localized: "Another arrangement change is waiting on the Mac.")
            case DisplayArrangeReason.stale?: return String(localized: "The Mac's displays changed. Try again.")
            case DisplayArrangeReason.requested?: return String(localized: "Request cancelled.")
            case DisplayArrangeReason.sessionEnded?: return String(localized: "The connection ended before the Mac answered.")
            default: return String(localized: "The Mac didn't accept this arrangement.")
            }
        case .failed:
            if reason == DisplayArrangeReason.sessionEnded {
                return String(localized: "The connection ended. Check the arrangement on the Mac.")
            }
            return String(localized: "macOS didn't apply this arrangement, so nothing was changed.")
        case .awaitingMacConfirm, .applied:
            return ""
        }
    }
}

/// "Keep this arrangement? Reverting in N s" with Keep and Revert.
private struct DisplayArrangementKeepBanner: View {
    let revertAt: Date
    let onKeep: () -> Void
    let onRevert: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(revertAt.timeIntervalSince(context.date).rounded(.up)))
            Text("Keep this arrangement? Reverting in \(left) s")
                .font(.headline)
                .monospacedDigit()
        }
        HStack(spacing: 12) {
            Button("Revert", action: onRevert)
                .buttonStyle(.bordered)
            Button("Keep", action: onKeep)
                .buttonStyle(.borderedProminent)
                .tint(meowAccent)
        }
    }
}
