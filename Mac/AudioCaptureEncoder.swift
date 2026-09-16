@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia

/// Hands a non-`Sendable` Core Media/Core Audio value across an isolation
/// boundary (into this actor, or into a detached `Task`). Safe because
/// ScreenCaptureKit hands each sample buffer to exactly one call site and
/// nothing else touches it concurrently — the type itself just isn't
/// annotated `Sendable` by the SDK.
struct MediaSampleBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) { self.value = value }
}

/// One encoded AAC access unit ready to go on the wire, plus enough
/// metadata for the receiver to schedule it — see `AudioMediaFrame` /
/// `AudioPacketFrame` (Shared/AudioMediaFrame.swift) for the wire shape.
struct EncodedAudioPacket: Sendable {
    let payload: Data
    /// Milliseconds since the Unix epoch on the sender's clock, derived
    /// from this packet's real capture presentation timestamp — never from
    /// when encoding or sending happened.
    let capturedAtMs: Int64
    let durationMs: UInt32
}

/// The AAC format description a receiver needs before it can build a
/// `CMAudioFormatDescription` for the packets that follow.
struct AudioFormatConfig: Sendable, Equatable {
    let sampleRate: UInt32
    let channelCount: UInt8
    /// The AudioSpecificConfig ("magic cookie") AVAudioConverter produces
    /// once it has been primed with real input.
    let cookie: Data
}

/// One DEBUG-only diagnostic PCM packet — see `AudioCaptureEncoder.encodePCM`.
struct EncodedPCMPacket: Sendable {
    /// 32-bit Float32 interleaved samples.
    let payload: Data
    let capturedAtMs: Int64
    let frameCount: Int
}

/// The DEBUG-only diagnostic PCM format description a receiver needs before
/// it can build an `lpcm` `CMAudioFormatDescription`.
struct PCMFormatConfig: Sendable, Equatable {
    let sampleRate: UInt32
    let channelCount: UInt8
}

