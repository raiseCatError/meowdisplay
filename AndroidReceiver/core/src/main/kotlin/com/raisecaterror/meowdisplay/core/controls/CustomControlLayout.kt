package com.raisecaterror.meowdisplay.core.controls

// Ported from Shared/CustomControlLayout.swift.
//
// iPad Custom control layouts: where controls APPEAR, never what they DO.
// Every placement points at an existing control: a Main tray item
// (`ControlTrayItem`, whose modifiers drive the one `ControlInteractionState`
// chord machine), a Function Tray item by its stable `ShortcutItem` id, or
// Move View, so shortcuts, chords and wire messages stay exactly where they
// already live.
//
// Value semantics: the layout types are immutable data classes; where the
// Swift mutates a struct in place, use `copy(...)` (or `setArrangement`, which
// returns the updated layout).
//
// `LossyDecodableArray<Element>` is `JsonElement?.lossyListOf(decode)` in
// ControlsJson.kt: an element that fails to decode is dropped on its own, and
// only a non-array value fails the whole container.

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

enum class ControlCorner(val raw: String, val title: String) {
    TopLeading("topLeading", "Top Left"),
    TopTrailing("topTrailing", "Top Right"),
    BottomLeading("bottomLeading", "Bottom Left"),
    BottomTrailing("bottomTrailing", "Bottom Right");

    val id: String get() = raw

    val isLeading: Boolean get() = this == TopLeading || this == BottomLeading
    val isTop: Boolean get() = this == TopLeading || this == TopTrailing

    /** The corner as a normalized point (0 or 1 on each axis). */
    val unitPoint: CGPoint get() = CGPoint(x = if (isLeading) 0.0 else 1.0, y = if (isTop) 0.0 else 1.0)

    companion object {
        fun of(raw: String?): ControlCorner? = entries.firstOrNull { it.raw == raw }
    }
}

/** What a Custom placement shows. Resolves against existing models only. */
sealed interface CustomControlKind {
    /** A Main tray item: a modifier, Escape, Tab, Toggle Dock, Keyboard or Settings. */
    data class Tray(val item: ControlTrayItem) : CustomControlKind

    /** A Function Tray item, by its stable `ShortcutItem.id`. */
    data class Function(val id: String) : CustomControlKind

    /** The receiver-local Move View mode toggle. */
    data object MoveView : CustomControlKind

    /**
     * A user-made one-tap keyboard shortcut, owned by this placement. Uses the
     * same `ShortcutItem`/`KeyboardShortcut` model as every palette.
     */
    data class Shortcut(val item: ShortcutItem) : CustomControlKind

    val modifier: ControlModifier? get() = (this as? Tray)?.item?.modifier

    /** Fires once on tap (a Function action or a one-tap shortcut), rather than joining the chord gesture. */
    val isOneTapAction: Boolean
        get() = when (this) {
            is Function, is Shortcut -> true
            is Tray, MoveView -> false
        }

    /** A readable id for a template placement. */
    val stableID: String
        get() = when (this) {
            is Tray -> item.raw
            is Function -> id
            MoveView -> "move-view"
            is Shortcut -> item.id
        }

    /** Swift's hand-written `encode(to:)`: `{"kind":"tray","value":"command"}` and so on. */
    fun toJson(): JsonElement = buildJsonObject {
        when (val k = this@CustomControlKind) {
            is Tray -> {
                put("kind", jsonOf("tray"))
                put("value", jsonOf(k.item.raw))
            }
            is Function -> {
                put("kind", jsonOf("function"))
                put("value", jsonOf(k.id))
            }
            MoveView -> put("kind", jsonOf("moveView"))
            is Shortcut -> {
                put("kind", jsonOf("shortcut"))
                put("shortcut", k.item.toJson())
            }
        }
    }

    companion object {
        /** Swift's hand-written `init(from:)`: an unknown kind, tray item or invalid shortcut fails the value. */
        fun fromJson(e: JsonElement?): CustomControlKind? {
            val o = e.obj() ?: return null
            return when (o["kind"].str() ?: return null) {
                "tray" -> Tray(ControlTrayItem.of(o["value"].str() ?: return null) ?: return null)
                "function" -> Function(o["value"].str() ?: return null)
                "moveView" -> MoveView
                "shortcut" -> {
                    val item = ShortcutItem.fromJson(o["shortcut"]) ?: return null
                    val action = item.action as? ControlAction.KeyboardShortcutAction ?: return null
                    if (!action.shortcut.isValid) return null
                    Shortcut(item)
                }
                else -> null
            }
        }
    }
}

enum class PaletteShape(val raw: String, val title: String) {
    Arc("arc", "Arc"),
    Ring("ring", "Ring"),
    Row("row", "Row"),
    Column("column", "Column"),

    /** A ring of wedge-shaped segments around the modifier; see [WheelPaletteGeometry]. */
    Wheel("wheel", "Wheel");

    val id: String get() = raw

    companion object {
        fun of(raw: String?): PaletteShape? = entries.firstOrNull { it.raw == raw }
    }
}

/** How a modifier's chord palette blooms around it. */
data class PalettePresentation(
    val shape: PaletteShape = PaletteShape.Arc,
    /** Multiplier on the automatic bloom radius. */
    val spacing: Double = 1.0,
    /** Bloom direction in degrees (0 = right, 90 = down); null blooms toward the middle of the screen. */
    val directionDegrees: Double? = null,
) {
    fun toJson(): JsonElement = buildJsonObject {
        put("shape", jsonOf(shape.raw))
        put("spacing", jsonOf(spacing))
        putIfNotNull("directionDegrees", directionDegrees?.let(::jsonOf))
    }

    companion object {
        val spacingRange: ClosedFloatingPointRange<Double> = 0.8..2.0

        fun fromJson(e: JsonElement?): PalettePresentation? {
            val o = e.obj() ?: return null
            val direction = o["directionDegrees"]
            return PalettePresentation(
                shape = PaletteShape.of(o["shape"].str()) ?: return null,
                spacing = o["spacing"].dbl() ?: return null,
                directionDegrees = if (direction == null || direction is JsonNull) null else direction.dbl() ?: return null,
            )
        }
    }
}

/**
 * One placed control. The public constructor is Swift's `init`, which clamps
 * position and size and gives a modifier its default palette; decoding and
 * [copy] store values as given, like the Swift synthesized `Decodable` and a
 * plain property assignment.
 */
