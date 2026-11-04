import CoreMedia
import CoreVideo
import ScreenCaptureKit
import XCTest

/// The display stream is configured from one set of settings, at start and
/// on every live change. `SCStream.updateConfiguration` replaces the whole
/// configuration (measured on macOS 27.0: a configuration with only the frame
/// interval set turned a 320×180 stream into 1920×1080). Max FPS changes, the
/// encoder's fallbacks and the Mac audio switch used to send such a
/// configuration, which reset the capture size, drew the Mac cursor into the
/// picture, turned audio capture off and lifted the frame-rate cap.
final class DisplayCaptureSettingsTests: XCTestCase {

    private func mirror(fps: Int = 120, audio: Bool = true) -> DisplayCaptureSettings {
        DisplayCaptureSettings(pixelsWide: 2796, pixelsHigh: 1290, targetFPS: fps, capturesAudio: audio,
                               showsCursor: false, audioCarrierOnly: false,
                               pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    func testMirrorAndExtendAreConfiguredFromTheSettings() {
        let config = mirror().configuration
        XCTAssertEqual(config.width, 2796)
        XCTAssertEqual(config.height, 1290)
        XCTAssertEqual(config.minimumFrameInterval, CMTime(value: 1, timescale: 240), "double the target")
        XCTAssertEqual(config.pixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(config.queueDepth, 8)
        XCTAssertFalse(config.showsCursor, "the receiver draws the cursor itself")
        XCTAssertTrue(config.capturesAudio)
        XCTAssertEqual(config.sampleRate, 48_000)
        XCTAssertEqual(config.channelCount, 2)
        XCTAssertTrue(config.excludesCurrentProcessAudio)
    }

    func testWindowViewStreamOnlyCarriesAudio() {
        var settings = mirror()
        settings.audioCarrierOnly = true
        settings.showsCursor = true
        let config = settings.configuration
        XCTAssertEqual(config.width, DisplayCaptureSettings.carrierWidth)
        XCTAssertEqual(config.height, DisplayCaptureSettings.carrierHeight)
        XCTAssertEqual(config.minimumFrameInterval, CMTime(value: 1, timescale: 2))
        XCTAssertFalse(config.showsCursor)
        XCTAssertTrue(config.capturesAudio)

        settings.targetFPS = 60
        XCTAssertEqual(settings.configuration.minimumFrameInterval, CMTime(value: 1, timescale: 2),
                       "a Max FPS change never turns the carrier into a full-rate capture")
    }

    /// A Max FPS change, an encoder fallback and the audio switch each change
    /// one setting and keep every other one.
    func testALiveChangeKeepsEveryOtherSetting() {
        var settings = mirror(fps: 120, audio: true)
        settings.targetFPS = 60
        var config = settings.configuration
        XCTAssertEqual(config.minimumFrameInterval, CMTime(value: 1, timescale: 120))
        XCTAssertEqual(config.width, 2796)
        XCTAssertEqual(config.height, 1290)
        XCTAssertFalse(config.showsCursor)
        XCTAssertTrue(config.capturesAudio, "a Max FPS change keeps Mac audio on")

        settings.capturesAudio = false
        config = settings.configuration
        XCTAssertFalse(config.capturesAudio)
        XCTAssertEqual(config.minimumFrameInterval, CMTime(value: 1, timescale: 120), "the audio switch keeps the cap")
        XCTAssertEqual(config.width, 2796)
        XCTAssertFalse(config.showsCursor, "the audio switch doesn't draw the cursor in")
        XCTAssertEqual(config.queueDepth, 8)
    }

    /// Why a fresh configuration can't be used for a live change: its
    /// defaults aren't what the stream was started with.
    func testAFreshConfigurationIsNotTheLiveOne() {
        let fresh = SCStreamConfiguration()
        let live = mirror(fps: 120, audio: true).configuration
        XCTAssertNotEqual(fresh.width, live.width)
        XCTAssertNotEqual(fresh.showsCursor, live.showsCursor)
        XCTAssertNotEqual(fresh.capturesAudio, live.capturesAudio)
        XCTAssertNotEqual(fresh.minimumFrameInterval, live.minimumFrameInterval)
    }

    func testPixelFormatDefaultsTo420vAndBGRAIsAnOptIn() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DisplayCaptureSettingsTests"))
        defer { defaults.removePersistentDomain(forName: "DisplayCaptureSettingsTests") }
        XCTAssertEqual(DisplayCaptureSettings.pixelFormat(defaults: defaults), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        defaults.set("bgra", forKey: "pixfmt")
        XCTAssertEqual(DisplayCaptureSettings.pixelFormat(defaults: defaults), kCVPixelFormatType_32BGRA)
    }
}
