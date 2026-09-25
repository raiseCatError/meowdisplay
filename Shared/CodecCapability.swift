import Foundation

/// Compiled into BOTH the Mac and iOS/MacReceiver targets (see project.yml
/// `sources`), like `EncoderCapability.swift`. Pure, platform-neutral codec
/// model + Auto-selection policy — no VideoToolbox dependency, so it is
/// directly unit-testable.
///
/// HEVC/H.265 milestone: MEOW streams H.264 Annex B today (universal
/// compatibility path). This models the SECOND, OPTIONAL codec — HEVC Main,
/// 8-bit only, hardware-accelerated only, no software fallback — and how a
/// session picks between them. See PROTOCOL.md section 5 (codec framing) and
/// COMPATIBILITY.md section 6 (additive-change policy) for the wire side.
enum StreamCodec: String, Codable, CaseIterable, Identifiable {
    case h264
    case hevc

    var id: String { rawValue }

    /// Wire/log token — matches this enum's `rawValue`, kept as a separate
    /// name so call sites read as "the wire string" rather than incidentally
    /// relying on `rawValue` never changing shape.
    var wireValue: String { rawValue }
}

/// User-facing codec preference (SETTINGS/UX). Mac-authoritative, same
/// request/state shape as `StreamingProfile`/`StreamingPriority`. Default
/// `.auto`.
enum CodecPreference: String, CaseIterable, Codable, Identifiable {
    case auto
    case h264
    case hevc

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return String(localized: "Auto")
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }

    var explanation: String {
        switch self {
        case .auto: return String(localized: "Uses H.264 unless HEVC is needed and available to satisfy the requested stream.")
        case .h264: return String(localized: "Always uses H.264, the universal compatibility codec.")
        case .hevc: return String(localized: "Uses HEVC when both this Mac and the connected device support it, otherwise falls back to H.264.")
        }
    }
}

/// Pure HEVC NAL-unit classification (RECEIVER DECODER / HEVC NAL PARAMETER
/// SET HANDLING in the milestone spec). Deliberately NOT `first & 0x1F` —
/// that is H.264's type space. HEVC's NAL header is two bytes; the type is
/// bits 1-6 of the FIRST byte: `(firstByte >> 1) & 0x3F`. Kept as a pure,
/// directly-testable function so the wire-parsing call site never has to
/// re-derive this bit math inline.
enum HEVCNALUnitType: Equatable {
    case vps
    case sps
    case pps
    case seiPrefix
    case seiSuffix
    case other(Int)

    static func classify(firstByte: UInt8) -> HEVCNALUnitType {
        switch Int((firstByte >> 1) & 0x3F) {
        case 32: return .vps
        case 33: return .sps
        case 34: return .pps
        case 39: return .seiPrefix
        case 40: return .seiSuffix
        case let other: return .other(other)
        }
    }
}

/// Pure wrapper around the receiver-side hardware-decode capability decision
/// (RECEIVER DECODER / HARDWARE CAPABILITY in the milestone spec) — kept
/// separate from the actual `VTIsHardwareDecodeSupported` call so the
/// decision itself ("HEVC support => advertise both codecs, H.264 always
/// present") is directly unit-testable without VideoToolbox.
enum CodecCapabilityProbe {
    static func supportedCodecs(hevcHardwareDecodeSupported: Bool) -> [StreamCodec] {
        hevcHardwareDecodeSupported ? [.h264, .hevc] : [.h264]
    }

    /// Whether a receiver's advertised `hello.codecs` (`PhoneInfo.codecs`)
    /// includes HEVC. Deliberately takes ONLY the codec list — never the
    /// receiver's overall protocol version — because codec capability and
    /// overall `pv` are independent axes: a peer may advertise a lower `pv`
    /// without that saying anything about codec support.
    /// `nil` (the field never sent) or a list without `"hevc"` both mean
    /// H.264-only — absence is never treated as "unknown means everything".
    static func receiverSupportsHEVC(codecs: [String]?) -> Bool {
        codecs?.contains(StreamCodec.hevc.wireValue) ?? false
    }