class CustomControlPlacement private constructor(
    val id: String,
    val kind: CustomControlKind,
    /** Center, normalized to the safe layout area (0...1 on each axis) so a layout reads the same on every iPad size. */
    val x: Double,
    val y: Double,
    /** Per-control size multiplier on top of the global Control Size. */
    val size: Double,
    /** Modifiers only. */
    val palette: PalettePresentation?,
    @Suppress("UNUSED_PARAMETER") stored: Boolean,
) {
    constructor(
        id: String = newUUIDString(),
        kind: CustomControlKind,
        x: Double,
        y: Double,
        size: Double = 1.0,
        palette: PalettePresentation? = null,
    ) : this(
        id, kind, unit(x), unit(y), clampedSize(size),
        palette ?: if (kind.modifier != null) PalettePresentation() else null,
        true,
    )

    /** Assigning properties one by one, as the Swift does; nothing is re-clamped. */
    fun copy(
        id: String = this.id,
        kind: CustomControlKind = this.kind,
        x: Double = this.x,
        y: Double = this.y,
        size: Double = this.size,
        palette: PalettePresentation? = this.palette,
    ): CustomControlPlacement = CustomControlPlacement(id, kind, x, y, size, palette, true)

    fun toJson(): JsonElement = buildJsonObject {
        put("id", jsonOf(id))
        put("kind", kind.toJson())
        put("x", jsonOf(x))
        put("y", jsonOf(y))
        put("size", jsonOf(size))
        putIfNotNull("palette", palette?.toJson())
    }

    override fun equals(other: Any?): Boolean =
        other is CustomControlPlacement && id == other.id && kind == other.kind && x == other.x && y == other.y &&
            size == other.size && palette == other.palette

    override fun hashCode(): Int = listOf(id, kind, x, y, size, palette).hashCode()
    override fun toString(): String = "CustomControlPlacement(id=$id, kind=$kind, x=$x, y=$y, size=$size, palette=$palette)"

    companion object {
        val sizeRange: ClosedFloatingPointRange<Double> = 0.8..1.6

        fun unit(value: Double): Double = if (value.isFinite()) min(max(value, 0.0), 1.0) else 0.5

        fun clampedSize(value: Double): Double =
            if (value.isFinite()) min(max(value, sizeRange.start), sizeRange.endInclusive) else 1.0

        fun fromJson(e: JsonElement?): CustomControlPlacement? {
            val o = e.obj() ?: return null
            val palette = o["palette"]
            return CustomControlPlacement(
                id = o["id"].str() ?: return null,
                kind = CustomControlKind.fromJson(o["kind"]) ?: return null,
                x = o["x"].dbl() ?: return null,
                y = o["y"].dbl() ?: return null,
                size = o["size"].dbl() ?: return null,
                palette = if (palette == null || palette is JsonNull) null else PalettePresentation.fromJson(palette) ?: return null,
                stored = true,
            )
        }
    }
}

/** One orientation's layout. */
data class CustomControlArrangement(
    /**
     * The corner the permanent cluster was built around: drives Two-Hand
     * Assist's opposite side and the palette's bloom direction.
     */
    val corner: ControlCorner,
    val placements: List<CustomControlPlacement>,
) {
    fun placement(modifier: ControlModifier): CustomControlPlacement? = placements.firstOrNull { it.kind.modifier == modifier }

    /**
     * Mean normalized center of the modifier anchors (or of everything, when
     * there are none): which side of the screen the permanent cluster lives on.
     */
    val clusterCentroid: CGPoint
        get() {
            val anchors = placements.filter { it.kind.modifier != null }
            val points = (if (anchors.isEmpty()) placements else anchors).map { CGPoint(x = it.x, y = it.y) }
            if (points.isEmpty()) return corner.unitPoint
            val sum = points.fold(CGPoint.zero) { a, b -> CGPoint(a.x + b.x, a.y + b.y) }
            return CGPoint(sum.x / points.size.toDouble(), sum.y / points.size.toDouble())
        }

    fun toJson(): JsonElement = buildJsonObject {
        put("corner", jsonOf(corner.raw))
        put("placements", jsonArrayOf(placements.map { it.toJson() }))
    }

    companion object {
        /**
         * Swift's hand-written `init(from:)`: a missing corner is bottom-right
         * and missing placements are none; placements decode lossily.
         */
        fun fromJson(e: JsonElement?): CustomControlArrangement? {
            val o = e.obj() ?: return null
            val corner = o["corner"]
            val placements = o["placements"]
            return CustomControlArrangement(
                corner = if (corner == null || corner is JsonNull) ControlCorner.BottomTrailing else ControlCorner.of(corner.str()) ?: return null,
                placements = if (placements == null || placements is JsonNull) {
                    emptyList()
                } else {
                    placements.lossyListOf(CustomControlPlacement::fromJson) ?: return null
                },
            )
        }

        /**
         * Reference safe-area sizes the template is authored against (an 11"
         * iPad). Positions are stored normalized, so other sizes scale.
         */
        val referenceLandscape = CGSize(width = 1150.0, height = 780.0)
        val referencePortrait = CGSize(width = 780.0, height = 1150.0)

        /** Where the template's Settings anchor sits, from each corner edge. */
        const val templateAnchorInset: CGFloat = 34.0
        const val templateBaseDiameter: CGFloat = PadControlMetrics.baseItem
        const val templateSpacing: CGFloat = 8.0
        val templateUtilities: List<CustomControlKind> = listOf(
            CustomControlKind.Tray(ControlTrayItem.Keyboard), CustomControlKind.Tray(ControlTrayItem.Escape),
            CustomControlKind.Tray(ControlTrayItem.Tab), CustomControlKind.MoveView,
        )
        val templateModifiers: List<ControlTrayItem> =
            listOf(ControlTrayItem.Command, ControlTrayItem.Option, ControlTrayItem.Control, ControlTrayItem.Shift)

        /** Menu Bar, Dock, Show Desktop, Control Center: the Strip's system group. */
        val templateSystem: List<CustomControlKind> = listOf(
            CustomControlKind.Function("menu-bar"), CustomControlKind.Tray(ControlTrayItem.Dock),
            CustomControlKind.Function("show-desktop"), CustomControlKind.Function("control-center"),
        )
        const val utilitySize = 0.9
        const val settingsSize = 0.9

        /**
         * The radial corner template, as true concentric arcs around Settings:
         * Settings (the anchor) -> a utility arc (Keyboard, Escape, Tab, Move
         * View) -> the modifier arc. A held chord's palette blooms on the next
         * arc out ([CustomLayoutGeometry.palettePoints]).
         */
        fun radialTemplate(corner: ControlCorner, portrait: Boolean): CustomControlArrangement {
            val reference = if (portrait) referencePortrait else referenceLandscape
            val inset = templateAnchorInset
            val origin = CGPoint(
                x = if (corner.isLeading) inset else reference.width - inset,
                y = if (corner.isTop) inset else reference.height - inset,
            )
            val edges = CGSize(width = inset, height = inset)
            val base = templateBaseDiameter
            val utilityDiameter = base * utilitySize
            val radii = CornerArcGeometry.layerRadii(
                counts = listOf(templateUtilities.size, templateModifiers.size),
                diameters = listOf(utilityDiameter, base),
                innerDiameter = base * settingsSize, spacing = templateSpacing,
                corner = corner, edgeDistances = edges,
            )
            fun normalized(point: CGPoint): Pair<Double, Double> = Pair(point.x / reference.width, point.y / reference.height)
            val placements = mutableListOf<CustomControlPlacement>()
            val settings = normalized(origin)
            placements.add(
                CustomControlPlacement(
                    id = "settings", kind = CustomControlKind.Tray(ControlTrayItem.Settings),
                    x = settings.first, y = settings.second, size = settingsSize,
                ),
            )
            val utilityPoints = CornerArcGeometry.points(
                count = templateUtilities.size, radius = radii[0], origin = origin, corner = corner,
                diameter = utilityDiameter, edgeDistances = edges,
            )
            for ((kind, point) in templateUtilities.zip(utilityPoints)) {
                val p = normalized(point)
                placements.add(CustomControlPlacement(id = kind.stableID, kind = kind, x = p.first, y = p.second, size = utilitySize))
            }
            val modifierPoints = CornerArcGeometry.points(
                count = templateModifiers.size, radius = radii[1], origin = origin, corner = corner,
                diameter = base, edgeDistances = edges,
            )
            for ((item, point) in templateModifiers.zip(modifierPoints)) {
                val p = normalized(point)
                placements.add(CustomControlPlacement(id = item.raw, kind = CustomControlKind.Tray(item), x = p.first, y = p.second))
            }
            // System actions on the opposite corner's inner arc: inside the
            // arc Two-Hand Assist uses there, so the two never collide.
            val mirrored = CornerArcGeometry.mirroredHorizontally(corner)
            val mirroredOrigin = CGPoint(x = reference.width - origin.x, y = origin.y)
            val systemPoints = CornerArcGeometry.points(
                count = templateSystem.size, radius = radii[0], origin = mirroredOrigin, corner = mirrored,
                diameter = utilityDiameter, edgeDistances = edges,
            )
            for ((kind, point) in templateSystem.zip(systemPoints)) {
                val p = normalized(point)
                placements.add(CustomControlPlacement(id = kind.stableID, kind = kind, x = p.first, y = p.second, size = utilitySize))
            }
            return CustomControlArrangement(corner, placements)
        }
    }
}

