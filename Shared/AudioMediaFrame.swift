import CoreMedia
import Foundation

// Binary framing for Mac system-audio media (PROTOCOL.md section 5A,
// introduced at `pv` 12 — see `WireProtocol.audioWireVersion`).
//
// Every wire frame is still `[4-byte length][payload]` (PROTOCOL.md section
// 3). The existing section-4 demux heuristic classifies a payload as JSON
// control (`< 32768 bytes, starts with '{', no NUL byte`) or legacy video
// (everything else); both of those payload shapes always start with `{`
// (0x7B) today and always will — the video telemetry prefix is JSON, and
// control messages are JSON. An audio media frame instead starts with a
// dedicated one-byte marker, `0x01` (ASCII SOH), which cannot collide with
// either existing shape and needs no heuristic: the receiver checks this
// single byte before running the legacy demux at all. Because audio frames
// are gated on `WireProtocol.audioWireVersion`, a peer below that version
// never receives one, so there is no backward-compatibility hazard.
enum AudioMediaFrame {
    /// First byte of every audio media frame payload.
    static let marker: UInt8 = 0x01

    private enum Subtype: UInt8 {
        case config = 0x01
        case packet = 0x02
        /// DEBUG-only diagnostic PCM bypass (see `MacSender.audioDebugPCMMode`
        /// / `AudioCaptureEncoder.encodePCM`) — a developer-only A/B mode for
        /// isolating whether remaining audio garble is in AAC encode/decode
        /// or upstream of it. A production sender never emits these; a
        /// receiver that doesn't recognize them (e.g. a Release build, which
        /// never decodes past the marker byte for this subtype in practice)
        /// simply drops the frame like any other malformed one. No wire
        /// version bump — it rides the existing pv 12 audio marker byte.
        case pcmConfig = 0x03
        case pcmPacket = 0x04
    }

    case config(AudioConfigFrame)
    case packet(AudioPacketFrame)
    case pcmConfig(PCMConfigFrame)
    case pcmPacket(PCMPacketFrame)

    static func isAudioFrame(_ payload: Data) -> Bool {
        payload.first == marker
    }

    func encode() -> Data {
        var data = Data([Self.marker])
        switch self {
        case .config(let config):
            data.append(Subtype.config.rawValue)
            data.append(config.encode())
        case .packet(let packet):
            data.append(Subtype.packet.rawValue)
            data.append(packet.encode())
        case .pcmConfig(let config):
            data.append(Subtype.pcmConfig.rawValue)
            data.append(config.encode())
        case .pcmPacket(let packet):
            data.append(Subtype.pcmPacket.rawValue)
            data.append(packet.encode())
        }
        return data
    }

    /// Returns `nil` for anything malformed or truncated — callers MUST
    /// treat that as "drop the frame", never as fatal (PROTOCOL.md's
    /// tolerance rule for control messages applies equally here).
    static func decode(_ payload: Data) -> AudioMediaFrame? {
        guard payload.count >= 2, payload.first == marker else { return nil }
        guard let subtype = Subtype(rawValue: payload[payload.startIndex + 1]) else { return nil }
        let body = payload.suffix(from: payload.startIndex + 2)
        switch subtype {
        case .config:
            guard let config = AudioConfigFrame.decode(body) else { return nil }
            return .config(config)
        case .packet:
            guard let packet = AudioPacketFrame.decode(body) else { return nil }
            return .packet(packet)
        case .pcmConfig:
            guard let config = PCMConfigFrame.decode(body) else { return nil }
            return .pcmConfig(config)
        case .pcmPacket:
            guard let packet = PCMPacketFrame.decode(body) else { return nil }
            return .pcmPacket(packet)
        }
    }
}

/// AAC format description parameters: sent once when audio starts (and
/// again whenever the format changes) so the receiver can build a
/// `CMAudioFormatDescription` before any packet arrives.
struct AudioConfigFrame: Equatable {
    var sampleRate: UInt32
    var channelCount: UInt8
    /// The AudioSpecificConfig (AAC "magic cookie") describing profile,
    /// sample rate index, and channel configuration.
    var cookie: Data

    func encode() -> Data {
        var data = Data()
        data.append(bigEndian: sampleRate)
        data.append(channelCount)
        data.append(bigEndian: UInt16(cookie.count))
        data.append(cookie)
        return data
    }

