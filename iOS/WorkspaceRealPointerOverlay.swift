import SwiftUI

/// Window mode, while the Trackpad drives the Mac (owner's QA of 9000083): a small pointer in
/// each Full Desktop pane where the Mac's real pointer is, so the pane follows the Trackpad
/// even when its own picture lags. A window pane's own pointer stays as it is, full size. The
/// mark fades with the controls tray once the pointer rests. Drawing only: it takes no touches.
struct WorkspaceRealPointerOverlay: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var cursor: TrackpadCursorPresentation
    let displays: [TrackpadDisplayGeometry]
    let picture: CGRect
    /// The controls tray is auto-hidden now.
    let controlsHidden: Bool
    /// Where the Mac draws its own cursor (normalized picture), nil while hidden.
    @ObservedObject var echo: CursorEchoPresentation

    @State private var resting = false
    @State private var restTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let restDelay: Duration = .milliseconds(1500)

    var body: some View {
        let marks = cursor.location.map { model.realPointerMarks(cursor: $0, displays: displays, picture: picture, echo: echo.echo) } ?? [:]
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(marks.keys.sorted(), id: \.self) { id in
                if let p = marks[id] {
                    SmallPointer()
                        .frame(width: SmallPointer.size.width, height: SmallPointer.size.height)
                        // The arrow's tip is the point.
                        .position(x: p.x + SmallPointer.size.width / 2, y: p.y + SmallPointer.size.height / 2)
                }
            }
        }
        .opacity(controlsHidden && resting ? 0 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: controlsHidden && resting)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: cursor.location) { _ in
            resting = false
            restTask?.cancel()
            restTask = Task { @MainActor in
                try? await Task.sleep(for: Self.restDelay)
                guard !Task.isCancelled else { return }
                resting = true
            }
        }
        .onDisappear { restTask?.cancel() }
    }
}

/// A small classic arrow: dark fill, light edge, a soft shadow so it reads on any picture.
private struct SmallPointer: View {
    static let size = CGSize(width: 11, height: 16)

    var body: some View {
        let shape = PointerShape()
        shape.fill(Color.black.opacity(0.85))
            .overlay(shape.stroke(Color.white, style: StrokeStyle(lineWidth: 1.1, lineJoin: .round)))
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
    }
}

private struct PointerShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + h * 0.80))
        p.addLine(to: CGPoint(x: r.minX + w * 0.27, y: r.minY + h * 0.62))
        p.addLine(to: CGPoint(x: r.minX + w * 0.47, y: r.minY + h * 0.98))
        p.addLine(to: CGPoint(x: r.minX + w * 0.64, y: r.minY + h * 0.90))
        p.addLine(to: CGPoint(x: r.minX + w * 0.45, y: r.minY + h * 0.56))
        p.addLine(to: CGPoint(x: r.minX + w, y: r.minY + h * 0.56))
        p.closeSubpath()
        return p
    }
}