data class CustomControlLayout(
    val id: String,
    val name: String,
    val landscape: CustomControlArrangement,
    val portrait: CustomControlArrangement,
    val twoHandAssist: Boolean,
    /** Function Tray item ids shown on the opposite side while idle. */
    val assistActionIDs: List<String>,
    /**
     * Which Function Tray profile this layout's Function controls come from;
     * null follows the active one. The layout owns where; the profile owns what.
     */
    val functionProfile: ControlProfileSlot? = null,
) {
    fun arrangement(portrait: Boolean): CustomControlArrangement = if (portrait) this.portrait else landscape

    /** Swift's mutating `setArrangement`: returns the layout with that orientation replaced. */
    fun setArrangement(arrangement: CustomControlArrangement, portrait: Boolean): CustomControlLayout =
        if (portrait) copy(portrait = arrangement) else copy(landscape = arrangement)

    /** Swift's synthesized `Encodable`: every property under its own name, a nil profile omitted. */
    fun toJson(): JsonElement = buildJsonObject {
        put("id", jsonOf(id))
        put("name", jsonOf(name))
        put("landscape", landscape.toJson())
        put("portrait", portrait.toJson())
        put("twoHandAssist", jsonOf(twoHandAssist))
        put("assistActionIDs", jsonArrayOf(assistActionIDs.map(::jsonOf)))
        putIfNotNull("functionProfile", functionProfile?.let { jsonOf(it.raw) })
    }

    companion object {
        const val maximumCount = 5
        val defaultAssistActionIDs = listOf("undo", "redo", "zoom-in", "zoom-out", "return")

        /** Swift's synthesized `Decodable`: every key but `functionProfile` is required. */
        fun fromJson(e: JsonElement?): CustomControlLayout? {
            val o = e.obj() ?: return null
            val profile = o["functionProfile"]
            return CustomControlLayout(
                id = o["id"].str() ?: return null,
                name = o["name"].str() ?: return null,
                landscape = CustomControlArrangement.fromJson(o["landscape"]) ?: return null,
                portrait = CustomControlArrangement.fromJson(o["portrait"]) ?: return null,
                twoHandAssist = o["twoHandAssist"].bool() ?: return null,
                assistActionIDs = o["assistActionIDs"].listOf { it.str() } ?: return null,
                functionProfile = if (profile == null || profile is JsonNull) null else ControlProfileSlot.of(profile.str()) ?: return null,
            )
        }

        /** The radial starter: both orientations built around [corner], with Two-Hand Assist on. */
        fun radialTemplate(
            id: String = newUUIDString(),
            name: String,
            corner: ControlCorner = ControlCorner.BottomTrailing,
        ): CustomControlLayout = CustomControlLayout(
            id = id, name = name,
            landscape = CustomControlArrangement.radialTemplate(corner, portrait = false),
            portrait = CustomControlArrangement.radialTemplate(corner, portrait = true),
            twoHandAssist = true,
            assistActionIDs = defaultAssistActionIDs,
        )
    }
}

/**
 * Polar geometry for controls arranged on concentric quarter arcs around a
 * corner origin. Angles are in radians in a y-down space (0 = right, pi/2 =
 * down). Each arc spans from the corner's horizontal edge to its vertical
 * edge, trimmed so every control stays clear of both edges, with controls
 * evenly spaced by angle.
 */
object CornerArcGeometry {
    /** Direction along the corner's horizontal edge, into the screen. */
    fun horizontalEdgeAngle(corner: ControlCorner): CGFloat = if (corner.isLeading) 0.0 else PI

    /** Signed sweep from the horizontal edge toward the vertical edge (+-pi/2). */
    fun sweep(corner: ControlCorner): CGFloat =
        // leading+top: 0 -> pi/2 (+); trailing+top: pi -> pi/2 (-);
        // leading+bottom: 0 -> -pi/2 (-); trailing+bottom: pi -> 3pi/2 (+).
        if (corner.isLeading == corner.isTop) PI / 2 else -PI / 2

    /**
     * Offsets from the horizontal edge (0...pi/2) that keep a control of
     * [diameter] on an arc of [radius] inside both edges. [edgeDistances] is the
     * origin's distance to the vertical edge (width) and to the horizontal edge (height).
     */
    fun usableOffsets(radius: CGFloat, diameter: CGFloat, edgeDistances: CGSize): ClosedFloatingPointRange<CGFloat> {
        if (!(radius > 0)) return (PI / 4)..(PI / 4)
        fun clearance(distance: CGFloat): CGFloat = asin(min(1.0, max(0.0, (diameter / 2 - distance) / radius)))
        val lower = clearance(edgeDistances.height)
        val upper = PI / 2 - clearance(edgeDistances.width)
        return if (lower <= upper) lower..upper else ((lower + upper) / 2)..((lower + upper) / 2)
    }

    /** Evenly spaced angles for [count] controls on the arc of [radius]. */
    fun angles(count: Int, radius: CGFloat, corner: ControlCorner, diameter: CGFloat, edgeDistances: CGSize): List<CGFloat> {
        if (count <= 0) return emptyList()
        val usable = usableOffsets(radius, diameter, edgeDistances)
        val direction = if (sweep(corner) > 0) 1.0 else -1.0
        return (0 until count).map { index ->
            val t = if (count == 1) 0.5 else index.toDouble() / (count - 1).toDouble()
            val offset = usable.start + t * (usable.endInclusive - usable.start)
            horizontalEdgeAngle(corner) + direction * offset
        }
    }

    fun points(count: Int, radius: CGFloat, origin: CGPoint, corner: ControlCorner, diameter: CGFloat, edgeDistances: CGSize): List<CGPoint> =
        angles(count, radius, corner, diameter, edgeDistances)
            .map { CGPoint(x = origin.x + radius * cos(it), y = origin.y + radius * sin(it)) }

    /** Neighbors' center distance on an arc: the chord between angles. */
    fun chord(radius: CGFloat, angle: CGFloat): CGFloat = 2 * radius * sin(abs(angle) / 2)

