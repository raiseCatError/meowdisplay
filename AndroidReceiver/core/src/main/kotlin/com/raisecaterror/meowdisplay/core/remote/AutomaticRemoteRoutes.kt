package com.raisecaterror.meowdisplay.core.remote

/**
 * Which kinds of reported tailnet address automatic Remote Access may dial on a path
 * (Shared/AutomaticRemoteRoutes.swift). A family is turned on for a path only once it has been
 * verified on real devices; a typed address is never limited by this.
 */
data class TailnetFamilies(val ipv4: Boolean, val ipv6: Boolean, val names: Boolean) {
    companion object {
        val NONE = TailnetFamilies(ipv4 = false, ipv6 = false, names = false)

        /**
         * Android knocking its Mac (9003) and the Mac dialing back (9001) over Tailscale IPv4: verified
         * live over LTE + Tailscale (handoff-2.0/COMPLETION-MATRIX.md, "Android Remote devices").
         * IPv6 and MagicDNS names have not been verified on this path.
         */
        val ANDROID = TailnetFamilies(ipv4 = true, ipv6 = false, names = false)
    }
}

object AutomaticRemoteRoutes {
    /**
     * The address to use from a report, or null: a MagicDNS name first (it survives address
     * changes), then IPv4, then IPv6, each only where [families] allows it.
     */
    fun host(names: List<String>, ips: List<String>, families: TailnetFamilies): String? {
        if (families.names) names.firstOrNull()?.let { return it }
        if (families.ipv4) ips.firstOrNull { ':' !in it }?.let { return it }
        if (families.ipv6) ips.firstOrNull { ':' in it }?.let { return it }
        return null
    }
}
