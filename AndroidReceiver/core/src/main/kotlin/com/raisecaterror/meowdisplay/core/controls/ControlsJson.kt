package com.raisecaterror.meowdisplay.core.controls

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

// JSON in the shapes Swift's JSONEncoder/JSONDecoder use for the same
// Codable values, so persisted preferences and shared layouts keep one
// format across the Apple and Android receivers. Decoders mirror Swift:
// a required key that is missing or mistyped fails the value (null), and
// hand-written Swift defaults are applied by the caller.

internal val controlsJson = Json { isLenient = false; ignoreUnknownKeys = true }

internal fun parseJson(text: String): JsonElement? = try {
    controlsJson.parseToJsonElement(text)
} catch (_: Exception) {
    null
} catch (_: StackOverflowError) {
    null
}

internal fun JsonElement?.obj(): JsonObject? = this as? JsonObject
internal fun JsonElement?.arr(): JsonArray? = this as? JsonArray

internal fun JsonElement?.str(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content
internal fun JsonElement?.bool(): Boolean? = (this as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull
internal fun JsonElement?.dbl(): Double? = (this as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull }?.doubleOrNull

/** JSONDecoder's Int: an integral JSON number in range. */
internal fun JsonElement?.int(): Int? {
    val p = (this as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull } ?: return null
    p.longOrNull?.let { return it.takeIf { v -> v in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt() }
    val d = p.doubleOrNull ?: return null
    return if (d.isFinite() && d == Math.rint(d) && d >= Int.MIN_VALUE && d <= Int.MAX_VALUE) d.toInt() else null
}

/** A list where every element must decode (synthesized `[T]` decoding). */
internal fun <T> JsonElement?.listOf(decode: (JsonElement) -> T?): List<T>? {
    val array = arr() ?: return null
    val result = ArrayList<T>(array.size)
    for (element in array) result += decode(element) ?: return null
    return result
}

/** `LossyDecodableArray`: elements that fail to decode are dropped. */
internal fun <T> JsonElement?.lossyListOf(decode: (JsonElement) -> T?): List<T>? = arr()?.mapNotNull(decode)

internal fun jsonArrayOf(items: Iterable<JsonElement>): JsonArray = buildJsonArray { items.forEach { add(it) } }

internal fun JsonObjectBuilder.putIfNotNull(key: String, value: JsonElement?) {
    if (value != null) put(key, value)
}

/** Swift's synthesized encoding of an enum case with one unlabeled payload: `{"case":{"_0":payload}}`. */
internal fun swiftCase(name: String, payload: JsonElement): JsonObject =
    buildJsonObject { put(name, buildJsonObject { put("_0", payload) }) }

/** A payload-free enum case: `{"case":{}}`. */
internal fun swiftCase(name: String): JsonObject = buildJsonObject { put(name, JsonObject(emptyMap())) }

/** The single case key and its payload object of a synthesized enum encoding. */
internal fun JsonElement?.swiftCaseOf(): Pair<String, JsonObject>? {
    val o = obj() ?: return null
    if (o.size != 1) return null
    val (key, value) = o.entries.first()
    return key to (value.obj() ?: return null)
}

internal fun jsonOf(value: String) = JsonPrimitive(value)
internal fun jsonOf(value: Boolean) = JsonPrimitive(value)
internal fun jsonOf(value: Int) = JsonPrimitive(value)
internal fun jsonOf(value: Double) = JsonPrimitive(value)