    /** The smallest radius >= [minimum] whose arc holds [count] controls at least [pitch] apart (center to center). */
    fun radius(count: Int, pitch: CGFloat, minimum: CGFloat, diameter: CGFloat, corner: ControlCorner, edgeDistances: CGSize): CGFloat {
        if (count <= 1) return minimum
        var radius = max(minimum, 1.0)
        for (pass in 0 until 2000) {
            val usable = usableOffsets(radius, diameter, edgeDistances)
            val step = (usable.endInclusive - usable.start) / (count - 1).toDouble()
            if (chord(radius, step) >= pitch - 0.01) return radius
            radius += 1.0
        }
        return radius
    }

    /** How many controls fit on the arc of [radius] at least [pitch] apart. */
    fun capacity(radius: CGFloat, pitch: CGFloat, diameter: CGFloat, edgeDistances: CGSize): Int {
        if (!(radius > 0) || !(pitch > 0)) return 1
        val usable = usableOffsets(radius, diameter, edgeDistances)
        val step = 2 * asin(min(1.0, pitch / (2 * radius)))
        if (!(step > 0)) return 1
        return max(1, ((usable.endInclusive - usable.start) / step + 0.0001).toInt() + 1)
    }

    /**
     * Radii for successive layers around an inner control of [innerDiameter]:
     * each layer sits one [spacing] clear of the previous one, and is widened
     * only as much as its own count requires.
     */
    fun layerRadii(
        counts: List<Int>, diameters: List<CGFloat>, innerDiameter: CGFloat, spacing: CGFloat,
        corner: ControlCorner, edgeDistances: CGSize,
    ): List<CGFloat> {
        val radii = mutableListOf<CGFloat>()
        var previousRadius = 0.0
        var previousDiameter = innerDiameter
        for ((count, diameter) in counts.zip(diameters)) {
            val minimum = previousRadius + previousDiameter / 2 + diameter / 2 + spacing
            val radius = radius(count, pitch = diameter + spacing, minimum = minimum, diameter = diameter, corner = corner, edgeDistances = edgeDistances)
            radii.add(radius)
            previousRadius = radius
            previousDiameter = diameter
        }
        return radii
    }

    fun mirroredHorizontally(corner: ControlCorner): ControlCorner = when (corner) {
        ControlCorner.TopLeading -> ControlCorner.TopTrailing
        ControlCorner.TopTrailing -> ControlCorner.TopLeading
        ControlCorner.BottomLeading -> ControlCorner.BottomTrailing
        ControlCorner.BottomTrailing -> ControlCorner.BottomLeading
    }
}

/**
 * A Custom arrangement read as a corner cluster: the Settings anchor as
 * origin, and every modifier on the screen side of it, near its corner. When
 * an arrangement isn't one (controls dragged elsewhere), palettes and Two-Hand
 * Assist fall back to local geometry.
 */
data class CornerCluster(
    val origin: CGPoint,
    val corner: ControlCorner,
    /** The outermost modifier arc's radius. */
    val modifierRadius: CGFloat,
    /** The largest modifier diameter. */
    val modifierDiameter: CGFloat,
    /** The origin's distances to its vertical and horizontal area edges. */
    val edgeDistances: CGSize,
) {
    /** The same cluster mirrored across the area's vertical center line: Two-Hand Assist's opposite side. */
    fun mirrored(area: CGRect): CornerCluster = CornerCluster(
        origin = CGPoint(x = area.minX + area.maxX - origin.x, y = origin.y),
        corner = CornerArcGeometry.mirroredHorizontally(corner),
        modifierRadius = modifierRadius, modifierDiameter = modifierDiameter,
        edgeDistances = edgeDistances,
    )

    /**
     * Palette keys on the arc(s) directly outside the modifier arc: the first
     * ring one [spacing] beyond it; more keys than fit continue on the next
     * ring out. Each ring's keys are spread evenly by angle.
     */
    fun palettePoints(count: Int, keyDiameter: CGFloat, spacing: CGFloat): List<CGPoint> {
        if (count <= 0) return emptyList()
        val pitch = keyDiameter + spacing
        var radius = modifierRadius + modifierDiameter / 2 + keyDiameter / 2 + spacing
        var remaining = count
        val result = mutableListOf<CGPoint>()
        while (remaining > 0) {
            val fits = CornerArcGeometry.capacity(radius, pitch, keyDiameter, edgeDistances)
            val ring = min(fits, remaining)
            result += CornerArcGeometry.points(ring, radius, origin, corner, keyDiameter, edgeDistances)
            remaining -= ring
            radius += pitch
        }
        return result
    }

    /**
     * Controls on the modifier arc itself (Two-Hand Assist helpers and idle
     * actions use the mirrored cluster's modifier arc).
     */
    fun modifierArcPoints(count: Int, diameter: CGFloat): List<CGPoint> =
        CornerArcGeometry.points(count, modifierRadius, origin, corner, diameter, edgeDistances)

    companion object {
        fun resolve(arrangement: CustomControlArrangement, frames: Map<String, CGRect>, area: CGRect): CornerCluster? {
            val settings = arrangement.placements.firstOrNull { it.kind == CustomControlKind.Tray(ControlTrayItem.Settings) } ?: return null
            val settingsFrame = frames[settings.id] ?: return null
            val origin = CGPoint(x = settingsFrame.midX, y = settingsFrame.midY)
            // The corner the anchor actually sits in: the stored corner can be
            // stale once the cluster has been dragged elsewhere.
            val corner = if (origin.y < area.midY) {
                if (origin.x < area.midX) ControlCorner.TopLeading else ControlCorner.TopTrailing
            } else {
                if (origin.x < area.midX) ControlCorner.BottomLeading else ControlCorner.BottomTrailing
            }
            val modifierFrames = arrangement.placements.filter { it.kind.modifier != null }.mapNotNull { frames[it.id] }
            if (modifierFrames.isEmpty()) return null
            val reach = min(area.width, area.height) * 0.5
            val inward = CGPoint(x = if (corner.isLeading) 1.0 else -1.0, y = if (corner.isTop) 1.0 else -1.0)
            var radius = 0.0
            for (frame in modifierFrames) {
                val dx = frame.midX - origin.x
                val dy = frame.midY - origin.y
                // On the screen side of the anchor (a little slack for edges).
                if (!(dx * inward.x >= -frame.width / 2 && dy * inward.y >= -frame.height / 2)) return null
                val distance = hypot(dx, dy)
                if (!(distance <= reach)) return null
                radius = max(radius, distance)
            }
            val edges = CGSize(
                width = if (corner.isLeading) origin.x - area.minX else area.maxX - origin.x,
                height = if (corner.isTop) origin.y - area.minY else area.maxY - origin.y,
            )
            return CornerCluster(
                origin = origin, corner = corner, modifierRadius = radius,
                modifierDiameter = modifierFrames.maxOfOrNull { it.width } ?: 0.0,
                edgeDistances = CGSize(width = max(0.0, edges.width), height = max(0.0, edges.height)),
            )
        }
    }
}

// region Library (create / rename / delete / select)

val ReceiverControlPreferences.canCreateCustomLayout: Boolean get() = customLayouts.size < CustomControlLayout.maximumCount

/**
 * What a device starts with before anything is saved. iPad opens on the
 * radial Custom layout around a bottom-right Settings anchor, with Strip and
 * Overlay one setting away; iPhone keeps the standard defaults. Saved
 * preferences are never replaced by this.
 */
