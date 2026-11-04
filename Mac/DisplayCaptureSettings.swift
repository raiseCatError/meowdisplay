import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Everything the display stream's ScreenCaptureKit configuration is made
/// from, so the stream is always configured the same way.
///
/// `SCStream.updateConfiguration` replaces the whole configuration. A field
/// the new configuration doesn't set takes ScreenCaptureKit's default, which
/// was measured on macOS 27.0 as 1920×1080, the cursor drawn into the
/// picture, no audio and at most 60 fps. A live change (Max FPS, an encoder
/// fallback, Mac audio) therefore edits a copy of the live settings and
/// applies all of it, never a fresh configuration with one field set.
struct DisplayCaptureSettings: Equatable, Sendable {
    var pixelsWide: Int
    var pixelsHigh: Int
    var targetFPS: Int
    var capturesAudio: Bool
    /// False with the local cursor echo, which draws the cursor on the receiver.
    var showsCursor: Bool
    /// Window view: video comes from the window compositor, so this stream
    /// only carries Mac audio and keeps the capture lifecycle.
    var audioCarrierOnly: Bool
    var pixelFormat: OSType

    /// The Window view audio carrier: tiny and slow, so it costs next to nothing.
    static let carrierWidth = 64
    static let carrierHeight = 36
    static let carrierFPS = 2

    /// 420v matches the encoder's native input, which skips a BGRA→YUV
    /// conversion inside VideoToolbox. `defaults write … pixfmt bgra`
    /// reverts it for A/B testing.
    static func pixelFormat(defaults: UserDefaults = .standard) -> OSType {
        defaults.string(forKey: "pixfmt") == "bgra"
            ? kCVPixelFormatType_32BGRA
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    /// The frame interval ScreenCaptureKit is asked for. It's double the
    /// target even though the source may run slower: asking for exactly
    /// 1/fps makes SCK's rate limiter skip frames that arrive a hair early
    /// (a beat frequency), measured at about 51 fps instead of 60 at parity.
    var minimumFrameInterval: CMTime {
        audioCarrierOnly
            ? CMTime(value: 1, timescale: Int32(Self.carrierFPS))
            : CMTime(value: 1, timescale: Int32(max(targetFPS, 1) * 2))
    }

    var configuration: SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = audioCarrierOnly ? Self.carrierWidth : pixelsWide
        config.height = audioCarrierOnly ? Self.carrierHeight : pixelsHigh
        config.minimumFrameInterval = minimumFrameInterval
        config.pixelFormat = pixelFormat
        // One buffer is held permanently (keyframe replay) and one sits in
        // the encoder for about 13 ms. The headroom prevents SCK starvation drops.
        config.queueDepth = 8
        config.showsCursor = showsCursor && !audioCarrierOnly
        // Mac system audio is a copy of system audio, never a reroute of the
        // Mac's physical output. `capturesAudio` gates SCK's own audio capture
        // work: off means SCK does none of it, not just that the samples are
        // ignored (PROTOCOL.md 5A). It must never pick up this Mac's own
        // MeowDisplay audio. There is none today, but excluding it is the
        // documented way to avoid a feedback loop.
        config.capturesAudio = capturesAudio
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        return config
    }
}
