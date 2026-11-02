package com.raisecaterror.meowdisplay.core.remote

/**
 * Which Tailscale endpoints a Mac reports for automatic Remote Access may be kept
 * (Shared/TailnetEndpointFilter.swift; both run fixtures/remote/tailnet-endpoint-vectors.json).
 *
 * An endpoint is only a routing hint: the pinned mutual-TLS handshake decides who answers. The
 * filter keeps the hints narrow anyway, so a report can never point this device at a LAN or public
 * address, Tailscale's own service address, or another tailnet: only 100.64.0.0/10,
 * fd7a:115c:a1e0::/48 and MagicDNS names (`<host>.<tailnet>.ts.net`). Pure and DNS-free.
 */
object TailnetEndpointFilter {
    const val MAX_NAMES = 2
    const val MAX_ADDRESSES = 4

    enum class Reason(val wire: String) {
        /** Not a well-formed name or address. */
        Invalid("invalid"),
        /** Well-formed, but not a Tailscale address or MagicDNS name. */
        NotTailnet("notTailnet"),
        /** Tailscale's own service address (100.100.100.100), never a peer. */
        Reserved("reserved"),
        /** A MagicDNS name in a tailnet other than the one expected. */
        OtherTailnet("otherTailnet"),
        /** Past the per-report cap. */
        OverCap("overCap"),
    }

    /** [value] is the reported value, trimmed. */
    data class Rejection(val value: String, val reason: Reason)

    /** [rejected] keeps the order the values came in: names first, then addresses. */
    data class Result(val names: List<String>, val addresses: List<String>, val rejected: List<Rejection>)

    /** [tailnet]: the expected tailnet's MagicDNS suffix (`tail1234.ts.net`), when known. */
    fun filter(names: List<String>, addresses: List<String>, tailnet: String? = null): Result {
        val suffix = tailnet?.let(::normalizedName)
        val rejected = ArrayList<Rejection>()
        val keptNames = collect(names, MAX_NAMES, rejected) { name(it, suffix) }
        val keptAddresses = collect(addresses, MAX_ADDRESSES, rejected, ::address)
        return Result(keptNames, keptAddresses, rejected)
    }

    private sealed interface Check {
        data class Ok(val normalized: String) : Check
        data class No(val reason: Reason) : Check
    }

    private fun collect(values: List<String>, cap: Int, rejected: MutableList<Rejection>, check: (String) -> Check): List<String> {
        val kept = ArrayList<String>()
        for (raw in values) {
            val value = RemoteEndpointValidation.trimWhitespace(raw)
            if (value.isEmpty()) continue
            when (val result = check(value)) {
                is Check.No -> rejected += Rejection(value, result.reason)
                is Check.Ok -> when {
                    result.normalized in kept -> Unit
                    kept.size >= cap -> rejected += Rejection(value, Reason.OverCap)
                    else -> kept += result.normalized
                }
            }
        }
        return kept
    }

    // Names

    private fun normalizedName(text: String): String =
        RemoteEndpointValidation.trimWhitespace(text).lowercase(java.util.Locale.ROOT).removeSuffix(".")

    private fun name(value: String, tailnet: String?): Check {
        val normalized = normalizedName(value)
        if (normalized.length > 253) return Check.No(Reason.Invalid)
        val labels = normalized.split('.')
        for (label in labels) {
            if (label.length !in 1..63 || label.first() == '-' || label.last() == '-') return Check.No(Reason.Invalid)
            if (!label.all { it in 'a'..'z' || it in '0'..'9' || it == '-' }) return Check.No(Reason.Invalid)
        }
        // <host>.<tailnet>.ts.net: at least one label in front of the tailnet's own name.
        if (labels.size < 4 || !normalized.endsWith(".ts.net")) return Check.No(Reason.NotTailnet)
        if (tailnet != null && !normalized.endsWith(".$tailnet")) return Check.No(Reason.OtherTailnet)
        return Check.Ok(normalized)
    }

    // Addresses

    private fun address(value: String): Check {
        val bytes = IpLiteral.parse(value) ?: return Check.No(Reason.Invalid)
        if (bytes.size == 16) {
            if (!IpLiteral.isTailscaleRange(bytes)) return Check.No(Reason.NotTailnet)
            return Check.Ok(formatIPv6(bytes))
        }
        val octets = bytes.map { it.toInt() and 0xFF }
        if (octets == listOf(100, 100, 100, 100)) return Check.No(Reason.Reserved)
        if (!IpLiteral.isTailscaleRange(bytes)) return Check.No(Reason.NotTailnet)
        return Check.Ok(octets.joinToString("."))
    }

    /**
     * RFC 5952: lowercase hex, no leading zeros, the longest run of two or more zero groups (the
     * first on a tie) written `::`.
     */
    fun formatIPv6(bytes: ByteArray): String {
        require(bytes.size == 16)
        val groups = IntArray(8) { ((bytes[it * 2].toInt() and 0xFF) shl 8) or (bytes[it * 2 + 1].toInt() and 0xFF) }
        var bestStart = -1
        var bestLength = 0
        var runStart = -1
        for (i in 0..8) {
            if (i < 8 && groups[i] == 0) {
                if (runStart < 0) runStart = i
            } else if (runStart >= 0) {
                if (i - runStart > bestLength) {
                    bestStart = runStart
                    bestLength = i - runStart
                }
                runStart = -1
            }
        }
        fun hex(range: IntRange) = range.joinToString(":") { groups[it].toString(16) }
        if (bestLength < 2) return hex(0 until 8)
        return hex(0 until bestStart) + "::" + hex(bestStart + bestLength until 8)
    }
}
