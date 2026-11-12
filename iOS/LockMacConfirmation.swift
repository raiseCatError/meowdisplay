import SwiftUI

/// What Lock Mac shows, in Settings ▸ Input and in Session Actions. The decisions are in
/// `LockMacFlow`; this is only words and a confirmation dialog.
extension WorkspaceModel {
    /// Waiting for control or for the Mac's lock answer.
    var lockMacBusy: Bool { lockFlow.isAwaiting || lockMacStatus == .locking }

    /// The latest truthful line: waiting, why the flow stopped, or what the Mac reported.
    var lockMacStatusLine: String? {
        if lockFlow.isAwaiting { return LockMacFlow.awaitingText }
        if let notice = lockFlow.notice { return LockMacFlow.text(notice) }
        if case .done(let result)? = lockMacStatus { return LockMacResult.receiverText(result) }
        return nil
    }
}

extension LockMacResult {
    static func receiverText(_ result: LockMacResult) -> String {
        switch result {
        case .locked: String(localized: "The Mac is locked.")
        case .control: String(localized: "The Mac didn't lock because this device doesn't have control of it.")
        case .accessibility: String(localized: "The Mac can't lock: turn on MeowDisplay in System Settings ▸ Privacy & Security ▸ Accessibility on the Mac.")
        case .failed: String(localized: "The Mac didn't lock. Its Lock Screen shortcut (Control-Command-Q) may be changed or off.")
        }
    }
}

/// The "Lock the Mac?" confirmation. Attach it to a view of the host that is on screen (not
/// under a sheet). Cancel, a tap outside or Esc send nothing.
struct LockMacConfirmation: ViewModifier {
    @ObservedObject var workspace: WorkspaceModel
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .confirmationDialog(workspace.lockFlow.confirmTitle, isPresented: $showing, titleVisibility: .visible) {
                Button(workspace.lockFlow.confirmButtonTitle) { workspace.confirmLockMac() }
                    .accessibilityIdentifier(workspace.lockFlow.confirmingPath == .lockNow
                                             ? "lockMacConfirm" : "lockMacRequestControlAndLock")
                Button("Cancel", role: .cancel) { workspace.cancelLockMac() }
                    .accessibilityIdentifier("lockMacCancel")
            } message: {
                Text(workspace.lockFlow.confirmMessage)
            }
            .onChange(of: workspace.lockFlow.isConfirming) { showing = $0 }
            // Dismissed without a button (tap outside): nothing was confirmed.
            .onChange(of: showing) { shown in
                if !shown, workspace.lockFlow.isConfirming { workspace.cancelLockMac() }
            }
    }
}

extension View {
    func lockMacConfirmation(_ workspace: WorkspaceModel) -> some View {
        modifier(LockMacConfirmation(workspace: workspace))
    }
}