/// Captures a copy of Mac system audio (fed in from ScreenCaptureKit's
/// `.audio` stream output — see `MacSender.stream(_:didOutputSampleBuffer:of:)`)
/// and encodes it to AAC-LC using `AVAudioConverter`. Deliberately its own
/// small, actor-isolated type rather than more state on `MacSender`
/// (already ~3000 lines with pre-existing concurrency debt) — see the
/// milestone note in Mac/MacSender.swift's audio section.
///
/// Confined entirely to its own actor: `MacSender` only ever awaits
/// `encode(_:)` / `reset()` from its capture queue and receives back a
/// Sendable `[EncodedAudioPacket]` / `AudioFormatConfig?`, never touching
/// AVAudioConverter state directly.
actor AudioCaptureEncoder {
    private let targetBitRate: Int

    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    // DEBUG-only PCM bypass A/B mode converter: converts whatever format
    // ScreenCaptureKit actually delivers into one fixed, documented wire
    // layout (32-bit Float32 interleaved) so the receiver never has to
    // guess interleaving/planarity — see `encodePCM`.
    private var pcmConverter: AVAudioConverter?
    private var pcmOutputFormat: AVAudioFormat?

    /// Wall-clock ms (sender clock, Unix epoch) corresponding to
    /// `encodedSampleCount == 0`. Together with `originHostSeconds` (the
    /// SAME instant, in the CMTime host-clock domain used by captured
    /// sample buffers' own PTS) this defines one continuous audio
    /// timeline: `capturedAtMs(n) = originWallMs + (n - originHostSeconds-
    /// equivalent sample offset) / sampleRate * 1000`. `nil` means "not yet
    /// anchored".
    private var originWallMs: Double?
    private var originHostSeconds: Double?
    private var encodedSampleCount: Int64 = 0

    // DEBUG-only PCM bypass A/B mode (`MacSender.audioDebugPCMMode`): an
    // independent anchor rather than reusing the AAC one above, because PCM
    // packets map 1:1 to ScreenCaptureKit callbacks (no converter batching),
    // so their timestamp math is simpler and must not perturb — or be
    // perturbed by — the AAC path's `encodedSampleCount` bookkeeping when a
    // developer flips modes mid-session.
    private var pcmOriginWallMs: Double?
    private var pcmOriginHostSeconds: Double?
    private(set) var pcmFormatConfig: PCMFormatConfig?

    #if DEBUG
    private var loggedPacketizationAudit = false
    private var diagnosticPacketCount = 0
    private var lastInputFormatDescription: String?
    // Frame accounting (GOAL section B.8): compared periodically, not
    // per-packet, to catch PCM frames silently duplicated/dropped between
    // ScreenCaptureKit delivery and what the AAC converter actually
    // consumed.
    private var sourcePCMFramesReceived: Int64 = 0
    private var sourcePCMFramesConsumedByAAC: Int64 = 0
    private var aacPacketsProduced: Int64 = 0
    /// DEBUG-only local AAC round-trip validator: decodes the exact packet
    /// just produced back to PCM using `AVAudioConverter`, independent of
    /// the network/receiver path entirely, so a garble heard on-device can
    /// be attributed to encode vs. everything downstream of it. Opt in with
    /// `defaults write <bundle id from the `audioTrace: generation=` self-report line> audioLocalRoundTrip -bool YES`.
    private lazy var localRoundTripEnabled = UserDefaults.standard.bool(forKey: "audioLocalRoundTrip")
    private var roundTripDecoder: AVAudioConverter?
    private var roundTripAnomalyCount = 0
    /// Independent verification that the AAC leaving this encoder is clean,
    /// decoupled from the network path entirely: opt in with
    /// `defaults write <bundle id from the `audioTrace: generation=` self-report line> audioDebugDump -bool YES`.
    /// Writes ADTS-framed AAC (playable directly — `afplay`/`ffprobe`/QuickTime
    /// all understand it) to `~/Library/Logs/OpenDisplay/audio-debug-dump.aac`,
    /// capped at a few hundred packets (~a few seconds) so this can never grow
    /// into a standing recording. DEBUG-only; never runs in a Release build.
    private lazy var debugDumpEnabled = UserDefaults.standard.bool(forKey: "audioDebugDump")
    private var debugDumpHandle: FileHandle?
    private var debugDumpPacketCount = 0
    private static let debugDumpPacketLimit = 300
    /// DEBUG-only source-PCM-vs-locally-decoded-AAC A/B dump: a decoded
    /// round-trip packet can be numerically "valid" (no NaN/Inf, clean
    /// decode status) while still being audibly wrong — clipping, a
    /// dropped/duplicated block, or a discontinuity at a packet boundary
    /// all decode "successfully". Writing both signals to disk for the
    /// same short interval lets a human A/B them directly on the Mac,
    /// independent of the network/receiver entirely. Opt in with
    /// `defaults write <bundle id from the `audioTrace: generation=` self-report line> audioPCMCompareDump -bool YES`.
    /// Bounded to a few seconds so this can never become a standing
    /// recording; never runs in a Release build.
    private lazy var pcmCompareDumpEnabled = UserDefaults.standard.bool(forKey: "audioPCMCompareDump")
    private var sourceDumpFile: AVAudioFile?
    private var sourceDumpFrames = 0
    private var decodedDumpFile: AVAudioFile?
    private var decodedDumpFrames = 0
    /// The literal wire PCM: the exact Float32-interleaved buffer that gets
    /// serialized into a `PCMPacketFrame` payload — see `encodePCM`. Distinct
    /// from `sourceDumpFile` (captured PCM BEFORE conversion): comparing all
    /// three files against each other localizes a defect to capture, the
    /// AVAudioConverter/interleave step, or the wire/receiver, per GOAL #7.
    private var wireDumpFile: AVAudioFile?
    private var wireDumpFrames = 0
    private static let pcmCompareDumpFrameLimit = 48_000 * 5   // ~5s at 48kHz
    private var lastRoundTripSample: Float?
    /// Periodic (not per-packet) checksum/sample-sanity accounting for the
    /// DEBUG PCM bypass — GOAL #5/#6: a receiver-side counterpart in
    /// `StreamReceiver` logs the same fields so the two can be diffed by
    /// eye to separate "wire/framing corrupted the bytes" from "the bytes
    /// arrived correctly but something interprets them wrong".
    private var pcmPacketsSinceSanityLog = 0
    #endif

    private(set) var formatConfig: AudioFormatConfig?

    init(bitRate: Int = 128_000) {
        targetBitRate = bitRate
    }

    /// Drops all converter/timeline state. Called whenever capture restarts
    /// (new generation, reconnect, Audio re-enabled) so a stale sample
    /// count or cookie from a previous session can never leak into a new
    /// one's timeline or format description.
    func reset() {
        converter = nil
        outputFormat = nil
        originWallMs = nil
        originHostSeconds = nil
        encodedSampleCount = 0
        formatConfig = nil
        pcmConverter = nil
        pcmOutputFormat = nil
        pcmOriginWallMs = nil
        pcmOriginHostSeconds = nil
        pcmFormatConfig = nil
        #if DEBUG
        loggedPacketizationAudit = false
        lastInputFormatDescription = nil
        roundTripDecoder = nil
        lastRoundTripSample = nil
        finalizeDumpFiles()
        pcmPacketsSinceSanityLog = 0
        #endif
    }

    /// Feeds one captured PCM sample buffer and returns any AAC packets
    /// that became ready as a result. ScreenCaptureKit's audio chunks are
    /// shorter than one 1024-sample AAC frame, so most calls return an
    /// empty array while `AVAudioConverter` accumulates internally; that is
    /// normal, not an error.
    func encode(_ boxedSampleBuffer: MediaSampleBox<CMSampleBuffer>) -> [EncodedAudioPacket] {
        let sampleBuffer = boxedSampleBuffer.value
        guard CMSampleBufferIsValid(sampleBuffer) else {
            #if DEBUG
            Log.info("audioTrace: ⚠️ invalid sample buffer from ScreenCaptureKit — dropped")
            #endif
            return []
        }
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return [] }

        #if DEBUG
        let inputFormatDescription = "rate=\(pcm.format.sampleRate) ch=\(pcm.format.channelCount) interleaved=\(pcm.format.isInterleaved) commonFormat=\(pcm.format.commonFormat.rawValue)"
        if let lastInputFormatDescription, lastInputFormatDescription != inputFormatDescription {
            Log.info("audioTrace: ⚠️ source PCM ASBD changed mid-session was=[\(lastInputFormatDescription)] now=[\(inputFormatDescription)]")
        }
        lastInputFormatDescription = inputFormatDescription
        sourcePCMFramesReceived += Int64(pcm.frameLength)
        if pcmCompareDumpEnabled { dumpSourcePCM(pcm) }
        #endif

        if converter == nil {
            guard setUpConverter(inputFormat: pcm.format) else { return [] }
        }
        guard let converter, let outputFormat else { return [] }

        let bufferHostSeconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if originWallMs == nil || originHostSeconds == nil {
            originWallMs = Date().timeIntervalSince1970 * 1000
            originHostSeconds = bufferHostSeconds
            #if DEBUG
            Log.info("audioTrace: encoder anchored inputRate=\(pcm.format.sampleRate) inputChannels=\(pcm.format.channelCount) outputRate=\(outputFormat.sampleRate) outputChannels=\(outputFormat.channelCount)")
            #endif
        } else {
            // A genuine ScreenCaptureKit discontinuity (a capture stall,
            // not merely this callback's own scheduling jitter) shows up as
            // this buffer's REAL host-time PTS diverging from what our
            // pure sample-count timeline expects. Letting the running
            // counter free-run through a real gap would silently drift the
            // whole session's audio away from its actual capture time —
            // re-anchor instead, so `capturedAtMs` always reflects reality.
            let expectedHostSeconds = originHostSeconds! + Double(encodedSampleCount) / outputFormat.sampleRate
            let driftSeconds = bufferHostSeconds - expectedHostSeconds
            if abs(driftSeconds) > 0.05 {
                #if DEBUG
                Log.info("audioTrace: capture discontinuity detected drift=\(Int(driftSeconds * 1000))ms — re-anchoring")
                #endif
                originWallMs = Date().timeIntervalSince1970 * 1000
                originHostSeconds = bufferHostSeconds
                encodedSampleCount = 0
            }
        }
        guard let originWallMs else { return [] }

        if formatConfig == nil, let cookie = AACLCFraming.audioSpecificConfig(
            sampleRate: outputFormat.sampleRate, channelCount: Int(outputFormat.channelCount)) {
            formatConfig = AudioFormatConfig(
                sampleRate: UInt32(outputFormat.sampleRate),
                channelCount: UInt8(outputFormat.channelCount),
                cookie: cookie)
        }

        var packets: [EncodedAudioPacket] = []
        let pcmBox = MediaSampleBox(pcm)
        var suppliedInput = false
        while true {
            let output = AVAudioCompressedBuffer(
                format: outputFormat, packetCapacity: 1,
                maximumPacketSize: converter.maximumOutputPacketSize)
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if suppliedInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                outStatus.pointee = .haveData
                return pcmBox.value
            }
            guard status == .haveData, output.byteLength > 0 else { break }

            #if DEBUG
            // Empirical packetization audit (do not assume one converter
            // call == one packet): with `packetCapacity: 1` the buffer
            // MUST hold exactly one AAC access unit. Log once so a real
            // multi-packet buffer — which would mean every packet after
            // the first in that buffer is being silently dropped — is
            // caught rather than assumed away.
            if !loggedPacketizationAudit {
                loggedPacketizationAudit = true
                let descSummary: String
                if let descs = output.packetDescriptions {
                    descSummary = (0..<Int(output.packetCount))
                        .map { "off=\(descs[$0].mStartOffset) size=\(descs[$0].mDataByteSize)" }
                        .joined(separator: ",")
                } else {
                    descSummary = "none"
                }
                let looksLikeADTS = output.byteLength >= 2
                    && output.data.load(fromByteOffset: 0, as: UInt8.self) == 0xFF
                    && (output.data.load(fromByteOffset: 1, as: UInt8.self) & 0xF0) == 0xF0
                Log.info("audioTrace: packetization audit packetCount=\(output.packetCount) byteLength=\(output.byteLength) descs=[\(descSummary)] looksLikeADTS=\(looksLikeADTS) (expected false — raw AAC-LC, no ADTS)")
            }
            if output.packetCount != 1 {
                Log.info("audioTrace: WARNING unexpected packetCount=\(output.packetCount) (packetCapacity was 1) byteLength=\(output.byteLength)")
            }
            #endif

            let capturedAtMs = AudioPacketTiming.capturedAtMs(
                originWallMs: originWallMs, encodedSampleCount: encodedSampleCount,
                sampleRate: outputFormat.sampleRate)
            let durationMs = AudioPacketTiming.durationMs(sampleRate: outputFormat.sampleRate)
            let payload = Data(bytes: output.data, count: Int(output.byteLength))
            packets.append(EncodedAudioPacket(
                payload: payload, capturedAtMs: capturedAtMs, durationMs: durationMs))
            encodedSampleCount += AudioPacketTiming.framesPerPacket

            #if DEBUG
            diagnosticPacketCount += 1
            aacPacketsProduced += 1
            if diagnosticPacketCount % 100 == 0 {
                Log.info("audioTrace: encoded packet #\(diagnosticPacketCount) capturedAtMs=\(capturedAtMs) durationMs=\(durationMs) bytes=\(output.byteLength)")
                // Frame accounting (GOAL B.8): sourcePCMFramesReceived should
                // track sourcePCMFramesConsumedByAAC within a bounded
                // remainder, and aacPacketsProduced * framesPerPacket should
                // track sourcePCMFramesConsumedByAAC the same way. Only the
                // divergence is worth a human's attention.
                let expectedConsumedFromPackets = aacPacketsProduced * AudioPacketTiming.framesPerPacket
                let producedVsConsumedDrift = expectedConsumedFromPackets - sourcePCMFramesConsumedByAAC
                let receivedVsConsumedDrift = sourcePCMFramesReceived - sourcePCMFramesConsumedByAAC
                Log.info("audioTrace: frame accounting sourcePCMFramesReceived=\(sourcePCMFramesReceived) sourcePCMFramesConsumed=\(sourcePCMFramesConsumedByAAC) AACPacketsProduced=\(aacPacketsProduced) AACFramesRepresented=\(expectedConsumedFromPackets)")
                if abs(producedVsConsumedDrift) > AudioPacketTiming.framesPerPacket * 4 {
                    Log.info("audioTrace: ⚠️ AAC frame accounting diverged by \(producedVsConsumedDrift) frames (produced-vs-consumed) — possible duplication/drop in the converter input block")
                }
                if receivedVsConsumedDrift < -Int64(pcm.frameLength) * 2 {
                    // Consumed more than was ever received: the input
                    // closure is being asked for data more than once per
                    // buffer without `suppliedInput` gating it correctly.
                    Log.info("audioTrace: ⚠️ AAC consumed more source PCM (\(sourcePCMFramesConsumedByAAC)) than ScreenCaptureKit delivered (\(sourcePCMFramesReceived))")
                }
            }
            if debugDumpEnabled, let cookie = formatConfig?.cookie {
                dumpPacketForVerification(payload, sampleRate: outputFormat.sampleRate,
                                          channelCount: Int(outputFormat.channelCount), cookie: cookie)
            }
            if localRoundTripEnabled {
                verifyLocalRoundTrip(payload, outputFormat: outputFormat)
            }
            #endif
        }
        #if DEBUG
        if suppliedInput {
            sourcePCMFramesConsumedByAAC += Int64(pcm.frameLength)
        }
        #endif
        return packets
    }

    private func setUpConverter(inputFormat: AVAudioFormat) -> Bool {
        var outputStreamDescription = AudioStreamBasicDescription(
            mSampleRate: inputFormat.sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(AudioPacketTiming.framesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: inputFormat.channelCount,
            mBitsPerChannel: 0,
            mReserved: 0)
        guard let outputFormat = AVAudioFormat(streamDescription: &outputStreamDescription),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return false }
        converter.bitRate = targetBitRate
        self.converter = converter
        self.outputFormat = outputFormat
        return true
    }

    /// DEBUG-only diagnostic PCM bypass (see `PCMPacketFrame`,
    /// `MacSender.audioDebugPCMMode`): converts one captured buffer to a
    /// fixed, documented wire layout — 32-bit Float32 interleaved, same
    /// sample rate/channel count ScreenCaptureKit is actually delivering —
    /// and returns it uncompressed, with no AAC involved at all. Uses its
    /// own anchor (`pcmOriginWallMs`/`pcmOriginHostSeconds`) so switching
    /// A/B modes mid-session cannot perturb the AAC path's timeline state.
    func encodePCM(_ boxedSampleBuffer: MediaSampleBox<CMSampleBuffer>) -> EncodedPCMPacket? {
        let sampleBuffer = boxedSampleBuffer.value
        guard CMSampleBufferIsValid(sampleBuffer),
              let pcm = Self.pcmBuffer(from: sampleBuffer) else { return nil }
        #if DEBUG
        if pcmCompareDumpEnabled { dumpSourcePCM(pcm) }
        #endif

        if pcmConverter == nil {
            guard setUpPCMConverter(inputFormat: pcm.format) else { return nil }
        }
        guard let pcmConverter, let pcmOutputFormat else { return nil }

        let bufferHostSeconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if pcmOriginWallMs == nil || pcmOriginHostSeconds == nil {
            pcmOriginWallMs = Date().timeIntervalSince1970 * 1000
            pcmOriginHostSeconds = bufferHostSeconds
        }
        guard let pcmOriginWallMs, let pcmOriginHostSeconds else { return nil }

        if pcmFormatConfig == nil {
            pcmFormatConfig = PCMFormatConfig(
                sampleRate: UInt32(pcmOutputFormat.sampleRate),
                channelCount: UInt8(pcmOutputFormat.channelCount))
        }

        guard let output = AVAudioPCMBuffer(
            pcmFormat: pcmOutputFormat, frameCapacity: pcm.frameLength) else { return nil }
        var suppliedInput = false
        var error: NSError?
        let status = pcmConverter.convert(to: output, error: &error) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return pcm
        }
        guard status != .error, output.frameLength > 0,
              let channelData = output.floatChannelData else {
            #if DEBUG
            Log.info("audioTrace: ⚠️ PCM bypass converter failed status=\(status) error=\(String(describing: error))")
            #endif
            return nil
        }

        // `AVAudioPCMBuffer`'s `floatChannelData` is always non-interleaved
        // (one pointer per channel) even for an interleaved `AVAudioFormat`
        // — interleave explicitly here rather than assuming the in-memory
        // layout matches the wire layout we promise the receiver.
        let frameCount = Int(output.frameLength)
        let channelCount = Int(pcmOutputFormat.channelCount)
        var interleaved = [Float](repeating: 0, count: frameCount * channelCount)
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                interleaved[frame * channelCount + channel] = channelData[channel][frame]
            }
        }
        let payload = interleaved.withUnsafeBufferPointer { Data(buffer: $0) }

        #if DEBUG
        // Invariant this whole wire format rests on (GOAL #4): for Float32
        // interleaved PCM, payload byte count is exactly frameCount *
        // channelCount * 4 — not asserted in a comment, checked every
        // packet (cheap: one multiply/compare), logged once if it's ever
        // wrong instead of silently shipping a payload the receiver cannot
        // interpret correctly.
        let expectedBytes = frameCount * channelCount * 4
        if payload.count != expectedBytes {
            Log.info("audioTrace: ⚠️ PCM wire payload size invariant violated: got \(payload.count) bytes, expected frameCount(\(frameCount))*channelCount(\(channelCount))*4=\(expectedBytes)")
        }
        if pcmCompareDumpEnabled {
            dumpWirePCM(interleaved, frameCount: frameCount, channelCount: channelCount, sampleRate: pcmOutputFormat.sampleRate)
        }
        logPCMSanityIfDue(interleaved, frameCount: frameCount, channelCount: channelCount, side: "sender")
        #endif

        let capturedAtMs = Int64(pcmOriginWallMs + (bufferHostSeconds - pcmOriginHostSeconds) * 1000)
        return EncodedPCMPacket(payload: payload, capturedAtMs: capturedAtMs, frameCount: frameCount)
    }

    private func setUpPCMConverter(inputFormat: AVAudioFormat) -> Bool {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
            channels: inputFormat.channelCount, interleaved: true),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return false }
        pcmConverter = converter
        pcmOutputFormat = outputFormat
        #if DEBUG
        Log.info("audioTrace: PCM bypass anchored inputRate=\(inputFormat.sampleRate) inputChannels=\(inputFormat.channelCount) interleaved=\(inputFormat.isInterleaved) -> wireRate=\(outputFormat.sampleRate) wireChannels=\(outputFormat.channelCount) wireFormat=Float32 interleaved")
        #endif
        return true
    }

    #if DEBUG
    /// DEBUG-only local AAC round-trip validator (GOAL B.6): decodes the
    /// exact packet just produced back to PCM, independent of the network
    /// path, and flags anything that looks wrong (decode failure, NaN/Inf
    /// samples). Combine with the existing `audioDebugDump` ADTS dump
    /// (playable directly with `afplay`) to listen to precisely what this
    /// encoder produced, decoupled from transport/receiver entirely.
    private func verifyLocalRoundTrip(_ payload: Data, outputFormat: AVAudioFormat) {
        if roundTripDecoder == nil {
            guard let pcmFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: outputFormat.sampleRate,
                channels: outputFormat.channelCount, interleaved: false),
                let decoder = AVAudioConverter(from: outputFormat, to: pcmFormat) else { return }
            roundTripDecoder = decoder
        }
        guard let decoder = roundTripDecoder else { return }

        let compressed = AVAudioCompressedBuffer(
            format: outputFormat, packetCapacity: 1, maximumPacketSize: payload.count)
        payload.withUnsafeBytes { raw in
            compressed.data.copyMemory(from: raw.baseAddress!, byteCount: payload.count)
        }
        compressed.byteLength = UInt32(payload.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(payload.count))

        guard let pcmOut = AVAudioPCMBuffer(
            pcmFormat: decoder.outputFormat,
            frameCapacity: AVAudioFrameCount(AudioPacketTiming.framesPerPacket)) else { return }
        var suppliedInput = false
        var error: NSError?
        let status = decoder.convert(to: pcmOut, error: &error) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return compressed
        }
        guard status == .haveData else {
            roundTripAnomalyCount += 1
            Log.info("audioTrace: ⚠️ local AAC round-trip decode failed status=\(status) error=\(String(describing: error)) (anomaly #\(roundTripAnomalyCount))")
            return
        }
        guard let channelData = pcmOut.floatChannelData else { return }
        let frameLength = Int(pcmOut.frameLength)
        var hasNaNOrInf = false
        var maxAbsSample: Float = 0
        var jumpDetected = false
        // Channel 0 only: cheap per-packet heuristic, not authoritative —
        // a real audible defect that survives decode as "clean" (no NaN/
        // Inf, .haveData status) still tends to show up as either sustained
        // clipping (>= ~0dBFS for many consecutive samples, a converter/
        // gain-staging problem) or an abrupt inter-sample jump at a packet
        // boundary (a dropped/duplicated block or priming/remainder
        // mishandling) — exactly the failure modes that decode "fine" but
        // sound robotic/glitchy.
        let buf0 = channelData[0]
        for i in 0..<frameLength {
            let v = buf0[i]
            if v.isNaN || v.isInfinite { hasNaNOrInf = true }
            let absV = abs(v)
            if absV > maxAbsSample { maxAbsSample = absV }
            if let last = lastRoundTripSample, abs(v - last) > 1.5 { jumpDetected = true }
            lastRoundTripSample = v
        }
        for channel in 1..<Int(pcmOut.format.channelCount) {
            let buf = channelData[channel]
            for i in 0..<frameLength where buf[i].isNaN || buf[i].isInfinite { hasNaNOrInf = true }
        }
        if hasNaNOrInf {
            roundTripAnomalyCount += 1
            Log.info("audioTrace: ⚠️ local AAC round-trip produced NaN/Inf sample (anomaly #\(roundTripAnomalyCount)) — sender-side encode/input defect, not transport/receiver")
        }
        if maxAbsSample >= 0.999 {
            roundTripAnomalyCount += 1
            Log.info("audioTrace: ⚠️ local AAC round-trip sample near/at full-scale (\(maxAbsSample)) — possible clipping (anomaly #\(roundTripAnomalyCount))")
        }
        if jumpDetected {
            roundTripAnomalyCount += 1
            Log.info("audioTrace: ⚠️ local AAC round-trip inter-sample discontinuity at packet boundary (anomaly #\(roundTripAnomalyCount)) — possible dropped/duplicated block")
        }
        if pcmCompareDumpEnabled { dumpDecodedPCM(pcmOut) }
    }

    /// DEBUG-only A/B dump counterparts — see `pcmCompareDumpEnabled`'s doc
    /// comment. All three write to fixed, bounded files in `Log.directory`
    /// (never a hardcoded path — see this method's forensic note) and
    /// self-report every step, so a silent no-op is impossible to mistake
    /// for "nothing was wrong to report".
    ///
    /// FORENSIC NOTE: the first version of this hardcoded
    /// `~/Library/Logs/OpenDisplay`, while `Log.swift` actually resolves to
    /// `~/Library/Logs/<CFBundleName>` — `OpenDisplay Dev` for this
    /// checkout's local Debug signing override. The dump silently wrote to
    /// (or failed silently trying to write to) a folder nobody was looking
    /// in, while `AVAudioFile`'s throwing initializer was swallowed by
    /// `try?` with no failure log at all — the exact same "wrong hardcoded
    /// identity, silently" shape as the `UserDefaults` domain bug in
    /// `MacSender.beginAudioGeneration`. Fixed by reusing `Log.directory`
    /// (one source of truth) and never using `try?` on anything in this
    /// method without a paired log line.
    private func dumpSourcePCM(_ pcm: AVAudioPCMBuffer) {
        guard sourceDumpFrames < Self.pcmCompareDumpFrameLimit else { return }
        if sourceDumpFile == nil {
            sourceDumpFile = Self.makeDumpFile(name: "audio-compare-source.caf", format: pcm.format)
        }
        guard let sourceDumpFile else { return }
        do {
            try sourceDumpFile.write(from: pcm)
            sourceDumpFrames += Int(pcm.frameLength)
        } catch {
            Log.info("audioTrace: ⚠️ audio-compare-source.caf write failed: \(error)")
        }
    }

    private func dumpDecodedPCM(_ pcm: AVAudioPCMBuffer) {
        guard decodedDumpFrames < Self.pcmCompareDumpFrameLimit else { return }
        if decodedDumpFile == nil {
            decodedDumpFile = Self.makeDumpFile(name: "audio-compare-decoded-aac.caf", format: pcm.format)
        }
        guard let decodedDumpFile else { return }
        do {
            try decodedDumpFile.write(from: pcm)
            decodedDumpFrames += Int(pcm.frameLength)
            if decodedDumpFrames >= Self.pcmCompareDumpFrameLimit {
                Log.info("audioTrace: audio-compare-decoded-aac.caf reached \(decodedDumpFrames) frames — finalizing")
                finalizeDumpFiles()
            }
        } catch {
            Log.info("audioTrace: ⚠️ audio-compare-decoded-aac.caf write failed: \(error)")
        }
    }

    /// GOAL #7: the literal wire PCM — built directly from the SAME `Float`
    /// array (`interleaved`, from `encodePCM`) that becomes the
    /// `PCMPacketFrame` payload, not a re-derivation from the converter's
    /// `AVAudioPCMBuffer` — so this file is provably byte-identical to what
    /// actually goes on the wire.
    /// FORENSIC NOTE: the first version of this built an `interleaved:
    /// true` `AVAudioFormat`/`AVAudioPCMBuffer` and poked raw bytes into
    /// `audioBufferList.pointee.mBuffers.mData` directly, assuming that was
    /// the single interleaved buffer. On the user's first physical test
    /// this failed with `ExtAudioFileWrite Code=-50` (paramErr) and
    /// finalized with 0 frames — `AVAudioPCMBuffer` does not reliably
    /// expose interleaved storage as one contiguous buffer this way. Fixed
    /// by using `interleaved: false` (matching the pattern `dumpDecodedPCM`
    /// already uses successfully) and explicitly de-interleaving into
    /// `floatChannelData` — the exact inverse of the interleave this
    /// method's caller (`encodePCM`) already does, so the file's SAMPLE
    /// VALUES are still provably identical to the wire payload; only the
    /// on-disk container's channel layout differs from the wire's.
    private func dumpWirePCM(_ interleaved: [Float], frameCount: Int, channelCount: Int, sampleRate: Double) {
        guard wireDumpFrames < Self.pcmCompareDumpFrameLimit,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                channels: AVAudioChannelCount(channelCount), interleaved: false) else { return }
        if wireDumpFile == nil {
            wireDumpFile = Self.makeDumpFile(name: "audio-compare-wire-pcm.caf", format: format)
        }
        guard let wireDumpFile,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channelData = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                channelData[channel][frame] = interleaved[frame * channelCount + channel]
            }
        }
        do {
            try wireDumpFile.write(from: buffer)
            wireDumpFrames += frameCount
            if wireDumpFrames >= Self.pcmCompareDumpFrameLimit {
                Log.info("audioTrace: audio-compare-wire-pcm.caf reached \(wireDumpFrames) frames — finalizing")
                finalizeDumpFiles()
            }
        } catch {
            Log.info("audioTrace: ⚠️ audio-compare-wire-pcm.caf write failed: \(error)")
        }
    }

    private static func makeDumpFile(name: String, format: AVAudioFormat) -> AVAudioFile? {
        let dir = Log.directory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Log.info("audioTrace: ⚠️ could not create \(dir.path): \(error)")
            return nil
        }
        let url = dir.appendingPathComponent(name)
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            Log.info("audioTrace: opened PCM compare dump \(url.path) settings=\(format.settings)")
            return file
        } catch {
            Log.info("audioTrace: ⚠️ could not open \(url.path) for writing: \(error)")
            return nil
        }
    }

    /// Drops the strong references to every open dump file, which is what
    /// actually finalizes an `AVAudioFile` (flushes its header/frame count —
    /// there is no explicit `close()`). Called from `reset()` (every fresh
    /// generation) and whenever a dump hits its frame limit, so a file is
    /// never left in a state where its header doesn't reflect what was
    /// written — the state that would make it fail to open/play at all.
    private func finalizeDumpFiles() {
        if let sourceDumpFile {
            Log.info("audioTrace: finalized \(sourceDumpFile.url.lastPathComponent) frames=\(sourceDumpFrames) durationSeconds=\(sourceDumpFile.length > 0 ? Double(sourceDumpFrames) / sourceDumpFile.processingFormat.sampleRate : 0)")
        }
        if let decodedDumpFile {
            Log.info("audioTrace: finalized \(decodedDumpFile.url.lastPathComponent) frames=\(decodedDumpFrames) durationSeconds=\(decodedDumpFile.length > 0 ? Double(decodedDumpFrames) / decodedDumpFile.processingFormat.sampleRate : 0)")
        }
        if let wireDumpFile {
            Log.info("audioTrace: finalized \(wireDumpFile.url.lastPathComponent) frames=\(wireDumpFrames) durationSeconds=\(wireDumpFile.length > 0 ? Double(wireDumpFrames) / wireDumpFile.processingFormat.sampleRate : 0)")
        }
        sourceDumpFile = nil
        sourceDumpFrames = 0
        decodedDumpFile = nil
        decodedDumpFrames = 0
        wireDumpFile = nil
        wireDumpFrames = 0
    }

    /// GOAL #6: min/max/RMS/peak-abs/NaN/Inf over one packet's samples,
    /// logged every 100 packets (not per-packet). `StreamReceiver` logs the
    /// identical shape for the reconstructed PCM it enqueues — the two are
    /// meant to be read side by side, not diffed programmatically.
    private func logPCMSanityIfDue(_ interleaved: [Float], frameCount: Int, channelCount: Int, side: String) {
        pcmPacketsSinceSanityLog += 1
        guard pcmPacketsSinceSanityLog % 100 == 1 else { return }
        var minV: Float = .greatestFiniteMagnitude
        var maxV: Float = -.greatestFiniteMagnitude
        var sumSquares: Double = 0
        var peakAbs: Float = 0
        var nanCount = 0
        var infCount = 0
        for v in interleaved {
            if v.isNaN { nanCount += 1; continue }
            if v.isInfinite { infCount += 1; continue }
            if v < minV { minV = v }
            if v > maxV { maxV = v }
            let a = abs(v)
            if a > peakAbs { peakAbs = a }
            sumSquares += Double(v) * Double(v)
        }
        let rms = interleaved.isEmpty ? 0 : (sumSquares / Double(interleaved.count)).squareRoot()
        let checksum = PCMChecksum.fnv1a(interleaved)
        Log.info("audioTrace: PCM sanity side=\(side) frameCount=\(frameCount) channels=\(channelCount) min=\(minV) max=\(maxV) rms=\(String(format: "%.4f", rms)) peakAbs=\(peakAbs) nanCount=\(nanCount) infCount=\(infCount) checksum=\(checksum)")
    }
    #endif

    #if DEBUG
    /// Self-report for `MacSender.beginAudioGeneration`'s diagnostics block
    /// (GOAL #1) — DEBUG-only opt-in flags and the resolved absolute dump
    /// directory, read from the actor so `MacSender` never has to duplicate
    /// or guess at this encoder's private DEBUG state.
    func debugDiagnosticStatus() -> (pcmCompareDumpEnabled: Bool, localRoundTripEnabled: Bool, debugDumpEnabled: Bool, dumpDirectory: String) {
        (pcmCompareDumpEnabled, localRoundTripEnabled, debugDumpEnabled, Log.directory.path)
    }
    #endif


    /// Builds an `AVAudioPCMBuffer` by copying a captured audio
    /// `CMSampleBuffer`'s samples into freshly-owned storage.
    ///
    /// FORENSIC NOTE (found auditing real-device garbled/corrupted audio):
    /// an earlier version of this method built the buffer with
    /// `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:deallocator:)` over a
    /// manually `AudioBufferList.allocate`d list, then `free()`d that list
    /// in a `defer` that ran as soon as the function returned — while the
    /// just-created `AVAudioPCMBuffer` (created with the explicit
    /// `NoCopy` variant) held a raw pointer into that exact freed memory
    /// for its entire remaining lifetime. Every sample this function
    /// produced was a use-after-free the moment `AVAudioConverter` read it
    /// back later in `encode(_:)`. `CMSampleBufferCopyPCMDataIntoAudioBufferList`
    /// is the Apple-documented way to copy PCM out of a `CMSampleBuffer`
    /// into a buffer whose lifetime you actually own — no manual
    /// `AudioBufferList` allocation, no deallocator lifetime hazard.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        pcmBuffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList)
        guard status == noErr else {
            #if DEBUG
            Log.info("audioTrace: CMSampleBufferCopyPCMDataIntoAudioBufferList failed status=\(status)")
            #endif
            return nil
        }
        return pcmBuffer
    }

    #if DEBUG
    /// Wraps one raw AAC-LC access unit in a 7-byte ADTS header (from the
    /// AudioSpecificConfig we already computed — same sampling-frequency
    /// index table as `audioSpecificConfig`) and appends it to the debug
    /// dump file, so the encoder's actual output can be verified by ear or
    /// with `ffprobe`/`afinfo`, independent of the network/receiver path
    /// entirely. Silently stops after `debugDumpPacketLimit` packets.
    private func dumpPacketForVerification(_ payload: Data, sampleRate: Double, channelCount: Int, cookie: Data) {
        guard debugDumpPacketCount < Self.debugDumpPacketLimit,
              let header = AACLCFraming.adtsHeader(
                payloadLength: payload.count, sampleRate: sampleRate, channelCount: channelCount) else { return }
        if debugDumpHandle == nil {
            let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/OpenDisplay", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("audio-debug-dump.aac")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            debugDumpHandle = try? FileHandle(forWritingTo: url)
            Log.info("audioTrace: writing debug AAC dump to \(url.path)")
        }
        guard let handle = debugDumpHandle else { return }
        handle.write(header)
        handle.write(payload)
        debugDumpPacketCount += 1
        if debugDumpPacketCount == Self.debugDumpPacketLimit {
            Log.info("audioTrace: debug AAC dump reached \(Self.debugDumpPacketLimit) packets — stopping (file left in place)")
            try? debugDumpHandle?.close()
        }
    }
    #endif
}
