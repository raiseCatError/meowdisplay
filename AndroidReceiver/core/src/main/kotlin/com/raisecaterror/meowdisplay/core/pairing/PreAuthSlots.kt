package com.raisecaterror.meowdisplay.core.pairing

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Bounds connections that haven't authenticated yet (Shared/PreAuthSlots.swift). A pairing
 * listener anyone on the network can reach gives each connection one of a few slots until
 * the peer's commitment arrives, which must happen within [DEADLINE_MS]; when every slot is
 * taken, newcomers are closed at once.
 */
class PreAuthSlots(val limit: Int) {
    companion object {
        const val DEADLINE_MS = 10_000L
        const val PAIRING_LIMIT = 4
    }

    private val used = AtomicInteger(0)

    val inUse: Int get() = used.get()

    /** A slot to release exactly once, or null when every slot is taken. */
    fun tryAcquire(): Slot? {
        while (true) {
            val current = used.get()
            if (current >= limit) return null
            if (used.compareAndSet(current, current + 1)) return Slot()
        }
    }

    inner class Slot internal constructor() {
        private val released = AtomicBoolean(false)
        fun release() {
            if (released.compareAndSet(false, true)) used.decrementAndGet()
        }
    }
}
