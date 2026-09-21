import CoreMedia
import Foundation
import VideoToolbox

// MacSenderVideoEncoder — sole owner of the sender's `VTCompressionSession`.
//
// Before this extraction the session lived on `MacSender` as a bare
// `private var encoder: VTCompressionSession?`, created, configured,
// submitted to and invalidated from three different execution domains:
//
//   * `queue` (`sender.video`) — `encode`, `applyVideoEnabled`,
//     `pauseDisplay`'s completion, `transitionToMirrorAndDisableVideo`;
//   * the Swift concurrency cooperative pool — `startCapture`,
//     `reconfigure`, `resumeCapture` are plain nonisolated `async` methods
//     on a non-isolated class, so they do NOT run on `queue`;
//   * the main thread — `stop()` is called straight from `@MainActor`
//     SwiftUI/controller code.
//
// plus the VideoToolbox output thread, which read `MacSender.activeCodec`
// (queue-written) to decide H.264 vs HEVC parameter-set extraction. None of
// that was synchronized.
//
// CONFINEMENT INVARIANT — the single, documented reason this type is
// `@unchecked Sendable`:
//
//   Every mutable field (`session`, `sessionCodec`, `sessionToken`) is read
//   and written ONLY while `lock` is held, and no VideoToolbox call that can
//   re-enter this type is ever made while holding it.
//
// The second half of that invariant is load-bearing, not decoration:
// `VTCompressionSessionInvalidate` may synchronously drain outstanding
// output handlers, and `VTCompressionSessionEncodeFrame` may invoke its
// handler synchronously for a frame it drops. Both handlers call back into
// `codec(ifCurrent:)`, which takes `lock` — so `invalidate()` retires the
// session under the lock, releases it, and only then calls VideoToolbox, and
// `submit` copies the session reference out under the lock and submits with
// the lock released. `lock` is a plain `NSLock` (non-recursive), so doing
// either the other way around would deadlock.
//
// SESSION IDENTITY. `sessionToken` is a monotonic identity for "the session
// that is current right now". It is bumped on every retire and on every
// create, and each submission's output handler is handed the codec of the
// session it was submitted to, or `nil` once that session has been replaced.
// That is what makes stale output rejectable: VideoToolbox can deliver a
// frame encoded by session A after session B has already become current, and
// such a frame must never be packaged with B's codec nor published as if B
// produced it.
//
// Deliberately NOT owned here: `needsKeyframe` (a MacSender streaming/
// recovery policy — see its declaration; every write is a session-level
// reason, never an encoder mechanism, so the encoder takes an immutable
// per-submission `forceKeyframe` decision instead), pending-encode/send
// accounting (`MacSenderPipelineState`), codec SELECTION
// (`CodecSelectionPolicy`, via `MacSender.setupEncoder`'s fallback ladder),
// frame admission (`FrameRateLimiter`) and everything transport-side.
@available(macOS 14.0, *)
final class MacSenderVideoEncoder: @unchecked Sendable {

    /// Everything fixed at session creation. Nothing here is updated in
    /// place: every reconfiguration in this codebase (bitrate, FPS,
    /// resolution, codec) recreates the session, so there is no
    /// `VTSessionSetProperty` path outside `create`.
    struct Configuration {
        let width: Int
        let height: Int
        let fps: Int
        let bitrate: Int
        let codec: StreamCodec
        /// Request an encoder that supports low-latency rate control. The
        /// spec FILTERS which encoder VideoToolbox may pick, so an encoder
        /// without the mode fails creation outright rather than ignoring the
        /// key — the caller owns retrying without it (#133).
        let lowLatency: Bool
    }

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var sessionCodec: StreamCodec = .h264
    private var sessionToken: UInt64 = 0

