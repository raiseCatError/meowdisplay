package com.raisecaterror.meowdisplay.core.remote

/**
 * What a Mac's `_opendisplay-mac-pair._tcp` TXT record says about it (Shared/MacSessionDiscovery.swift):
 * its install ID, and for a Mac with several logged-in users (Fast User Switching, opt-in) the
 * host group, the Mac's own name, the session label and whether that session is switched out.
 * Everything here is unauthenticated: it arranges and labels the list, never trust, pairing or input.
 */
data class MacAdvertisement(
    val installID: String? = null,
    val hostGroup: String? = null,
    val hostName: String? = null,
    val sessionLabel: String? = null,
    /** Logged in but not on the console: it can't capture or take input, so it can't share now. */
    val switchedOut: Boolean = false,
) {
    /** "Family MacBook · Jai" for one of several sessions; null when the Mac didn't label it. */
    val sessionTitle: String? get() = sessionLabel?.let { label -> hostName?.let { "$it · $label" } ?: label }

    companion object {
        const val MAX_LABEL = 32
        const val MAX_HOST_NAME = 63
        const val MAX_ID = 64

        fun parse(txt: Map<String, String?>): MacAdvertisement {
            fun field(key: String, max: Int) = txt[key]?.trim()?.takeIf { it.isNotEmpty() }?.take(max)
            val group = field("hg", 32)?.takeIf { g -> g.all { it.isLetterOrDigit() } }
            // Labels only count as a group of sessions (sl is meaningless without hg).
            return MacAdvertisement(
                installID = field("id", MAX_ID),
                hostGroup = group,
                hostName = if (group != null) field("hn", MAX_HOST_NAME) else null,
                sessionLabel = if (group != null) field("sl", MAX_LABEL) else null,
                switchedOut = txt["ss"]?.trim() == "i",
            )
        }
    }
}