    static func decode(_ body: Data) -> AudioConfigFrame? {
        var reader = BinaryReader(body)
        guard let sampleRate: UInt32 = reader.read(),
              let channelCount: UInt8 = reader.read(),
              let cookieLen: UInt16 = reader.read(),
              let cookie = reader.readData(Int(cookieLen)) else { return nil }
        return AudioConfigFrame(sampleRate: sampleRate, channelCount: channelCount, cookie: cookie)
    }
}

/// One encoded AAC access unit (raw, no ADTS header — the format
/// description carries what an ADTS header would otherwise repeat).
struct AudioPacketFrame: Equatable {
    var sequence: UInt32
    /// Capture timestamp, milliseconds since the Unix epoch on the sender's
    /// clock — the same coordinate space as the video telemetry prefix's
    /// `cap` field (PROTOCOL.md 5.1), taken from the audio sample buffer's
    /// own presentation timestamp, never from send/arrival time.
    var capturedAtMs: Int64
    var durationMs: UInt32
    var payload: Data

    func encode() -> Data {
        var data = Data()
        data.append(bigEndian: sequence)
        data.append(bigEndian: UInt64(bitPattern: capturedAtMs))
        data.append(bigEndian: durationMs)
        data.append(bigEndian: UInt32(payload.count))
        data.append(payload)
        return data
    }

    static func decode(_ body: Data) -> AudioPacketFrame? {
        var reader = BinaryReader(body)
        guard let sequence: UInt32 = reader.read(),
              let capturedRaw: UInt64 = reader.read(),
              let durationMs: UInt32 = reader.read(),
              let payloadLen: UInt32 = reader.read(),
              let payload = reader.readData(Int(payloadLen)) else { return nil }
        return AudioPacketFrame(sequence: sequence,
                                capturedAtMs: Int64(bitPattern: capturedRaw),
                                durationMs: durationMs,
                                payload: payload)
    }
}

/// DEBUG-only diagnostic PCM format description: sent once at the start of
/// the PCM bypass A/B mode (and again if the format changes) so the
/// receiver can build an `lpcm` `CMAudioFormatDescription` before any
/// packet arrives. Unlike `AudioConfigFrame` there is no codec magic
/// cookie — wire PCM is always 32-bit Float32 interleaved (see
/// `AudioCaptureEncoder.encodePCM`), so sample rate and channel count fully
/// describe it.
struct PCMConfigFrame: Equatable {
    var sampleRate: UInt32
    var channelCount: UInt8

    func encode() -> Data {
        var data = Data()
        data.append(bigEndian: sampleRate)
        data.append(channelCount)
        return data
    }

    static func decode(_ body: Data) -> PCMConfigFrame? {
        var reader = BinaryReader(body)
        guard let sampleRate: UInt32 = reader.read(),
              let channelCount: UInt8 = reader.read() else { return nil }
        return PCMConfigFrame(sampleRate: sampleRate, channelCount: channelCount)
    }
}

/// DEBUG-only diagnostic PCM access unit: one ScreenCaptureKit audio
/// callback's worth of samples, converted to 32-bit Float32 interleaved
/// (see `AudioCaptureEncoder.encodePCM`) and sent raw, uncompressed.
struct PCMPacketFrame: Equatable {
    var sequence: UInt32
    /// Same coordinate space as `AudioPacketFrame.capturedAtMs`.
    var capturedAtMs: Int64
    /// Interleaved sample frames represented by `payload`
    /// (`payload.count == frameCount * channelCount * 4`).
    var frameCount: UInt32
    var payload: Data

    func encode() -> Data {
        var data = Data()
        data.append(bigEndian: sequence)
        data.append(bigEndian: UInt64(bitPattern: capturedAtMs))
        data.append(bigEndian: frameCount)
        data.append(bigEndian: UInt32(payload.count))
        data.append(payload)
        return data
    }

    static func decode(_ body: Data) -> PCMPacketFrame? {
        var reader = BinaryReader(body)
        guard let sequence: UInt32 = reader.read(),
              let capturedRaw: UInt64 = reader.read(),
              let frameCount: UInt32 = reader.read(),
              let payloadLen: UInt32 = reader.read(),
              let payload = reader.readData(Int(payloadLen)) else { return nil }
        return PCMPacketFrame(sequence: sequence,
                              capturedAtMs: Int64(bitPattern: capturedRaw),
                              frameCount: frameCount,
                              payload: payload)
    }
}