    /// Whether a compression session is currently installed. The direct
    /// replacement for `MacSender`'s old `encoder == nil` checks.
    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return session != nil
    }

    /// Retires the current session: nothing submitted to it can be published
    /// afterwards (its token is spent), and VideoToolbox is told to tear it
    /// down deterministically, as `VTCompressionSessionInvalidate`'s contract
    /// asks. Idempotent — invalidating when there is no session is a no-op
    /// beyond spending the token.
    func invalidate() {
        lock.lock()
        let retired = session
        session = nil
        sessionToken &+= 1
        lock.unlock()
        // Outside the lock: this call can synchronously deliver outstanding
        // output handlers, and those re-enter `codec(ifCurrent:)`.
        if let retired { VTCompressionSessionInvalidate(retired) }
    }

    /// Replaces the current session with a freshly created and configured
    /// one. Returns `VTCompressionSessionCreate`'s status; on any failure no
    /// session is installed (`isActive == false`), exactly as the previous
    /// inline `compressionSessionOut: &encoder` write-back left it, and the
    /// previously installed session has been invalidated either way.
    @discardableResult
    func create(_ configuration: Configuration) -> OSStatus {
        invalidate()
        let spec: CFDictionary? = configuration.lowLatency
            ? [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
            : nil
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(configuration.width), height: Int32(configuration.height),
            codecType: configuration.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            // Block-based output: every frame carries its own handler via
            // `VTCompressionSessionEncodeFrame`, so there is no C callback
            // and no `outputCallbackRefCon` whose lifetime must be managed.
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard let created else { return status }
        // Low-latency settings: real-time, no B-frames, periodic keyframes.
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel,
            value: configuration.codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        // No periodic IDRs: each one is a bitrate spike → transmit-time hiccup.
        // TCP never loses data, and we force a keyframe on reconnect/drop.
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 3600 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 60 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: configuration.bitrate as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: configuration.fps as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(created)
        lock.lock()
        session = created
        sessionCodec = configuration.codec
        sessionToken &+= 1
        lock.unlock()
        return status
    }

    /// Submits one frame to the current session.
    ///
    /// `onOutput`'s `codec` argument is the codec of the session this frame
    /// was submitted to, or `nil` if that session has since been retired —
    /// i.e. the output is STALE and must not be packaged or published. The
    /// handler is invoked exactly where VideoToolbox invokes it (its own
    /// output thread, or synchronously on the submitting thread for a frame
    /// dropped during submission); this adds no queue, actor or Task hop.
    ///
    /// Returns `VTCompressionSessionEncodeFrame`'s status, or
    /// `kVTInvalidSessionErr` when there is no installed session — the
    /// caller's existing synchronous-submit-failure path then applies, so
    /// every admitted frame still has exactly one accounting outcome.
    func submit(
        _ pixelBuffer: CVPixelBuffer,
        pts: CMTime,
        forceKeyframe: Bool,
        onOutput: @escaping @Sendable (OSStatus, CMSampleBuffer?, StreamCodec?) -> Void
    ) -> OSStatus {
        lock.lock()
        let active = session
        let token = sessionToken
        lock.unlock()
        guard let active else { return kVTInvalidSessionErr }
        var frameProperties: CFDictionary?
        if forceKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
        }
        // Submitted with the lock released: VideoToolbox may call the handler
        // synchronously from inside this call, and the handler takes the lock.
        // The local `active` reference keeps the session alive for the
        // duration even if another domain retires it concurrently; submitting
        // to an already-invalidated session simply returns kVTInvalidSessionErr.
        return VTCompressionSessionEncodeFrame(
            active,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, buffer in
            onOutput(status, buffer, self?.codec(ifCurrent: token))
        }
    }

    /// The codec `token`'s session was configured for, or `nil` once that
    /// session is no longer the current one.
    private func codec(ifCurrent token: UInt64) -> StreamCodec? {
        lock.lock(); defer { lock.unlock() }
        return token == sessionToken ? sessionCodec : nil
    }

    // MARK: - Test support

    /// The identity of the currently installed session, or `nil` if there is
    /// none. Exposed so the stale-output decision can be tested without a
    /// live VideoToolbox session.
    var currentTokenForTesting: UInt64? {
        lock.lock(); defer { lock.unlock() }
        return session == nil ? nil : sessionToken
    }

    /// `codec(ifCurrent:)` under test.
    func codecIfCurrentForTesting(_ token: UInt64) -> StreamCodec? {
        codec(ifCurrent: token)
    }
}
