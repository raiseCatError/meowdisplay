package com.raisecaterror.meowdisplay.core.controls

// Temporary: the real definitions arrive with the PadControlLayout.swift and
// CustomControlLayout.swift port; delete this file then. Shapes match the Swift.

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

enum class PadControlLayoutMode(val raw: String) {
    Strip("strip"), Overlay("overlay"), Custom("custom");

    companion object {
        fun of(raw: String?): PadControlLayoutMode? = entries.firstOrNull { it.raw == raw }
    }
}

enum class ControlEdge(val raw: String) {
    Leading("leading"), Trailing("trailing"), Top("top"), Bottom("bottom");

    companion object {
        fun of(raw: String?): ControlEdge? = entries.firstOrNull { it.raw == raw }
    }
}

object PadControlScale {
    val range: ClosedFloatingPointRange<Double> = 0.85..1.4
    const val defaultValue = 1.0

    fun clamped(value: Double): Double = if (!value.isFinite()) defaultValue else value.coerceIn(range.start, range.endInclusive)
}

enum class PadStandardControl(val raw: String) {
    MenuBar("menuBar"), Dock("dock"), ShowDesktop("showDesktop"), ControlCenter("controlCenter"),
    Escape("escape"), Tab("tab"), Keyboard("keyboard"), MoveView("moveView");

    companion object {
        fun of(raw: String?): PadStandardControl? = entries.firstOrNull { it.raw == raw }
    }
}

data class PadStandardControlVisibility(var hidden: Set<PadStandardControl> = emptySet()) {
    fun isVisible(control: PadStandardControl) = control !in hidden

    fun setVisible(visible: Boolean, control: PadStandardControl) {
        hidden = if (visible) hidden - control else hidden + control
    }

    fun toJson(): JsonElement = jsonArrayOf(PadStandardControl.entries.filter { it in hidden }.map { jsonOf(it.raw) })

    companion object {
        fun fromJson(e: JsonElement?): PadStandardControlVisibility? =
            e.listOf { it.str() }?.let { raw -> PadStandardControlVisibility(raw.mapNotNull(PadStandardControl::of).toSet()) }
    }
}

data class CustomControlLayout(val json: JsonObject) {
    val id: String get() = json["id"].str() ?: ""

    fun toJson(): JsonElement = json

    companion object {
        const val maximumCount = 5

        fun fromJson(e: JsonElement?): CustomControlLayout? = e.obj()?.takeIf { it["id"].str() != null }?.let(::CustomControlLayout)
    }
}
