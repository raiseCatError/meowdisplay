// ReceiverAudioDecoder — RC-3 Stage E1.
//
// The sole owner of the receiver-side AAC→PCM decode domain that used to
// live as plain `queue`-confined stored properties on `StreamReceiver`: the
// shared `AVAudioConverter` (production `PCMPlaybackEngine` playback AND
// the DEBUG-only local-decode validation both go through this one
// instance — see the doc comment that used to sit on `StreamReceiver.
// receiverAACDecoder` for why there must be exactly one conversion chain),
// its format-description-keyed recreation, and the DEBUG-only anomaly/dump
// diagnostics that examine ONLY the decoder's own output.
//
// Isolation: NOT an actor. `decode(_:formatDescription:)` is a plain
// synchronous call — `AVAudioConverter.convert(to:error:)` runs its input
// closure and returns its status synchronously on the calling thread, with
// no callback that escapes to a foreign thread the way VideoToolbox's
// decode callback does (contrast `ReceiverVideoDecoder`, which needs an
// actor + ordered command pump for exactly that reason). Every call this
// session makes into this type happens synchronously from
// `StreamReceiver.queue`, the same single serial `DispatchQueue` that owns
// every other piece of receiver audio state — so this follows the
// project's established single-queue-confinement pattern (see
// `PCMPlaybackEngine`'s `@unchecked Sendable` doc comment) rather than
// introducing an actor hop into a real-time, per-packet decode path.
// `@unchecked Sendable`: every stored property below is touched only from
// `StreamReceiver.queue`, never concurrently, and never from this type's
// own async work (there is none) — the same confinement shape as
// `PCMPlaybackEngine`, justified the same way.
//
// Input boundary: the minimum immutable information needed to decode one
// received AAC access unit — its raw compressed payload and the current
// `CMAudioFormatDescription` the sender's `AudioConfigFrame` established.
// This type never sees `AudioPacketFrame`/`AudioMediaFrame` wire types.
//
// Output boundary: stops at a decoded `AVAudioPCMBuffer`. It has no
// knowledge of `audioAnchor`, `clockOffsetMs`, `avSyncOffsetMs`,
// `presentationGeneration`, the renderer/synchronizer, or
// `PCMPlaybackEngine` — those all remain host-side (`StreamReceiver`),
// which hands the returned buffer to whichever scheduling path
// (`PCMPlaybackEngine.enqueue`, or the DEBUG-only analysis pass) is active.
//
// Ordering: decode calls are synchronous and this type does no queueing of
// its own — ordering is inherited entirely from the caller always invoking
// `decode` on `StreamReceiver.queue`, in wire-arrival order, exactly as the
// pre-extraction code did.
//
// Converter lifecycle: unchanged from the pre-extraction code — the
// converter is created once per distinct `CMAudioFormatDescription` (via
// `CMFormatDescriptionEqual`) and reused across packets that share it;
// `reset()` (called by `StreamReceiver.resetAudioPlayback` only when NOT
// `keepingFormat`) drops it so the next decode rebuilds fresh.
//
// Error semantics: unchanged — a decode failure (conversion status !=
// `.haveData`, or unable to build a converter from the format description)
// drops that one packet (returns `nil`); the converter itself is not
// reset or torn down by a failure, matching the pre-extraction behavior.
//
@preconcurrency import AVFoundation
import CoreMedia

final class ReceiverAudioDecoder: @unchecked Sendable {

    // MARK: - State moved together from StreamReceiver (E1)

    private var converter: AVAudioConverter?
    private var converterFormatDescription: CMAudioFormatDescription?
    private var decodeAnomalyCount = 0

    #if DEBUG
    /// Separate from the production decode above: lets a physical device
    /// run the (cheap) decode+anomaly-log path without also paying for the
    /// ~5s CAF file write, or vice versa. Read fresh from `UserDefaults` on
    /// every use (never latched), matching every other in-app Developer /
    /// Audio Diagnostics toggle in this codebase — a physical iOS device's
    /// sandboxed defaults can't receive a Mac terminal's `defaults write`,
    /// so an in-app toggle is the only practical way to flip this on a real
    /// device.
    /// Not `private`: `StreamReceiver.beginAudioGenerationIfCodecChanged`
    /// names it in its startup diagnostic log line.
    var dumpEnabled: Bool {
        UserDefaults.standard.bool(forKey: "audioReceiverDumpEnabled")
    }
    private var lastDecodedSample: Float?
    private var dumpFile: AVAudioFile?
    private var dumpFrames = 0
    private static let dumpFrameLimit = 48_000 * 5   // ~5s at 48kHz

    /// iOS: the app's own Documents directory, so the dump is reachable
    /// from the Files app (On My iPhone/iPad → MeowDisplay) without Xcode.
    /// macOS (the `OpenSidecarMacReceiver` test target): the same
    /// `Log.directory` the Mac sender's dumps already use. Not `private`:
    /// `StreamReceiver.beginAudioGenerationIfCodecChanged` names it too.
    static func dumpDirectory() -> URL {
        #if os(iOS)
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #else
        return Log.directory
        #endif
    }
    #endif

    /// Decodes one received AAC access unit into PCM, using a plain
    /// `AVAudioConverter` rather than the legacy compressed-`CMSampleBuffer`
    /// path. Called every packet in production
    /// (`StreamReceiver.scheduleAudioPacket` when `activePlaybackPath ==
    /// .pcmEngine`) and, DEBUG-only, as an independent validation pass
    /// regardless of which playback path is active.
    func decode(_ payload: Data, formatDescription: CMAudioFormatDescription) -> AVAudioPCMBuffer? {
        if converterFormatDescription == nil
            || !CMFormatDescriptionEqual(converterFormatDescription!, otherFormatDescription: formatDescription) {
            let compressedFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
            guard let pcmFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: compressedFormat.sampleRate,
                    channels: compressedFormat.channelCount, interleaved: false),
                  let decoder = AVAudioConverter(from: compressedFormat, to: pcmFormat) else {
                Log.info("audioTrace: ⚠️ could not build receiver-local AAC decoder from received format description")
                return nil
            }
            converter = decoder
            converterFormatDescription = formatDescription
        }
        guard let decoder = converter else { return nil }

