import SwiftUI

/// A Mac app's icon as the Mac sent it or, until it arrives (or when the Mac has none), one quiet
/// placeholder: a neutral rounded tile with the app's initial (Finder: its blue face). The same
/// wherever an app is shown: pane and float titles, Stage Peek and its dock.
struct WorkspaceAppIcon: View {
    let icon: CGImage?
    let name: String
    var bundleID: String?
    var size: CGFloat
    /// The placeholder's letter (and, faintly, its tile): match the text beside it.
    var tint: Color = .white

    var body: some View {
        Group {
            if let icon {
                Image(decorative: icon, scale: 1).resizable().interpolation(.high)
            } else if bundleID == MacAppItem.finderBundle {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.72, blue: 1), Color(red: 0.13, green: 0.45, blue: 0.95)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Image(systemName: "face.smiling").font(.system(size: size * 0.55)).foregroundStyle(.white))
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(tint.opacity(0.16))
                    .overlay(Group {
                        if let letter = AppIconRequestPlanner.initial(of: name) {
                            Text(letter).font(.system(size: size * (size < 24 ? 0.6 : 0.45), weight: .semibold))
                        } else {
                            Image(systemName: "macwindow").font(.system(size: size * 0.45, weight: .semibold))
                        }
                    }
                    .foregroundStyle(tint))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