    /// Whether `streamCodecState` should be (re-)sent to a peer whose `hello`
    /// carried `codecs` — including on every RECONNECT/re-hello, not only the
    /// first one, and regardless of whether the peer's `hello` changed
    /// anything (RECONNECT / TRANSPORT MIGRATION in the milestone spec).
    ///
    /// A reconnect or route migration (a new TCP connection, no resolution/
    /// FPS change) never re-runs `setupEncoder` — the existing encoder
    /// session simply keeps running whatever codec it already had. But the
    /// RECEIVER side's own belief about the active codec lives only in that
    /// `StreamReceiver` instance's memory, defaulting back to `.h264` if the
    /// receiver app/process restarted (a fresh `StreamReceiver()`) while the
    /// Mac's encoder stayed on HEVC. Without an explicit resend gated ONLY on
    /// capability advertisement — never on whether anything about the hello
    /// actually changed, and never by re-running `CodecSelectionPolicy` — the
    /// receiver would misclassify the next HEVC keyframe's VPS/SPS/PPS using
    /// H.264's `&0x1F` NAL-type space. This is deliberately the SAME
    /// predicate `receiverSupportsHEVC` and `MacSender.sendStreamCodecState`
    /// use for "does this peer understand codec negotiation at all" — codecs
    /// field presence, not `pv`, not HEVC support specifically (an H.264-only
    /// receiver still needs its H.264 confirmed after a process restart, in
    /// principle, even though H.264 is also the safe unconfirmed default).
    static func shouldConfirmCodecOnHello(codecs: [String]?) -> Bool {
        codecs != nil
    }
}

/// The receiver decode-raster ceiling APPLICABLE TO A GIVEN CODEC
/// (CODEC-SAFE STREAM CONFIGURATION in the milestone spec).
///
/// `hello.maxEncodeWide/High` (PROTOCOL.md 6.5, `DecodeCeiling.clamp`) is
/// historically an H.264-SPECIFIC number: iOS's own doc comment
/// (`iOSDecodeCeiling`) calls it "the VideoToolbox H.264 hardware decoder's
/// actual pixel ceiling", and `MacReceiver.start()`'s comment is explicit
/// that "4096x2304 is H.264's practical hardware-decode ceiling" and flags
/// "revisit when an HEVC path lands (HEVC decodes 5K fine even on a 2017
/// iMac)" — i.e. the codebase's own author already expected HEVC's real
/// ceiling to be materially higher than H.264's measured one.
///
/// Despite that, this milestone does NOT invent a distinct, larger HEVC
/// number: VideoToolbox exposes no queryable "max decodable raster for
/// codec X" API, the MacReceiver comment's "5K"/"2017 iMac" figures are an
/// unvalidated developer note (not a measurement this build can cite), and
/// asserting an unverified larger ceiling into a pre-hardware-test build
/// risks the exact "sits on an impossible stream" failure this whole
/// decode-ceiling mechanism exists to prevent. The safe, conservative,
/// TRUTHFUL representation today is: HEVC's applicable ceiling equals
/// H.264's legacy-measured one, exactly like `EncoderCapability.codecSafeFPS`
/// refuses to invent an HEVC macroblock-rate ceiling. This is a DELIBERATE
/// choice, not an oversight — the seam exists so a future receiver that can
/// truthfully advertise a distinct, larger HEVC-specific ceiling (a real
/// measurement, or a genuine VideoToolbox capability) only has to extend
/// `PhoneInfo`/`hello` additively (e.g. `hevcMaxEncodeWide/High`) and thread
/// it through here — nothing else in the codec-selection pipeline needs to
/// change shape.
enum CodecDecodeCeiling {
    /// `(width, height)` — `nil, nil` for no known ceiling at all.
    static func applicable(
        codec: StreamCodec, legacyMaxEncodeWide: Int?, legacyMaxEncodeHigh: Int?
    ) -> (width: Int?, height: Int?) {
        // Both codecs currently resolve to the SAME legacy (H.264-measured)
        // ceiling — see the type doc above for why this is not yet a bug to
        // fix by inventing a bigger HEVC number. `codec` is accepted (rather
        // than this being a bare passthrough) so call sites read as
        // codec-aware and the seam is already in place for a future
        // HEVC-specific input.
        switch codec {
        case .h264, .hevc:
            return (legacyMaxEncodeWide, legacyMaxEncodeHigh)
        }
    }
}

