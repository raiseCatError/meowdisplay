package com.raisecaterror.meowdisplay.core.remote

// Remote Access endpoints (Shared/RemoteEndpointValidation.swift, Shared/RemotePairing.swift
// `RemotePairingEndpoint`). An endpoint is a routing hint typed by the user, never an identity:
// the pinned mutual-TLS handshake alone decides whether the thing at an address is the Mac.
// Validation is syntax only (no DNS, no "must look like Tailscale") and mirrors the Swift code,
// quirks included, so both apps accept and reject the same text (fixtures/remote/endpoint-vectors.json).

object RemotePorts {
    /** The Mac's "Pair over Remote" listener (WireCrypto.remotePairingPort). */
    const val PAIRING = 9004

    /** The Mac's authenticated connect-request ("knock") listener (WireCrypto.remoteRequestPort). */
    const val CONNECT_REQUEST = 9003
}

enum class EndpointError { EmptyHost, InvalidHost, InvalidPort }

/** [host] is a bare IPv6 literal, an IPv4 literal or a hostname; never bracketed. */
data class RemoteEndpoint(val host: String, val port: Int) {
    /** For the screen only: `host:port`, with brackets around an IPv6 literal. */
    val display: String get() = (if (':' in host) "[$host]" else host) + ":" + port

    /** The address as the user would type it: the port is left off when it is [defaultPort]. */
    fun typed(defaultPort: Int): String = if (port == defaultPort) host else display
}

sealed interface EndpointParse {
    data class Valid(val endpoint: RemoteEndpoint) : EndpointParse
    data class Invalid(val error: EndpointError) : EndpointParse
}

object RemoteEndpointValidation {
    private const val MAX_HOST = 253
    private const val MAX_LABEL = 63

    /**
     * Validates a host/port pair typed into the editor. Trims incidental whitespace only and never
     * rewrites the address: the host comes back as typed (brackets included).
     */
    fun validate(rawHost: String, rawPort: String): EndpointParse {
        val host = trimWhitespace(rawHost)
        if (host.isEmpty()) return EndpointParse.Invalid(EndpointError.EmptyHost)
        if (!isSyntacticallyValidHost(host)) return EndpointParse.Invalid(EndpointError.InvalidHost)
        val port = parsePort(trimWhitespace(rawPort)) ?: return EndpointParse.Invalid(EndpointError.InvalidPort)
        return EndpointParse.Valid(RemoteEndpoint(host, port))
    }

    /** IPv4, IPv6 (bracketed or bare) and DNS-style hostnames, MagicDNS names included. */
    fun isSyntacticallyValidHost(host: String): Boolean {
        if (host.isEmpty() || host.length > MAX_HOST) return false
        var candidate = host
        if (candidate.startsWith("[") && candidate.endsWith("]")) candidate = candidate.substring(1, candidate.length - 1)

        // An IPv4 or IPv6 literal. Text that looks like one but isn't never falls back to a hostname.
        if (':' in candidate || looksLikeIPv4(candidate)) return IpLiteral.parse(candidate) != null

        // Hostname: dot-separated ASCII letters/digits/hyphens, no empty label, no leading or trailing hyphen.
        val labels = candidate.split('.')
        for (label in labels) {
            if (label.isEmpty() || label.length > MAX_LABEL) return false
            if (label.first() == '-' || label.last() == '-') return false
            if (!label.all { it.isAsciiLetterOrDigit() || it == '-' }) return false
        }
        // The last label of a hostname is never all digits (RFC 3696 §2), so "999.1.1.1" or "1.2.3"
        // is a mistyped address, not a name to look up.
        if (labels.last().all { it in '0'..'9' }) return false
        return true
    }