        let compressed = AVAudioCompressedBuffer(
            format: decoder.inputFormat, packetCapacity: 1, maximumPacketSize: payload.count)
        payload.withUnsafeBytes { raw in
            compressed.data.copyMemory(from: raw.baseAddress!, byteCount: payload.count)
        }
        compressed.byteLength = UInt32(payload.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(payload.count))

        guard let pcmOut = AVAudioPCMBuffer(
            pcmFormat: decoder.outputFormat, frameCapacity: 1024) else { return nil }
        var suppliedInput = false
        var error: NSError?
        let status = decoder.convert(to: pcmOut, error: &error) { _, outStatus in
            if suppliedInput { outStatus.pointee = .noDataNow; return nil }
            suppliedInput = true
            outStatus.pointee = .haveData
            return compressed
        }
        guard status == .haveData, pcmOut.floatChannelData != nil else {
            decodeAnomalyCount += 1
            Log.info("audioTrace: ⚠️ receiver-local AAC decode failed status=\(status) error=\(String(describing: error)) (anomaly #\(decodeAnomalyCount))")
            return nil
        }
        return pcmOut
    }

    /// Drops the converter/format-description so the next `decode` rebuilds
    /// fresh, and (DEBUG) finalizes any in-flight dump and clears the
    /// discontinuity-detection sample. Callers pass through only when NOT
    /// `keepingFormat` — matches the pre-extraction `resetAudioPlayback`
    /// behavior exactly.
    func reset() {
        converter = nil
        converterFormatDescription = nil
        #if DEBUG
        finalizeDump()
        lastDecodedSample = nil
        #endif
    }

    #if DEBUG
    /// Anomaly checks + optional CAF dump over an already-decoded packet —
    /// split from `decode` so the production `PCMPlaybackEngine` path can
    /// reuse the identical decode without also paying for or depending on
    /// this DEBUG-only analysis.
    func analyze(_ pcmOut: AVAudioPCMBuffer) {
        guard let channelData = pcmOut.floatChannelData else { return }
        let frameLength = Int(pcmOut.frameLength)
        var hasNaNOrInf = false
        var maxAbsSample: Float = 0
        var jumpDetected = false
        let buf0 = channelData[0]
        for i in 0..<frameLength {
            let v = buf0[i]
            if v.isNaN || v.isInfinite { hasNaNOrInf = true }
            let a = abs(v)
            if a > maxAbsSample { maxAbsSample = a }
            if let last = lastDecodedSample, abs(v - last) > 1.5 { jumpDetected = true }
            lastDecodedSample = v
        }
        if hasNaNOrInf {
            decodeAnomalyCount += 1
            Log.info("audioTrace: ⚠️ receiver-local AAC decode produced NaN/Inf (anomaly #\(decodeAnomalyCount)) — reconstruction/decoder-input defect on THIS device")
        }
        if maxAbsSample >= 0.999 {
            decodeAnomalyCount += 1
            Log.info("audioTrace: ⚠️ receiver-local AAC decode near/at full-scale (\(maxAbsSample)) — possible clipping (anomaly #\(decodeAnomalyCount))")
        }
        if jumpDetected {
            decodeAnomalyCount += 1
            Log.info("audioTrace: ⚠️ receiver-local AAC decode inter-sample discontinuity at packet boundary (anomaly #\(decodeAnomalyCount))")
        }
        if dumpEnabled { dump(pcmOut) }
    }

    /// ~5s bounded dump of the receiver-local decode above, for an actual
    /// listening A/B on-device. Path is platform-specific (see
    /// `dumpDirectory`) and self-reports every step — same no-silent-
    /// failure discipline as `AudioCaptureEncoder`'s dumps on the Mac side.
    private func dump(_ pcm: AVAudioPCMBuffer) {
        guard dumpFrames < Self.dumpFrameLimit else { return }
        if dumpFile == nil {
            let dir = Self.dumpDirectory()
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                Log.info("audioTrace: ⚠️ could not create \(dir.path): \(error)")
                return
            }
            let url = dir.appendingPathComponent("audio-compare-received-decoded-aac.caf")
            do {
                dumpFile = try AVAudioFile(forWriting: url, settings: pcm.format.settings)
                Log.info("audioTrace: opened receiver-local AAC decode dump \(url.path) — pull it from the Files app (On My iPhone/iPad → MeowDisplay) or Xcode's Devices window on iOS, or open directly on macOS")
            } catch {
                Log.info("audioTrace: ⚠️ could not open \(url.path) for writing: \(error)")
                return
            }
        }
        guard let dumpFile else { return }
        do {
            try dumpFile.write(from: pcm)
            dumpFrames += Int(pcm.frameLength)
            if dumpFrames >= Self.dumpFrameLimit {
                Log.info("audioTrace: audio-compare-received-decoded-aac.caf reached \(dumpFrames) frames — finalizing")
                finalizeDump()
            }
        } catch {
            Log.info("audioTrace: ⚠️ audio-compare-received-decoded-aac.caf write failed: \(error)")
        }
    }

    private func finalizeDump() {
        if let dumpFile {
            Log.info("audioTrace: finalized \(dumpFile.url.lastPathComponent) frames=\(dumpFrames)")
        }
        dumpFile = nil
        dumpFrames = 0
    }
    #endif
}