fun ReceiverControlPreferences.Companion.initial(isPad: Boolean, phone: Boolean = !isPad): ReceiverControlPreferences {
    val preferences = ReceiverControlPreferences()
    // Phones start in Trackpad, tablets in Direct Touch (schema 21).
    preferences.inputMode = if (phone) PointerInputMode.Trackpad else PointerInputMode.Direct
    if (!isPad) return preferences
    preferences.createCustomLayout(corner = ControlCorner.BottomTrailing)
    preferences.padControlLayout = PadControlLayoutMode.Custom
    return preferences
}

/** The selected Custom layout, falling back to the first one. */
val ReceiverControlPreferences.activeCustomLayout: CustomControlLayout?
    get() = customLayouts.firstOrNull { it.id == activeCustomLayoutID } ?: customLayouts.firstOrNull()

/** Creates a radial starter layout and selects it. Null once [CustomControlLayout.maximumCount] exist. */
fun ReceiverControlPreferences.createCustomLayout(
    corner: ControlCorner = ControlCorner.BottomTrailing,
    id: String = newUUIDString(),
): String? {
    if (!canCreateCustomLayout) return null
    val layout = CustomControlLayout.radialTemplate(id = id, name = nextCustomLayoutName(), corner = corner)
    customLayouts = customLayouts + layout
    activeCustomLayoutID = layout.id
    return layout.id
}

fun ReceiverControlPreferences.renameCustomLayout(id: String, name: String) {
    val trimmed = name.trim { it.isWhitespace() }
    if (trimmed.isEmpty()) return
    val index = customLayouts.indexOfFirst { it.id == id }
    if (index < 0) return
    customLayouts = customLayouts.toMutableList().also { it[index] = it[index].copy(name = trimmed.prefixCharacters(40)) }
}

/**
 * Deleting the active layout selects the first remaining one; deleting the
 * last one leaves Custom mode with nothing to show, so the layout mode falls
 * back to Overlay.
 */
fun ReceiverControlPreferences.deleteCustomLayout(id: String) {
    customLayouts = customLayouts.filter { it.id != id }
    if (activeCustomLayoutID == id) activeCustomLayoutID = customLayouts.firstOrNull()?.id
    if (customLayouts.isEmpty() && padControlLayout == PadControlLayoutMode.Custom) padControlLayout = PadControlLayoutMode.Overlay
}

fun ReceiverControlPreferences.updateCustomLayout(layout: CustomControlLayout) {
    val index = customLayouts.indexOfFirst { it.id == layout.id }
    if (index < 0) return
    customLayouts = customLayouts.toMutableList().also { it[index] = layout }
}

private fun ReceiverControlPreferences.nextCustomLayoutName(): String {
    val names = customLayouts.map { it.name }.toSet()
    var number = customLayouts.size + 1
    while ("Custom Layout $number" in names) number += 1
    return "Custom Layout $number"
}

// endregion

// region Geometry

/** `ManualViewportState.normalizedAngle` (RemoteViewport.swift), which this file's `window` uses. */
internal fun normalizedAngle(angle: CGFloat): CGFloat {
    if (!angle.isFinite()) return 0.0
    var value = angle.rem(PI * 2)
    if (value > PI) value -= PI * 2
    if (value <= -PI) value += PI * 2
    return value
}

/** A normalized (0...1) position, as the editor stores a dropped control. */
data class NormalizedPosition(val x: Double, val y: Double)

object CustomLayoutGeometry {
    const val margin: CGFloat = 12.0

    /**
     * The area normalized placements map into: the safe area, less a small
     * margin, so nothing lands under the Home indicator or a rounded corner.
     */
    fun layoutArea(container: CGRect, safeInsets: ControlSafeInsets): CGRect {
        val horizontalInset: CGFloat = safeInsets.leading + safeInsets.trailing + margin * 2
        val verticalInset: CGFloat = safeInsets.top + safeInsets.bottom + margin * 2
        val width: CGFloat = max(0.0, container.width - horizontalInset)
        val height: CGFloat = max(0.0, container.height - verticalInset)
        return CGRect(container.minX + safeInsets.leading + margin, container.minY + safeInsets.top + margin, width, height)
    }

    /** A placement's circle, clamped so all of it stays inside [area]. */
    fun frame(placement: CustomControlPlacement, area: CGRect, baseDiameter: CGFloat): CGRect {
        val diameter = baseDiameter * CustomControlPlacement.clampedSize(placement.size)
        val center = CGPoint(
            x = area.minX + CustomControlPlacement.unit(placement.x) * area.width,
            y = area.minY + CustomControlPlacement.unit(placement.y) * area.height,
        )
        return PadEdgeGeometry.clamped(CGRect(center.x - diameter / 2, center.y - diameter / 2, diameter, diameter), area)
    }

    /** The normalized position for a view point (the editor's drag), clamped to the area. */
    fun normalizedPoint(point: CGPoint, area: CGRect): NormalizedPosition {
        if (!(area.width > 0 && area.height > 0)) return NormalizedPosition(0.5, 0.5)
        return NormalizedPosition(
            CustomControlPlacement.unit((point.x - area.minX) / area.width),
            CustomControlPlacement.unit((point.y - area.minY) / area.height),
        )
    }

    /** Palette keys are a touch smaller than the controls they bloom from. */
    fun paletteKeyDiameter(baseDiameter: CGFloat): CGFloat = baseDiameter * 0.92

    /**
     * Where a modifier's palette keys go: around [anchor], shaped and spaced by
     * [style], blooming toward the middle of [area] unless [style] fixes a
     * direction, and clear of the other controls. The one source for both the
     * live overlay and the editor's preview.
     */
    fun paletteCenters(
        count: Int, anchor: CGRect, style: PalettePresentation, area: CGRect,
        baseDiameter: CGFloat, spacing: CGFloat, obstacles: List<CGRect>,
    ): List<CGPoint> {
        val center = CGPoint(anchor.midX, anchor.midY)
        val direction = style.directionDegrees?.let { it * PI / 180 }
            ?: RadialPaletteLayout.direction(center, CGPoint(area.midX, area.midY))
        val spread = min(max(style.spacing, PalettePresentation.spacingRange.start), PalettePresentation.spacingRange.endInclusive)
        return RadialPaletteLayout.points(
            count = count, center = center, shape = style.shape,
            itemDiameter = paletteKeyDiameter(baseDiameter),
            spacing = spacing, minimumRadius = baseDiameter * 1.5 * spread,
            direction = direction, bounds = area, obstacles = obstacles,
        )
    }

    /** Every placement's resolved circle, by placement id. */
    fun frames(arrangement: CustomControlArrangement, area: CGRect, baseDiameter: CGFloat): Map<String, CGRect> {
        val result = LinkedHashMap<String, CGRect>()
        for (placement in arrangement.placements) result.getOrPut(placement.id) { frame(placement, area, baseDiameter) }
        return result
    }