/// Minimal big-endian binary cursor. Never traps — every read reports
/// failure instead of crashing on a truncated/malformed frame.
private struct BinaryReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    mutating func read<T: FixedWidthInteger>() -> T? {
        let width = MemoryLayout<T>.size
        guard offset + width <= data.endIndex else { return nil }
        let slice = data[offset..<offset + width]
        offset += width
        var value: T = 0
        for byte in slice { value = (value << 8) | T(byte) }
        return value
    }

    mutating func readData(_ length: Int) -> Data? {
        guard length >= 0, offset + length <= data.endIndex else { return nil }
        let slice = data[offset..<offset + length]
        offset += length
        return Data(slice)
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    mutating func append(_ byte: UInt8) {
        append(contentsOf: [byte])
    }
}

/// Shared AAC-LC framing math: the MPEG-4 sampling-frequency-index table
/// used both to build the AudioSpecificConfig a receiver needs
/// (`Mac/AudioCaptureEncoder.swift`) and, DEBUG-only, to synthesize ADTS
/// headers for the local encoder-output verification dump. Pure and
/// testable independent of any Apple media framework — see
/// `AudioMediaFrameTests` for "AAC packet byte boundaries" coverage.
enum AACLCFraming {
    static let frequencyIndex: [Int: UInt8] = [
        96_000: 0, 88_200: 1, 64_000: 2, 48_000: 3, 44_100: 4, 32_000: 5,
        24_000: 6, 22_050: 7, 16_000: 8, 12_000: 9, 11_025: 10, 8_000: 11, 7_350: 12,
    ]

    /// The 2-byte MPEG-4 AudioSpecificConfig for plain AAC-LC (ISO/IEC
    /// 14496-3): 5-bit object type (2 = AAC LC), 4-bit sampling-frequency
    /// index, 4-bit channel configuration, then three flag bits (frame
    /// length 1024, no dependsOnCoreCoder, no extension) — all zero for
    /// this encoder's fixed configuration.
    static func audioSpecificConfig(sampleRate: Double, channelCount: Int) -> Data? {
        guard let freqIndex = frequencyIndex[Int(sampleRate.rounded())],
              (1...7).contains(channelCount) else { return nil }
        let objectType: UInt8 = 2   // AAC LC
        let channelConfig = UInt8(channelCount)
        let byte0 = (objectType << 3) | (freqIndex >> 1)
        let byte1 = ((freqIndex & 1) << 7) | (channelConfig << 3)
        return Data([byte0, byte1])
    }

    /// A 7-byte ADTS header (no CRC) framing one AAC-LC access unit of
    /// `payloadLength` bytes — used only by the DEBUG-only local
    /// verification dump; the wire format carries raw AAC with no ADTS
    /// framing (PROTOCOL.md 5A).
    static func adtsHeader(payloadLength: Int, sampleRate: Double, channelCount: Int) -> Data? {
        guard let freqIndex = frequencyIndex[Int(sampleRate.rounded())],
              (1...7).contains(channelCount) else { return nil }
        let frameLength = UInt32(7 + payloadLength)
        let channel = UInt8(channelCount)
        var header = Data(count: 7)
        header[0] = 0xFF
        header[1] = 0xF1   // MPEG-4, layer 0, no CRC
        header[2] = ((2 - 1) << 6) | (freqIndex << 2) | (channel >> 2)
        header[3] = ((channel & 0x3) << 6) | UInt8((frameLength >> 11) & 0x3)
        header[4] = UInt8((frameLength >> 3) & 0xFF)
        header[5] = UInt8((frameLength & 0x7) << 5) | 0x1F
        header[6] = 0xFC
        return header
    }
}

/// Pure timing math for one AAC-LC access unit's wire timestamp/duration,
/// factored out of `AudioCaptureEncoder` for testability: "timestamp
/// progression at 48 kHz / 1024 frames" and "no double-counting sample
/// time" are exactly the properties `AudioMediaFrameTests` verifies here.
enum AudioPacketTiming {
    /// Samples per AAC-LC access unit — fixed by the codec, not a tunable.
    static let framesPerPacket: Int64 = 1024