    /** Swift pre-check: four dot-separated parts that each parse as a UInt8 (an optional `+`, digits). */
    private fun looksLikeIPv4(text: String): Boolean {
        val parts = text.split('.')
        return parts.size == 4 && parts.all { part ->
            val digits = part.removePrefix("+")
            digits.isNotEmpty() && digits.all { it in '0'..'9' } && digits.trimStart('0').let { it.length <= 3 && (it.isEmpty() || it.toInt() <= 255) }
        }
    }

    /** Swift `UInt16(text)` with `port > 0`: an optional `+`, ASCII digits, 1...65535. */
    private fun parsePort(text: String): Int? {
        val digits = text.removePrefix("+")
        if (digits.isEmpty() || !digits.all { it in '0'..'9' }) return null
        val trimmed = digits.trimStart('0')
        if (trimmed.length > 5) return null
        val value = if (trimmed.isEmpty()) 0 else trimmed.toInt()
        return value.takeIf { it in 1..65535 }
    }

    private fun Char.isAsciiLetterOrDigit() = this in 'a'..'z' || this in 'A'..'Z' || this in '0'..'9'

    /** Swift `CharacterSet.whitespacesAndNewlines`: Zs, tab, line feeds, NEL and the line/paragraph separators. */
    internal fun trimWhitespace(text: String): String {
        fun blank(c: Char) = c == '\t' || c in '\n'..'\r' || c == '\u0085' || c == ' ' || c == ' ' ||
            Character.getType(c) == Character.SPACE_SEPARATOR.toInt()
        var start = 0
        var end = text.length
        while (start < end && blank(text[start])) start++
        while (end > start && blank(text[end - 1])) end--
        return text.substring(start, end)
    }
}

object RemoteEndpoints {
    /**
     * `RemotePairingEndpoint.make`: validates, defaults an empty port to [defaultPort] and unwraps
     * a bracketed IPv6 literal.
     */
    fun make(host: String, port: String = "", defaultPort: Int = RemotePorts.PAIRING): EndpointParse {
        val portText = RemoteEndpointValidation.trimWhitespace(port)
        val effective = if (portText.isEmpty()) defaultPort.toString() else portText
        return when (val result = RemoteEndpointValidation.validate(host, effective)) {
            is EndpointParse.Invalid -> result
            is EndpointParse.Valid -> {
                var bare = result.endpoint.host
                if (bare.startsWith("[") && bare.endsWith("]")) bare = bare.substring(1, bare.length - 1)
                EndpointParse.Valid(RemoteEndpoint(bare, result.endpoint.port))
            }
        }
    }

    /**
     * The one Address field: `host`, `host:port`, `a.b.c.d:port`, a bare IPv6 literal, `[v6]` or
     * `[v6]:port`. The text is split and then judged by the same rules as [make]; nothing is
     * rewritten and a zone id (`%en0`) is rejected like any other bad character.
     */
    fun parseAddress(text: String, defaultPort: Int): EndpointParse {
        val typed = RemoteEndpointValidation.trimWhitespace(text)
        if (typed.isEmpty()) return EndpointParse.Invalid(EndpointError.EmptyHost)
        if (typed.startsWith("[")) {
            val close = typed.indexOf(']')
            if (close < 0) return EndpointParse.Invalid(EndpointError.InvalidHost)
            val host = typed.substring(0, close + 1)
            val rest = typed.substring(close + 1)
            return when {
                rest.isEmpty() -> make(host, "", defaultPort)
                rest[0] != ':' -> EndpointParse.Invalid(EndpointError.InvalidHost)
                else -> withExplicitPort(host, rest.substring(1), defaultPort)
            }
        }
        return when (typed.count { it == ':' }) {
            0 -> make(typed, "", defaultPort)
            1 -> withExplicitPort(typed.substringBefore(':'), typed.substringAfter(':'), defaultPort)
            // Two or more colons without brackets can only be a bare IPv6 literal.
            else -> make(typed, "", defaultPort)
        }
    }