    /**
     * Where the palette of the modifier placed at [anchorID] goes: the one
     * source for the live overlay, the editor and Preview. A default
     * (automatic arc) palette on a corner cluster blooms on the arc right
     * outside the modifier arc; any other style blooms around its own
     * modifier, clear of the other controls.
     */
    fun palettePoints(
        count: Int, anchorID: String, arrangement: CustomControlArrangement,
        frames: Map<String, CGRect>, area: CGRect, baseDiameter: CGFloat, spacing: CGFloat,
    ): List<CGPoint> {
        if (count <= 0) return emptyList()
        val anchor = frames[anchorID] ?: return emptyList()
        val placement = arrangement.placements.firstOrNull { it.id == anchorID } ?: return emptyList()
        val style = placement.palette ?: PalettePresentation()
        val keyDiameter = paletteKeyDiameter(baseDiameter)
        if (style.shape == PaletteShape.Arc && style.directionDegrees == null) {
            val cluster = CornerCluster.resolve(arrangement, frames, area)
            if (cluster != null) {
                val inner = area.insetBy(keyDiameter / 2, keyDiameter / 2)
                return cluster.palettePoints(count, keyDiameter, spacing * style.spacing)
                    .map { CGPoint(x = min(max(it.x, inner.minX), inner.maxX), y = min(max(it.y, inner.minY), inner.maxY)) }
            }
        }
        return paletteCenters(
            count, anchor, style, area, baseDiameter, spacing,
            obstacles = frames.filter { it.key != anchorID }.map { it.value },
        )
    }

    const val edgeSnapTolerance: CGFloat = 12.0

    /**
     * Where a control of [diameter] dropped at [point] is stored.
     * - Snap to Edges pulls it flush against the layout area's edges, or onto
     *   its center lines, when it lands within [edgeSnapTolerance].
     * - Snap to Guides pulls it onto the nearest alignment-guide line.
     * Guide display (Dots / Grid Lines) is editor chrome and never reaches the
     * layout; only these stored positions do.
     */
    fun droppedPosition(point: CGPoint, area: CGRect, diameter: CGFloat, snapToEdges: Boolean, snapToGuides: Boolean): NormalizedPosition {
        fun edgeSnap(value: CGFloat, lower: CGFloat, upper: CGFloat, middle: CGFloat): CGFloat? {
            val tolerance = edgeSnapTolerance
            if (abs(value - diameter / 2 - lower) <= tolerance) return lower + diameter / 2
            if (abs(upper - value - diameter / 2) <= tolerance) return upper - diameter / 2
            if (abs(value - middle) <= tolerance) return middle
            return null
        }
        var x = point.x
        var y = point.y
        var snappedX = false
        var snappedY = false
        if (snapToEdges) {
            edgeSnap(x, area.minX, area.maxX, area.midX)?.let { x = it; snappedX = true }
            edgeSnap(y, area.minY, area.maxY, area.midY)?.let { y = it; snappedY = true }
        }
        var position = normalizedPoint(CGPoint(x, y), area)
        if (snapToGuides) {
            if (!snappedX) position = position.copy(x = snapped(position.x))
            if (!snappedY) position = position.copy(y = snapped(position.y))
        }
        return position
    }

    /**
     * Snaps a normalized coordinate to a 1/[divisions] grid when within
     * [tolerance] of a line: the editor's alignment assist.
     */
    fun snapped(value: Double, divisions: Int = 24, tolerance: Double = 0.012): Double {
        if (divisions <= 0) return value
        val step = 1 / divisions.toDouble()
        val nearest = (value / step).roundedAwayFromZero() * step
        return if (abs(nearest - value) <= tolerance) nearest else value
    }
}

/**
 * Structured palette geometry: arc/fan, ring, row, or column around a center,
 * with collision avoidance against the other controls.
 */
object RadialPaletteLayout {
    /** The widest an arc fans before starting another, larger arc. */
    const val maximumArcSpan: CGFloat = 150 * PI / 180

    /** `CGRect.infinite`: only its `isInfinite` matters (the wheel skips its on-screen clamp). */
    private val infiniteBounds = CGRect(
        Double.NEGATIVE_INFINITY, Double.NEGATIVE_INFINITY, Double.POSITIVE_INFINITY, Double.POSITIVE_INFINITY,
    )

    /**
     * @param minimumRadius distance from [center] to the first ring/line.
     * @param direction bloom direction in radians (y-down, 0 = right).
     * @param obstacles frames the keys must not overlap (other controls); the
     * radius grows until they're clear, a bounded number of times.
     */
    fun points(
        count: Int, center: CGPoint, shape: PaletteShape, itemDiameter: CGFloat, spacing: CGFloat,
        minimumRadius: CGFloat, direction: CGFloat, bounds: CGRect, obstacles: List<CGRect> = emptyList(),
    ): List<CGPoint> {
        if (!(count > 0 && itemDiameter > 0 && direction.isFinite() && minimumRadius.isFinite())) return emptyList()
        if (shape == PaletteShape.Arc) {
            return fan(count, center, itemDiameter, spacing, max(minimumRadius, itemDiameter), direction, bounds, obstacles)
        }
        if (shape == PaletteShape.Wheel) {
            return WheelPaletteGeometry.layout(count, CGRect(center.x, center.y, 0.0, 0.0), itemDiameter, spacing, bounds)
                ?.segments?.map { it.labelPoint } ?: emptyList()
        }
        var radius = max(minimumRadius, itemDiameter)
        var result = raw(count, center, shape, itemDiameter, spacing, radius, direction)
        for (pass in 0 until 10) {
            if (!collides(result, itemDiameter, spacing, obstacles)) break
            radius += (itemDiameter + spacing) / 2
            result = raw(count, center, shape, itemDiameter, spacing, radius, direction)
        }
        val inner = bounds.insetBy(itemDiameter / 2, itemDiameter / 2)
        if (!(inner.width >= 0 && inner.height >= 0)) return result
        return result.map { CGPoint(x = min(max(it.x, inner.minX), inner.maxX), y = min(max(it.y, inner.minY), inner.maxY)) }
    }

    /**
     * An arc of evenly spaced keys at one radius around [center], fanned into
     * free space: the angular window closest to [direction] in which every key
     * stays inside [bounds] and clear of [obstacles]. When no window is wide
     * enough, the radius grows; more keys than one arc holds (<= [maximumArcSpan])
     * continue on the next arc out.
     */
    fun fan(
        count: Int, center: CGPoint, itemDiameter: CGFloat, spacing: CGFloat, minimumRadius: CGFloat,
        direction: CGFloat, bounds: CGRect, obstacles: List<CGRect> = emptyList(),
    ): List<CGPoint> {
        val pitch = itemDiameter + spacing
        val inner = bounds.insetBy(itemDiameter / 2, itemDiameter / 2)
        val reach = itemDiameter / 2 + spacing / 2
        fun valid(angle: CGFloat, radius: CGFloat): Boolean {
            val point = CGPoint(x = center.x + radius * cos(angle), y = center.y + radius * sin(angle))
            return inner.contains(point) && !obstacles.any { it.insetBy(-reach, -reach).contains(point) }
        }
        var result = listOf<CGPoint>()
        var radius = minimumRadius
        var remaining = count
        var attempts = 0
        while (remaining > 0 && attempts < 40) {
            attempts += 1
            val step = angularStep(pitch, radius)
            val capacity = max(1, (maximumArcSpan / step + 0.0001).toInt() + 1)
            val inArc = min(capacity, remaining)
            val needed = step * (inArc - 1).toDouble()
            val middle = window(needed, direction, radius, ::valid)
            if (middle != null) {
                result = result + (0 until inArc).map { index ->
                    val angle = middle + (index.toDouble() - (inArc - 1).toDouble() / 2) * step
                    CGPoint(x = center.x + radius * cos(angle), y = center.y + radius * sin(angle))
                }
                remaining -= inArc
                radius += pitch
            } else {
                radius += pitch / 2
            }
        }
        if (remaining > 0) {
            // Nowhere fits (a tiny screen): fall back to the plain arc, clamped.
            val rest = raw(remaining, center, PaletteShape.Ring, itemDiameter, spacing, radius, direction)
            result = result + rest.map { CGPoint(x = min(max(it.x, inner.minX), inner.maxX), y = min(max(it.y, inner.minY), inner.maxY)) }
        }
        return result
    }

