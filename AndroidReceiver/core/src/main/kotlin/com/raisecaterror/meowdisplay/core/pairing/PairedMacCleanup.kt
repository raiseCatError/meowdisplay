package com.raisecaterror.meowdisplay.core.pairing

/**
 * Which paired Macs are old copies. Reinstalling MeowDisplay on a Mac, a new test build or a
 * renamed Mac pairs again under a new id, so the list fills with entries of the same name that
 * can never connect again. Per name (ignoring case and surrounding spaces), anything connected
 * or nearby stays; otherwise the newest pairing stays. A pin without a date was saved before
 * this app recorded dates, so it is older than any dated one; when none of a name's pins has a
 * date, which is newest isn't known and none is offered. Nothing is removed without the owner
 * confirming the exact list. Same rule as Shared/KnownDeviceCleanup.swift.
 */
object PairedMacCleanup {
    data class Entry(val id: String, val name: String, val pairedAtMillis: Long?, val inUse: Boolean)

    fun superseded(entries: List<Entry>): List<Entry> {
        val out = mutableListOf<Entry>()
        for (group in entries.groupBy { it.name.trim().lowercase() }.values) {
            if (group.size < 2) continue
            val keep: Set<String> = if (group.any { it.inUse }) {
                group.filter { it.inUse }.map { it.id }.toSet()
            } else {
                val newest = group.filter { it.pairedAtMillis != null }
                    .maxWithOrNull(compareBy<Entry>({ it.pairedAtMillis }, { it.id })) ?: continue   // no dates: never guess
                setOf(newest.id)
            }
            out += group.filter { it.id !in keep && !it.inUse }
        }
        return out.sortedWith(compareBy({ it.name }, { it.pairedAtMillis ?: Long.MIN_VALUE }))
    }
}