/// Pure Auto-selection policy (AUTO POLICY in the milestone spec).
///
/// Deliberately conservative for this milestone: H.264 is the known latency
/// baseline, and Auto only reaches for HEVC to solve a REAL codec-driven
/// constraint — it never means "HEVC whenever supported". Mirrors
/// `EncoderCapability`'s shape (a pure `Input` -> `Result` function), so it's
/// directly unit-testable without VideoToolbox.
enum CodecSelectionPolicy {
    enum Reason: String {
        /// H.264 satisfies the requested configuration outright.
        case requestSatisfiedByH264 = "h264 safe configuration satisfies requested stream"
        /// H.264 would need to reduce the requested configuration, and
        /// mutually-supported hardware HEVC can satisfy it instead.
        case h264WouldReduceConfiguration = "h264 safe configuration would reduce requested stream"
        /// H.264 would need to reduce the requested configuration, but HEVC
        /// is unavailable (not mutually supported) — fall back to the
        /// safest valid H.264 configuration.
        case hevcUnavailable = "hevc unavailable — using safest valid h264 configuration"
        /// The user explicitly picked this codec.
        case explicitPreference = "explicit preference"
        /// The user explicitly picked HEVC, but it is not mutually
        /// supported by this session's sender/receiver pair.
        case explicitHEVCUnsupported = "receiver does not advertise hardware HEVC decode"
        /// HEVC was active but became unusable mid-session (receiver
        /// capability disappeared, an older peer connected, or the hardware
        /// encoder failed at runtime) — safe recovery to H.264.
        case runtimeFallback = "hevc unavailable at runtime — recovered to h264"
    }

    struct Input {
        let preference: CodecPreference
        /// This Mac has a real, usable hardware HEVC encoder (VideoToolbox
        /// capability, never an OS-version guess).
        let senderSupportsHEVC: Bool
        /// The connected receiver advertised hardware HEVC decode support.
        let receiverSupportsHEVC: Bool
        /// The stream configuration actually being requested for this
        /// session (post decode-ceiling clamping — PROTOCOL.md 6.5).
        let requestedWidth: Int
        let requestedHeight: Int
        let requestedFPS: Int

        init(preference: CodecPreference, senderSupportsHEVC: Bool, receiverSupportsHEVC: Bool,
             requestedWidth: Int, requestedHeight: Int, requestedFPS: Int) {
            self.preference = preference
            self.senderSupportsHEVC = senderSupportsHEVC
            self.receiverSupportsHEVC = receiverSupportsHEVC
            self.requestedWidth = requestedWidth
            self.requestedHeight = requestedHeight
            self.requestedFPS = requestedFPS
        }

        var hevcMutuallySupported: Bool { senderSupportsHEVC && receiverSupportsHEVC }
    }

    struct Result: Equatable {
        let codec: StreamCodec
        let reason: String
    }

    /// Pure decision function. Never touches VideoToolbox/UserDefaults —
    /// callers gather `Input` from actual capability probes and pass it in.
    static func select(_ input: Input) -> Result {
        switch input.preference {
        case .h264:
            return Result(codec: .h264, reason: Reason.explicitPreference.rawValue)

        case .hevc:
            if input.hevcMutuallySupported {
                return Result(codec: .hevc, reason: Reason.explicitPreference.rawValue)
            }
            return Result(codec: .h264, reason: Reason.explicitHEVCUnsupported.rawValue)

        case .auto:
            // Step 1-3: does H.264's codec-safe ceiling, at the requested
            // pixel size, cover the requested FPS without reducing it?
            // `EncoderCapability.codecSafeFPS` is H.264-specific (its own
            // doc comment: a macroblock-rate constant derived from real
            // hardware measurement of the H.264 encoder) — never applied to
            // HEVC, per the milestone's CODEC-SAFE STREAM CONFIGURATION
            // section.
            let h264Ceiling = EncoderCapability.codecSafeFPS(
                width: input.requestedWidth, height: input.requestedHeight)
            let h264SatisfiesRequest = h264Ceiling >= input.requestedFPS

            if h264SatisfiesRequest {
                return Result(codec: .h264, reason: Reason.requestSatisfiedByH264.rawValue)
            }
            // Step 5: H.264 would need to reduce the request. HEVC has no
            // established macroblock-rate ceiling in this codebase (no
            // hardware measurement backs one — inventing one would be the
            // "fake universal HEVC level ceiling" the milestone explicitly
            // forbids), so mutual hardware support is treated as sufficient
            // to satisfy the request; a runtime encoder-creation failure
            // still falls back safely via `runtimeFallback` regardless.
            if input.hevcMutuallySupported {
                return Result(codec: .hevc, reason: Reason.h264WouldReduceConfiguration.rawValue)
            }
            // Step 6: HEVC unavailable — take the safest valid H.264
            // configuration (the reduction itself is the caller's existing
            // `EncoderCapability`/`StreamingFPSPolicy` clamping; this policy
            // only decides the CODEC).
            return Result(codec: .h264, reason: Reason.hevcUnavailable.rawValue)
        }
    }
}