    /**
     * The center angle of a valid window [needed] radians wide, as close to
     * [preferred] as the free arcs at [radius] allow; null if none fits.
     */
    private fun window(needed: CGFloat, preferred: CGFloat, radius: CGFloat, valid: (CGFloat, CGFloat) -> Boolean): CGFloat? {
        val samples = 720
        val sample = 2 * PI / samples.toDouble()
        val flags = (0 until samples).map { valid(it.toDouble() * sample, radius) }
        if (flags.all { it }) return preferred
        val firstInvalid = flags.indexOf(false)
        if (firstInvalid < 0) return preferred
        // Walk once around, starting just after an invalid sample, collecting
        // the free arcs as [start, end] angles.
        val arcs = mutableListOf<Pair<CGFloat, CGFloat>>()
        var runStart: Int? = null
        for (offset in 1..samples) {
            val index = (firstInvalid + offset) % samples
            if (flags[index]) {
                if (runStart == null) runStart = firstInvalid + offset
            } else {
                val start = runStart
                if (start != null) {
                    arcs.add(Pair(start.toDouble() * sample, (firstInvalid + offset - 1).toDouble() * sample))
                    runStart = null
                }
            }
        }
        var best: Pair<CGFloat, CGFloat>? = null
        for (arc in arcs) {
            if (!(arc.second - arc.first >= needed)) continue
            // Closest angle to `preferred` (mod 2pi) the window's middle may take.
            val lower = arc.first + needed / 2
            val upper = arc.second - needed / 2
            var candidate = preferred
            while (candidate < lower - PI) candidate += 2 * PI
            while (candidate > upper + PI) candidate -= 2 * PI
            val clamped = min(max(candidate, lower), upper)
            val distance = abs(normalizedAngle(clamped - preferred))
            if (best == null || distance < best.second) best = Pair(clamped, distance)
        }
        return best?.first
    }

    /** Radians from [point] toward [target] (y-down). */
    fun direction(point: CGPoint, target: CGPoint): CGFloat {
        val dx = target.x - point.x
        val dy = target.y - point.y
        if (!(dx != 0.0 || dy != 0.0)) return -PI / 2
        return atan2(dy, dx)
    }

    private fun raw(
        count: Int, center: CGPoint, shape: PaletteShape, diameter: CGFloat, spacing: CGFloat,
        radius: CGFloat, direction: CGFloat,
    ): List<CGPoint> {
        val pitch = diameter + spacing
        when (shape) {
            PaletteShape.Arc -> {
                val points = mutableListOf<CGPoint>()
                var ringRadius = radius
                while (points.size < count) {
                    val step = angularStep(pitch, ringRadius)
                    val capacity = max(1, (maximumArcSpan / step).toInt() + 1)
                    val inRing = min(capacity, count - points.size)
                    for (index in 0 until inRing) {
                        val angle = direction + (index.toDouble() - (inRing - 1).toDouble() / 2) * step
                        points.add(CGPoint(x = center.x + ringRadius * cos(angle), y = center.y + ringRadius * sin(angle)))
                    }
                    ringRadius += pitch
                }
                return points
            }
            PaletteShape.Ring -> {
                // One ring, widened until neighbors are a full pitch apart.
                val needed = if (count > 1) pitch / (2 * sin(PI / count.toDouble())) else radius
                val ringRadius = max(radius, needed)
                return (0 until count).map { index ->
                    val angle = direction + index.toDouble() * 2 * PI / count.toDouble()
                    CGPoint(x = center.x + ringRadius * cos(angle), y = center.y + ringRadius * sin(angle))
                }
            }
            PaletteShape.Wheel ->
                return WheelPaletteGeometry.layout(count, CGRect(center.x, center.y, 0.0, 0.0), diameter, spacing, infiniteBounds)
                    ?.segments?.map { it.labelPoint } ?: emptyList()
            PaletteShape.Row, PaletteShape.Column -> {
                val origin = CGPoint(x = center.x + radius * cos(direction), y = center.y + radius * sin(direction))
                return (0 until count).map { index ->
                    val offset = (index.toDouble() - (count - 1).toDouble() / 2) * pitch
                    if (shape == PaletteShape.Row) CGPoint(x = origin.x + offset, y = origin.y) else CGPoint(x = origin.x, y = origin.y + offset)
                }
            }
        }
    }

    /** The angle between neighbors a full [pitch] apart on a circle. */
    private fun angularStep(pitch: CGFloat, radius: CGFloat): CGFloat = 2 * asin(min(1.0, pitch / (2 * radius)))

    private fun collides(points: List<CGPoint>, diameter: CGFloat, spacing: CGFloat, obstacles: List<CGRect>): Boolean {
        val reach = diameter / 2 + spacing / 2
        return points.any { point -> obstacles.any { it.insetBy(-reach, -reach).contains(point) } }
    }
}

// endregion

// region Two-Hand Assist

/**
 * What the opposite side shows. A projection of the one shared
 * `ControlInteractionState`; never a chord state of its own.
 */
sealed interface TwoHandAssistState {
    /** Assist off, or the layout has no Two-Hand Assist. */
    data object Hidden : TwoHandAssistState

    /** No chord in progress: the idle Function actions show. */
    data object Idle : TwoHandAssistState

    /**
     * A modifier is pressed, held or latched: the helper modifiers show, with
     * [active] highlighted exactly as on the primary side.
     */
    data class Helper(val active: Set<ControlModifier>) : TwoHandAssistState
}

object TwoHandAssist {
    fun state(enabled: Boolean, interaction: ControlInteractionState): TwoHandAssistState {
        if (!enabled) return TwoHandAssistState.Hidden
        val active = interaction.latchedModifiers + interaction.temporaryModifiers
        return when (val phase = interaction.phase) {
            ControlInteractionPhase.Idle, ControlInteractionPhase.Cancelled, ControlInteractionPhase.Executing ->
                if (active.isEmpty()) TwoHandAssistState.Idle else TwoHandAssistState.Helper(active)
            is ControlInteractionPhase.Pressed -> TwoHandAssistState.Helper(active + phase.modifier)
            is ControlInteractionPhase.Latched, is ControlInteractionPhase.Palette -> TwoHandAssistState.Helper(active)
        }
    }

    /**
     * The helper's anchor: the permanent cluster mirrored across the screen. A
     * cluster on the left/right mirrors horizontally (bottom-right ->
     * bottom-left); one centered along the top or bottom mirrors vertically instead.
     */
    fun helperAnchor(clusterCentroid: CGPoint): CGPoint {
        val c = clusterCentroid
        val horizontalBias = abs(c.x - 0.5)
        val verticalBias = abs(c.y - 0.5)
        return if (horizontalBias >= verticalBias) CGPoint(1 - c.x, c.y) else CGPoint(c.x, 1 - c.y)
    }