    static func capturedAtMs(originWallMs: Double, encodedSampleCount: Int64, sampleRate: Double) -> Int64 {
        Int64(originWallMs + (Double(encodedSampleCount) / sampleRate) * 1000)
    }

    /// DIAGNOSTIC/DISPLAY-ONLY — see `exactSampleDuration`. `durationMs`
    /// truncates 1024/48000s (21.333...ms) to a whole millisecond for the
    /// wire `AudioPacketFrame.durationMs` field and log lines; it is never
    /// consumed by real sample-buffer/renderer scheduling (verified this
    /// pass — GOAL: rule out or confirm rounding as the remaining glitch's
    /// cause. `StreamReceiver.scheduleAudioPacket` passes `packet.durationMs`
    /// only into `logAudioTimingDiagnostic`; the actual `CMSampleTimingInfo`
    /// duration always comes from `exactSampleDuration`, an exact rational
    /// CMTime, so this truncation cannot itself explain the glitch).
    static func durationMs(sampleRate: Double) -> UInt32 {
        UInt32((Double(framesPerPacket) / sampleRate) * 1000)
    }

    /// The value that actually feeds `CMSampleTimingInfo.duration` in
    /// `StreamReceiver.scheduleDecodedAudio` — an EXACT rational CMTime
    /// (`1024/sampleRate` seconds, e.g. 1024/48000 with no rounding),
    /// never a Double-seconds or rounded-millisecond intermediate. Kept as
    /// its own function (not inlined at the call site) so the "is this
    /// exact" property is independently testable — see
    /// `AudioMediaFrameTests.testExactSampleDurationIsNotQuantizedToWholeMilliseconds`.
    static func exactSampleDuration(sampleRate: Double) -> CMTime {
        CMTime(value: framesPerPacket, timescale: Int32(sampleRate))
    }
}

/// DEBUG-only checksum shared verbatim by `AudioCaptureEncoder` (sender) and
/// `StreamReceiver` (receiver) so a periodic checksum logged on each side
/// can be compared by eye — a mismatch means the wire/framing corrupted the
/// bytes; a match with still-wrong-sounding audio means the bytes arrived
/// intact and something is interpreting them incorrectly (GOAL #5).
enum PCMChecksum {
    /// 32-bit FNV-1a over raw `Float` sample bytes — no crypto dependency,
    /// deterministic across sender/receiver regardless of endianness*
    /// *both sides run on the same little-endian CPU family (Apple
    /// Silicon/Intel Mac and A-series/M-series iPhone), so this is
    /// diagnostic-only and deliberately not a portable wire checksum.
    static func fnv1a(_ samples: [Float]) -> UInt32 {
        samples.withUnsafeBytes { fnv1a(bytes: $0) }
    }

    /// Byte-level overload — GOAL (receiver-side AAC investigation): used
    /// to checksum raw AAC access-unit payloads (not PCM samples), so a
    /// sender-logged and receiver-logged checksum for the same
    /// generation/sequence can be compared to rule transport corruption in
    /// or out independent of the PCM path.
    static func fnv1a(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { fnv1a(bytes: $0) }
    }

    private static func fnv1a(bytes: UnsafeRawBufferPointer) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in bytes {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }
}

/// Pure timing logic for the receiver-local A/V sync offset. Positive
/// values delay audio; negative values delay video (audio cannot play
/// before it has arrived over the wire, so the only way to make it sound
/// "earlier" relative to the picture is to hold the picture back instead —
/// see `StreamReceiver`'s audio scheduling and delayed video presentation).
enum AVSyncOffset {
    static let range = -1_000...1_000
    static let stepMs = 25

    static func clamped(_ ms: Int) -> Int {
        min(max(ms, range.lowerBound), range.upperBound)
    }

    /// Milliseconds of audio delay to apply on top of its natural
    /// (capture-timeline-derived) schedule. Zero unless the offset is
    /// positive.
    static func audioDelayMs(for offsetMs: Int) -> Int {
        max(0, clamped(offsetMs))
    }

    /// Milliseconds to hold a decoded video frame before presenting it.
    /// Zero unless the offset is negative.
    static func videoDelayMs(for offsetMs: Int) -> Int {
        max(0, -clamped(offsetMs))
    }
}