    /** A colon was typed, so an empty port is a mistake, not a request for the default. */
    private fun withExplicitPort(host: String, port: String, defaultPort: Int): EndpointParse {
        // `http://mac`: a URL, not an address with a port.
        if (port.startsWith("//")) return EndpointParse.Invalid(EndpointError.InvalidHost)
        if (RemoteEndpointValidation.trimWhitespace(port).isEmpty()) {
            // Report a bad host first, as validate() would.
            return when (val hostOnly = make(host, "", defaultPort)) {
                is EndpointParse.Invalid -> hostOnly
                is EndpointParse.Valid -> EndpointParse.Invalid(EndpointError.InvalidPort)
            }
        }
        return make(host, port, defaultPort)
    }
}

/** Strict IPv4/IPv6 literals, accepting exactly what `inet_pton` does (no zone ids, no leading zeros in IPv4). */
object IpLiteral {
    /** 4 bytes (IPv4) or 16 bytes (IPv6), or null when [text] is not a literal. */
    fun parse(text: String): ByteArray? = if (':' in text) parseIPv6(text) else parseIPv4(text)

    private fun parseIPv4(text: String): ByteArray? {
        val parts = text.split('.')
        if (parts.size != 4) return null
        val out = ByteArray(4)
        for ((i, part) in parts.withIndex()) {
            if (part.isEmpty() || part.length > 3 || !part.all { it in '0'..'9' }) return null
            if (part.length > 1 && part[0] == '0') return null
            val value = part.toInt()
            if (value > 255) return null
            out[i] = value.toByte()
        }
        return out
    }

    private fun parseIPv6(text: String): ByteArray? {
        var body = text
        var embedded: ByteArray? = null
        if ('.' in text) {
            val lastColon = text.lastIndexOf(':')
            embedded = parseIPv4(text.substring(lastColon + 1)) ?: return null
            body = text.substring(0, lastColon + 1) + "0:0"
        }
        val groups = ArrayList<Int>(8)
        val compress = body.indexOf("::")
        if (compress != body.lastIndexOf("::")) return null
        fun hexGroups(part: String): List<Int>? {
            if (part.isEmpty()) return emptyList()
            return part.split(':').map { group ->
                if (group.isEmpty() || group.length > 4 || !group.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
                group.toInt(16)
            }
        }
        if (compress >= 0) {
            val head = hexGroups(body.substring(0, compress)) ?: return null
            val tail = hexGroups(body.substring(compress + 2)) ?: return null
            // `::` must stand for at least one group.
            if (head.size + tail.size > 7) return null
            groups += head
            repeat(8 - head.size - tail.size) { groups += 0 }
            groups += tail
        } else {
            val all = hexGroups(body) ?: return null
            if (all.size != 8) return null
            groups += all
        }
        val out = ByteArray(16)
        for (i in 0 until 8) {
            out[i * 2] = (groups[i] shr 8).toByte()
            out[i * 2 + 1] = groups[i].toByte()
        }
        embedded?.copyInto(out, 12)
        return out
    }

    private val TAILSCALE_V6 = byteArrayOf(0xfd.toByte(), 0x7a, 0x11, 0x5c, 0xa1.toByte(), 0xe0.toByte())

    /** Tailscale's address space: 100.64.0.0/10 or fd7a:115c:a1e0::/48. */
    fun isTailscaleRange(address: ByteArray): Boolean = when (address.size) {
        4 -> (address[0].toInt() and 0xFF) == 100 && (address[1].toInt() and 0xC0) == 0x40
        16 -> TAILSCALE_V6.indices.all { address[it] == TAILSCALE_V6[it] }
        else -> false
    }

    /** What a log line may say about an address: its kind, never the address itself. */
    fun logKind(host: String): String {
        val bare = if (host.startsWith("[") && host.endsWith("]")) host.substring(1, host.length - 1) else host
        val bytes = parse(bare) ?: return "dns"
        return when {
            isTailscaleRange(bytes) -> "tailscale-range"
            bytes.size == 4 -> "ipv4"
            else -> "ipv6"
        }
    }
}