    /**
     * Centers for [count] helper (or idle) controls: a compact arc around the
     * mirrored anchor, fanning toward the middle of [area].
     */
    fun helperPoints(count: Int, clusterCentroid: CGPoint, area: CGRect, itemDiameter: CGFloat, spacing: CGFloat): List<CGPoint> {
        if (!(count > 0 && area.width > 0 && area.height > 0)) return emptyList()
        val anchorUnit = helperAnchor(clusterCentroid)
        val inner = area.insetBy(itemDiameter / 2, itemDiameter / 2)
        val anchor = CGPoint(
            x = min(max(area.minX + anchorUnit.x * area.width, inner.minX), inner.maxX),
            y = min(max(area.minY + anchorUnit.y * area.height, inner.minY), inner.maxY),
        )
        val direction = RadialPaletteLayout.direction(anchor, CGPoint(area.midX, area.midY))
        return RadialPaletteLayout.points(
            count = count, center = anchor, shape = PaletteShape.Arc,
            itemDiameter = itemDiameter, spacing = spacing,
            minimumRadius = itemDiameter * 1.1, direction = direction, bounds = area,
        )
    }

    /**
     * Two-Hand Assist positions for a Custom arrangement: on a corner cluster,
     * the modifier arc mirrored to the opposite side (same radius, same angular
     * spread); otherwise the compact arc of the centroid-based [helperPoints].
     */
    fun helperPoints(
        count: Int, arrangement: CustomControlArrangement, frames: Map<String, CGRect>,
        area: CGRect, itemDiameter: CGFloat, spacing: CGFloat,
    ): List<CGPoint> {
        if (count <= 0) return emptyList()
        val cluster = CornerCluster.resolve(arrangement, frames, area)
            ?: return helperPoints(count, arrangement.clusterCentroid, area, itemDiameter, spacing)
        val mirrored = cluster.mirrored(area)
        // More controls than the modifier arc holds widen the arc, never crowd it.
        val widened = mirrored.copy(
            modifierRadius = CornerArcGeometry.radius(
                count = count, pitch = itemDiameter + spacing, minimum = mirrored.modifierRadius,
                diameter = itemDiameter, corner = mirrored.corner, edgeDistances = mirrored.edgeDistances,
            ),
        )
        return widened.modifierArcPoints(count, itemDiameter)
    }

    /** The modifiers the helper offers, in canonical order. */
    val helperModifiers: List<ControlModifier> = ControlModifier.entries
}

/**
 * A tap on a Two-Hand Assist helper modifier, applied to this same chord state:
 * - during a primary-side hold (pressed or palette), toggles the modifier as a
 *   temporary member of the held chord, so the palette updates at once and
 *   everything releases with the hold;
 * - otherwise (a latched chord, or nothing yet), it's an ordinary latch toggle,
 *   exactly a tap on that modifier's own button.
 */
fun ControlInteractionState.toggleAssistModifier(modifier: ControlModifier): List<ControlInteractionEffect> {
    when (val current = phase) {
        is ControlInteractionPhase.Pressed -> {
            val held = current.modifier
            val effects = beginPalette(held).toMutableList()
            if (modifier != held) effects += addTemporaryModifier(modifier)
            return effects
        }
        is ControlInteractionPhase.Palette -> {
            if (modifier in temporaryModifiers) return updateTemporaryChord(temporaryModifiers - modifier)
            return addTemporaryModifier(modifier)
        }
        ControlInteractionPhase.Idle, is ControlInteractionPhase.Latched, ControlInteractionPhase.Executing, ControlInteractionPhase.Cancelled ->
            return tap(modifier)
    }
}

// endregion

// region Wheel palette

/**
 * A ring of wedge-shaped segments around a center disc: the Wheel palette
 * style. Pure geometry: the renderer draws the wedges and the chord gesture
 * hit-tests them with [segmentIndex].
 */
data class WheelPaletteLayout(
    val center: CGPoint,
    val innerRadius: CGFloat,
    val outerRadius: CGFloat,
    val segments: List<Segment>,
) {
    data class Segment(
        val startAngle: CGFloat,
        val endAngle: CGFloat,
        /** Where the segment's key label sits. */
        val labelPoint: CGPoint,
    )

    val frame: CGRect get() = CGRect(center.x - outerRadius, center.y - outerRadius, outerRadius * 2, outerRadius * 2)

    /** The segment under [point], including a small slack outside the ring. */
    fun segmentIndex(point: CGPoint, slack: CGFloat = 14.0): Int? {
        if (segments.isEmpty()) return null
        val distance = hypot(point.x - center.x, point.y - center.y)
        if (!(distance >= innerRadius - slack && distance <= outerRadius + slack)) return null
        val first = segments[0].startAngle
        var angle = atan2(point.y - center.y, point.x - center.x) - first
        while (angle < 0) angle += 2 * PI
        while (angle >= 2 * PI) angle -= 2 * PI
        return min(segments.size - 1, (angle / (2 * PI / segments.size.toDouble())).toInt())
    }
}

object WheelPaletteGeometry {
    /**
     * The wheel for [count] actions around [anchor] (a modifier, or a rail): a
     * ring just clear of the anchor, wide enough for a key per segment, with the
     * first segment centered at the top. The center moves inward when the whole
     * wheel wouldn't fit inside [bounds].
     */
    fun layout(count: Int, anchor: CGRect, keyDiameter: CGFloat, spacing: CGFloat, bounds: CGRect): WheelPaletteLayout? {
        if (!(count > 0 && keyDiameter > 0)) return null
        // Generous wedges: deeper than a key, and at least a key and a bit
        // wide at mid-ring, so a thumb hits them reliably.
        val thickness = keyDiameter * 1.5
        var inner = max(anchor.width, anchor.height) / 2 + spacing
        val minimumMid = count.toDouble() * keyDiameter * 1.15 / (2 * PI)
        inner = max(max(inner, minimumMid - thickness / 2), keyDiameter * 0.6)
        val outer = inner + thickness
        var centerX = anchor.midX
        var centerY = anchor.midY
        if (!bounds.isInfinite && bounds.width >= outer * 2 && bounds.height >= outer * 2) {
            centerX = min(max(centerX, bounds.minX + outer), bounds.maxX - outer)
            centerY = min(max(centerY, bounds.minY + outer), bounds.maxY - outer)
        }
        val center = CGPoint(centerX, centerY)
        val sweep = 2 * PI / count.toDouble()
        val first = -PI / 2 - sweep / 2
        val middle = (inner + outer) / 2
        val segments = (0 until count).map { index ->
            val start = first + index.toDouble() * sweep
            val mid = start + sweep / 2
            WheelPaletteLayout.Segment(
                startAngle = start, endAngle = start + sweep,
                labelPoint = CGPoint(x = center.x + middle * cos(mid), y = center.y + middle * sin(mid)),
            )
        }
        return WheelPaletteLayout(center, inner, outer, segments)
    }
}

// endregion

// region Editor Two-Hand Assist

/**
 * Two-Hand Assist in the editor stays dormant while arranging: moving or
 * selecting a modifier never triggers it. Only Preview runs the real
 * projection; "Preview Two-Hand Assist" in Edit shows its helper arc statically.
 */
object EditorTwoHandPresentation {
    fun state(previewing: Boolean, showingAssistPreview: Boolean, enabled: Boolean, interaction: ControlInteractionState): TwoHandAssistState {
        if (!enabled) return TwoHandAssistState.Hidden
        if (previewing) return TwoHandAssist.state(enabled = true, interaction = interaction)
        return if (showingAssistPreview) TwoHandAssistState.Helper(setOf(ControlModifier.Command)) else TwoHandAssistState.Hidden
    }
}

// endregion
