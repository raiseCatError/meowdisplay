package com.raisecaterror.meowdisplay.core.controls

// Temporary: the real definitions arrive with the PointerGestureEngine.swift port; delete this file then.

enum class PointerInputMode(val raw: String) {
    Direct("direct"), Trackpad("trackpad");

    companion object {
        fun of(raw: String?): PointerInputMode? = entries.firstOrNull { it.raw == raw }
    }
}

class PointerGestureConfig {
    companion object {
        val trackpadSensitivityRange: ClosedFloatingPointRange<Double> = 0.5..2.0
        const val defaultTrackpadSensitivity: Double = 1.0
    }
}
