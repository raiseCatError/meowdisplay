package com.raisecaterror.meowdisplay.core.workspace

import java.text.Normalizer
import java.util.Locale

// Stage Peek, search and Launchpad (port of Shared/WorkspaceBrowse.swift; same
// vectors: fixtures/workspace/search-vectors.json). Pure; no Android types.

data class CatalogDisplay(val id: Long, val name: String, val width: Int, val height: Int, val isMain: Boolean, val isVirtual: Boolean)

/** One launchable Mac app (installed or running), from `appCatalog`. */
data class MacApp(val bundleID: String, val name: String, val running: Boolean, val windowCount: Int, val lastUsed: Long? = null) {
    val isFinder get() = bundleID == FINDER
    companion object { const val FINDER = "com.apple.finder" }
}

object WorkspaceSearch {
    private val marks = Regex("\\p{Mn}+")

    fun normalize(s: String): String =
        marks.replace(Normalizer.normalize(s, Normalizer.Form.NFD), "").lowercase(Locale.ROOT).trim().split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")

    /** 0 = no match. Exact > prefix > word prefix > initials > substring > in-order letters (3+). */
    fun score(rawQuery: String, rawText: String): Int {
        val q = normalize(rawQuery); val t = normalize(rawText)
        if (q.isEmpty() || t.isEmpty()) return 0
        if (t == q) return 1000
        if (t.startsWith(q)) return 900 - minOf(t.length - q.length, 99)
        val words = t.split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }
        if (words.any { it.startsWith(q) }) return 800 - minOf(t.length - q.length, 99)
        val initials = words.mapNotNull { it.firstOrNull() }.joinToString("")
        if (q.length >= 2 && initials.startsWith(q)) return 700
        val at = t.indexOf(q)
        if (at >= 0) return 600 - minOf(at, 99)
        if (q.length < 3) return 0
        var ti = 0; var gaps = 0; var matched = 0
        for (c in q) {
            if (c == ' ') continue
            val found = t.indexOf(c, ti)
            if (found < 0) return 0
            gaps += found - ti
            ti = found + 1
            matched++
        }
        if (matched < 2) return 0
        return maxOf(1, 300 - gaps * 8)
    }

    data class Results(val apps: List<MacApp>, val windows: List<CatalogWindow>)

    fun search(query: String, apps: List<MacApp>, windows: List<CatalogWindow>): Results {
        val q = normalize(query)
        if (q.isEmpty()) return Results(apps, windows)
        val rankedApps = apps.mapNotNull { a ->
            val s = maxOf(score(q, a.name), score(q, a.bundleID) * 6 / 10)
            if (s > 0) a to s + (if (a.running) 15 else 0) else null
        }.sortedWith(compareByDescending<Pair<MacApp, Int>> { it.second }.thenBy(String.CASE_INSENSITIVE_ORDER) { it.first.name }).map { it.first }
        val rankedWindows = windows.mapNotNull { w ->
            val s = maxOf(score(q, w.title), score(q, w.app) * 9 / 10)
            if (s > 0) w to s else null
        }.sortedWith(compareByDescending<Pair<CatalogWindow, Int>> { it.second }.thenBy(String.CASE_INSENSITIVE_ORDER) { it.first.title }).map { it.first }
        return Results(rankedApps, rankedWindows)
    }

    /** Finder, running apps (by name), then the rest (by name). */
    fun carouselOrder(apps: List<MacApp>): List<MacApp> =
        apps.sortedWith(compareBy<MacApp>({ !it.isFinder }, { !it.running }).thenBy(String.CASE_INSENSITIVE_ORDER) { it.name })

    fun recents(apps: List<MacApp>, limit: Int = 8): List<MacApp> =
        apps.filter { it.lastUsed != null && !it.isFinder }.sortedByDescending { it.lastUsed }.take(limit)
}

/** Which window stills to ask for next (visible cards first; no repeats within seconds; failures back off). */
class ThumbnailRequestPlanner {
    companion object {
        const val REFRESH_AFTER_MS = 8_000L
        const val RETRY_AFTER_MS = 2_500L
        const val FAILURE_BACKOFF_MS = 12_000L
        const val BATCH = 24
    }
    private val receivedAt = HashMap<Long, Long>()
    private val requestedAt = HashMap<Long, Long>()
    private val failedAt = HashMap<Long, Long>()

    fun plan(priority: List<Long>, all: List<Long>, now: Long): List<Long> {
        val seen = HashSet<Long>(); val out = ArrayList<Long>()
        for (id in priority + all) {
            if (!seen.add(id)) continue
            val asked = requestedAt[id]; if (asked != null && now - asked < RETRY_AFTER_MS) continue
            val failed = failedAt[id]; if (failed != null && now - failed < FAILURE_BACKOFF_MS) continue
            val got = receivedAt[id]; if (got != null && now - got < REFRESH_AFTER_MS) continue
            out += id
            if (out.size == BATCH) break
        }
        out.forEach { requestedAt[it] = now }
        return out
    }

    fun received(id: Long, now: Long) { receivedAt[id] = now; failedAt.remove(id); requestedAt.remove(id) }
    fun failed(id: Long, now: Long) { failedAt[id] = now; requestedAt.remove(id) }
    fun forget(id: Long) { receivedAt.remove(id); requestedAt.remove(id); failedAt.remove(id) }
    fun reset() { receivedAt.clear(); requestedAt.clear(); failedAt.clear() }
}
