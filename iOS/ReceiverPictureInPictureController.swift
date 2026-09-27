import AVFoundation
import AVKit
import CoreMedia
import os
import SwiftUI

/// Native Picture in Picture for the receiver, fed by the same
/// `AVSampleBufferDisplayLayer` the receiver already decodes into — no second
/// stream, decoder, or layer. View-only by design: the floating window shows
/// the Mac, and its restore button is the way back into the full receiver.
///
/// Policy lives in `ReceiverPictureInPictureConditions` and
/// `ReceiverPictureInPictureLifecycle` (Shared, unit-tested); this type only
/// owns the AVKit objects and reports their callbacks into that policy.
@MainActor
final class ReceiverPictureInPictureController: NSObject, ObservableObject {
    @Published private(set) var conditions = ReceiverPictureInPictureConditions.inactive
    /// AVKit's `isPictureInPicturePossible` for the current controller.
    @Published private(set) var isPossible = false
    @Published private(set) var lifecycle = ReceiverPictureInPictureLifecycle()

    /// PiP started after the scene had already backgrounded and lingered —
    /// resume rendering and recovery so the window shows a live picture.
    var onStartedAfterLinger: (() -> Void)?
    /// PiP ended while the app is still in the background — apply the linger
    /// that was held off while the window was showing.
    var onEndedInBackground: (() -> Void)?

    let systemSupported = AVPictureInPictureController.isPictureInPictureSupported()

    private let displayLayer: AVSampleBufferDisplayLayer
    private let playbackSource = ReceiverPictureInPicturePlaybackSource()
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init()
    }

    var availability: ReceiverPictureInPictureAvailability {
        conditions.availability(systemPossible: isPossible)
    }

    var isShowingWindow: Bool { lifecycle.isShowingWindow }

    // MARK: - Receiver state

    func update(_ newConditions: ReceiverPictureInPictureConditions) {
        if newConditions != conditions { conditions = newConditions }
        if newConditions.hostsController {
            installControllerIfNeeded()
        } else if !lifecycle.isEngaged {
            tearDownController()
        }
        guard let controller else { return }
        // Only a live session may carry the picture into the background on
        // its own; an interrupted or Video Off session never auto-starts.
        controller.canStartPictureInPictureAutomaticallyFromInline = newConditions.showsLiveVideo
        if playbackSource.setPaused(!newConditions.showsLiveVideo) {
            controller.invalidatePlaybackState()
        }
        if lifecycle.isShowingWindow, !newConditions.sustainsActiveWindow {
            Log.info("pip: closing — session no longer shows the Mac")
            controller.stopPictureInPicture()
        }
    }

    func start() {
        guard availability == .available, let controller else { return }
        controller.startPictureInPicture()
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    // MARK: - App lifecycle

    func sceneDidBackground(deviceLocked: Bool) -> ReceiverPictureInPictureLifecycle.BackgroundAction {
        lifecycle.sceneDidBackground(deviceLocked: deviceLocked)
    }

    func sceneDidActivate() {
        if lifecycle.sceneDidActivate() {
            Log.info("pip: returned to the app — restoring the full receiver")
            stop()
        }
    }

    func deviceWillLock() {
        lifecycle.deviceWillLock()
    }

    // MARK: - Controller ownership

    private func installControllerIfNeeded() {
        guard controller == nil else { return }
        // Picture in Picture requires the playback category. Same category
        // and options the receiver's own audio path sets, so neither
        // overrides the other and other apps' audio keeps playing.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        } catch {
            Log.info("pip: audio session category failed: \(error)")
        }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer, playbackDelegate: playbackSource)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        // Live content: no seeking or skipping.
        controller.requiresLinearPlayback = true
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
            @Sendable [weak self] _, change in
            let possible = change.newValue ?? false
            Task { @MainActor in self?.setPossible(possible) }
        }
        self.controller = controller
        Log.info("pip: controller installed")
    }

    private func tearDownController() {
        guard controller != nil else { return }
        possibleObservation?.invalidate()
        possibleObservation = nil
        controller?.delegate = nil
        controller = nil
        if isPossible { isPossible = false }
        Log.info("pip: controller removed")
    }

    private func setPossible(_ possible: Bool) {
        guard controller != nil, possible != isPossible else { return }
        isPossible = possible
    }

    private func pictureInPictureEnded() {
        if lifecycle.pictureInPictureDidEnd() {
            Log.info("pip: ended in the background — pausing rendering")
            onEndedInBackground?()
        }
        // A stop forced by the session/preference going away deferred the
        // teardown until AVKit finished with the layer.
        if !conditions.hostsController { tearDownController() }
    }
}

// AVKit delivers these on the main thread; the conformance is main-actor
// isolated and checked at runtime rather than assumed.
extension ReceiverPictureInPictureController: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Log.info("pip: starting")
        if lifecycle.pictureInPictureWillStart() {
            Log.info("pip: started after backgrounding — resuming rendering")
            onStartedAfterLinger?()
        }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        lifecycle.pictureInPictureDidStart()
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        Log.info("pip: failed to start: \(error)")
        pictureInPictureEnded()
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        lifecycle.pictureInPictureWillStop()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Log.info("pip: stopped")
        pictureInPictureEnded()
    }

    /// The full receiver is always behind the window while PiP can run, so
    /// restoring never needs to rebuild anything.
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

/// The sample-buffer playback delegate. The stream is live and view-only:
/// the timeline is open-ended, skipping is a no-op, and play/pause can't
/// pause the Mac, so the window's playing state always follows the session
/// (paused while the Mac is paused or the connection is recovering).
///
/// AVKit doesn't document which thread calls these, so the one piece of
/// state sits behind a lock instead of an actor.
final class ReceiverPictureInPicturePlaybackSource: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate,
    Sendable {
    private let paused = OSAllocatedUnfairLock(initialState: true)

    /// Returns whether the value changed.
    func setPaused(_ value: Bool) -> Bool {
        paused.withLock { current in
            guard current != value else { return false }
            current = value
            return true
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        // View-only: nothing to pause. Re-read the real state so the button
        // snaps back to it.
        pictureInPictureController.invalidatePlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // Infinite duration marks live content.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        paused.withLock { $0 }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

/// Covers the receiver surface while the picture is in the floating window,
/// as system players do, and keeps touches from reaching the Mac from a
/// surface that isn't showing anything.
struct ReceiverPictureInPicturePlaceholder: View {
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                Image(systemName: "pip")
                    .font(.system(size: 44, weight: .regular))
                Text("Showing in Picture in Picture")
                    .font(.headline)
            }
            .foregroundStyle(.white.opacity(0.7))
            .accessibilityElement(children: .combine)
        }
        .ignoresSafeArea()
    }
}
