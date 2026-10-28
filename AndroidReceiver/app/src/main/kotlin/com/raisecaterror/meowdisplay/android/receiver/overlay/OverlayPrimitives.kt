package com.raisecaterror.meowdisplay.android.receiver.overlay

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.absoluteOffset
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.raisecaterror.meowdisplay.core.controls.CGRect
import com.raisecaterror.meowdisplay.core.controls.ControlEdge
import com.raisecaterror.meowdisplay.core.controls.PadStrip
import com.raisecaterror.meowdisplay.core.controls.ShortcutItem
import kotlin.math.max
import kotlin.math.min

// The visual primitives (spec section 1). There is no blur on Android under a SurfaceView, so
// iOS's `.ultraThinMaterial` is emulated with flat translucent fills chosen to match its
// perceived brightness over live video:
//   * phone chip: black 30% scrim + white 12% (idle), white 90% (latched);
//   * ControlTray / Move View banner / HUD: dark translucent fills (black 55%, 88% for the banner).
// Everything else (PadChip, strips, wheel) is already flat on iOS and is reproduced exactly.

/** Fonts do not follow Dynamic Type on iOS for chip glyphs; `Dp.toSp()` cancels the user's font scale the same way. */
@Composable
internal fun fixedSp(dp: Double) = with(LocalDensity.current) { dp.toFloat().dp.toSp() }

private val Rounded = FontFamily.SansSerif

private fun Modifier.at(rect: CGRect) = absoluteOffset(rect.minX.dp, rect.minY.dp).size(rect.width.dp, rect.height.dp)

@Composable
private fun chipModifier(style: ChipStyle, selected: Boolean): Modifier {
    return when (style) {
        ChipStyle.Phone -> Modifier
            .shadow(2.dp, CircleShape, clip = false, ambientColor = Color.Black.copy(0.28f), spotColor = Color.Black.copy(0.28f))
            .then(
                if (selected) Modifier.background(Color.White.copy(alpha = 0.90f), CircleShape)
                else Modifier.background(Color.Black.copy(alpha = 0.30f), CircleShape).background(Color.White.copy(alpha = 0.12f), CircleShape),
            )
            .border(0.5.dp, Color.White.copy(alpha = if (selected) 0.55f else 0.28f), CircleShape)
        ChipStyle.Rail -> Modifier
            .background(if (selected) Color.White.copy(0.92f) else Color.White.copy(0.12f), CircleShape)
            .border(0.75.dp, Color.White.copy(alpha = if (selected) 0.5f else 0.08f), CircleShape)
        ChipStyle.Floating -> Modifier
            .shadow(3.dp, CircleShape, clip = false, ambientColor = Color.Black.copy(0.22f), spotColor = Color.Black.copy(0.22f))
            .background(if (selected) Color.White.copy(0.92f) else Color(0.2f, 0.2f, 0.2f, 0.88f), CircleShape)
            .border(0.75.dp, Color.White.copy(alpha = if (selected) 0.5f else 0.16f), CircleShape)
    }
}

@Composable
internal fun FaceContent(face: ChipFace, color: Color, boxWidth: Double) {
    when (face) {
        is ChipFace.Glyph -> GlyphIcon(face.glyph, face.size.toFloat().dp, color)
        is ChipFace.Label -> if (face.shrinks) FitText(face, color, boxWidth) else Text(
            face.text, color = color, fontSize = fixedSp(face.size), fontWeight = FontWeight.SemiBold,
            fontFamily = if (face.rounded) Rounded else FontFamily.Default, maxLines = 1, softWrap = false,
        )
    }
}

/** One line that shrinks (down to 50%) to fit, like `minimumScaleFactor(0.5)`. */
@Composable
private fun FitText(face: ChipFace.Label, color: Color, boxWidth: Double) {
    val density = LocalDensity.current
    val available = with(density) { (boxWidth * 0.84).toFloat().dp.toPx() }
    var scale by remember(face.text, face.size) { mutableFloatStateOf(1f) }
    Text(
        face.text, color = color, fontSize = fixedSp(face.size), fontWeight = FontWeight.SemiBold,
        fontFamily = Rounded, maxLines = 1, softWrap = false, textAlign = TextAlign.Center,
        onTextLayout = { layout ->
            val w = layout.size.width.toFloat()
            if (w > available && scale == 1f) scale = max(0.5f, available / w)
        },
        modifier = Modifier.graphicsLayer { scaleX = scale; scaleY = scale },
    )
}

/** The enter transition of palette content: scale from [from] (0 = from nothing) and fade in, once, on first composition. */
@Composable
internal fun enterProgress(animate: Boolean): State<Float> {
    val progress = remember { Animatable(if (animate) 0f else 1f) }
    LaunchedEffect(Unit) { if (animate) progress.animateTo(1f, tween(200)) }
    return progress.asState()
}

/** One drawn control chip. [hide] is the auto-hide progress (0 shown ... 1 hidden). */
@Composable
internal fun ChipView(
    spec: ChipSpec,
    hide: Float,
    reduceMotion: Boolean,
    retreat: Offset,
    hidden: Boolean,
    onActivate: (Activation) -> Unit,
) {
    val density = LocalDensity.current
    val color = if (spec.selected) Color.Black else Color.White
    val d = spec.frame.width
    var modifier = Modifier.at(spec.frame)
    if (spec.hide != HideKind.None && hide > 0f) {
        modifier = modifier.graphicsLayer {
            alpha = 1f - hide
            if (spec.hide == HideKind.Retreat && !reduceMotion) {
                val scale = 1f - 0.02f * hide
                scaleX = scale
                scaleY = scale
                translationX = retreat.x * density.density * hide
                translationY = retreat.y * density.density * hide
            }
        }
    }
    val blocked = hidden && spec.hide != HideKind.None
    modifier = modifier.then(chipModifier(spec.style, spec.selected))
    modifier = if (spec.ownTap && !blocked) {
        modifier.clickable(
            interactionSource = remember { MutableInteractionSource() }, indication = null,
            role = Role.Button, onClickLabel = spec.label,
        ) { onActivate(spec.activation) }
    } else modifier
    modifier = modifier.semantics(mergeDescendants = true) {
        contentDescription = spec.label
        spec.stateText?.let { stateDescription = it }
        role = Role.Button
        if (!spec.ownTap) onClick(label = null) { onActivate(spec.activation); true }
    }
    Box(modifier, contentAlignment = Alignment.Center) { FaceContent(spec.face, color, d) }
    spec.hint?.let { hint ->
        val caption = CGRect(spec.frame.midX - (d + 18) / 2, spec.frame.maxY + 2, d + 18, 12.0)
        Box(
            Modifier.at(caption).graphicsLayer { alpha = if (spec.hide == HideKind.None) 1f else 1f - hide }
                .semantics { contentDescription = "" },
            contentAlignment = Alignment.Center,
        ) {
            FitHint(hint)
        }
    }
}

@Composable
private fun FitHint(text: String) {
    var scale by remember(text) { mutableFloatStateOf(1f) }
    val available = with(LocalDensity.current) { 56.dp.toPx() }
    Text(
        text, color = Color.White.copy(0.7f), fontSize = fixedSp(10.0), fontWeight = FontWeight.Medium, maxLines = 1, softWrap = false,
        onTextLayout = { layout ->
            val w = layout.size.width.toFloat()
            if (w > available && scale == 1f) scale = max(0.7f, available / w)
        },
        modifier = Modifier.graphicsLayer { scaleX = scale; scaleY = scale },
    )
}

/** RC `ControlTray`: a fully rounded dark pill with a hairline. */
@Composable
internal fun ControlTrayView(spec: TraySpec, hide: Float, scaleIn: Float = 1f) {
    val shape = RoundedCornerShape(50)
    Box(
        Modifier.at(spec.rect)
            .graphicsLayer { alpha = (if (spec.hideable) 1f - hide else 1f) * scaleIn }
            .shadow(6.dp, shape, clip = false, ambientColor = Color.Black.copy(0.25f), spotColor = Color.Black.copy(0.25f))
            .background(Color.Black.copy(alpha = 0.55f), shape)
            .border(0.75.dp, Color.White.copy(0.12f), shape),
    )
}

@Composable
internal fun PaletteKeyView(key: PaletteKeySpec, enterScale: Float, animate: Boolean, onActivate: () -> Unit) {
    val enter by enterProgress(animate)
    val pop by animateFloatAsState(if (key.selected) (if (key.pill) 1.05f else 1.12f) else 1f, tween(140), label = "key")
    val color = if (key.selected) Color.Black else Color.White
    val scale = (enterScale + (1f - enterScale) * enter) * pop
    val common = Modifier.at(key.frame)
        .graphicsLayer { alpha = enter; scaleX = scale; scaleY = scale }
    val semantics: Modifier.() -> Modifier = {
        semantics(mergeDescendants = true) {
            contentDescription = key.action.title
            role = Role.Button
            onClick(label = null) { onActivate(); true }
        }
    }
    if (key.pill) {
        val shape = RoundedCornerShape(50)
        Row(
            common.semantics().background(if (key.selected) Color.White.copy(0.92f) else Color.Black.copy(0.55f), shape)
                .border(0.75.dp, Color.White.copy(if (key.selected) 0.5f else 0.2f), shape).padding(horizontal = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                key.action.displayKey, color = color, fontSize = fixedSp(14.0), fontWeight = FontWeight.SemiBold,
                fontFamily = Rounded, maxLines = 1, softWrap = false, modifier = Modifier.width(22.dp),
            )
            Text(
                key.action.title, color = color, fontSize = fixedSp(13.0), fontWeight = FontWeight.Medium,
                maxLines = 1, softWrap = false,
            )
        }
    } else {
        Box(common.semantics().then(chipModifier(key.style, key.selected)), contentAlignment = Alignment.Center) {
            FaceContent(OverlayScenes.faceFor(key.action.face, key.frame.width), color, key.frame.width)
        }
    }
}

/** Places [content] centered on (cx, cy) dp in the overlay. */
@Composable
internal fun CenteredAt(cx: Double, cy: Double, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val density = LocalDensity.current
    Layout(content = content, modifier = modifier) { measurables, constraints ->
        val placeables = measurables.map { it.measure(Constraints()) }
        val w = placeables.maxOfOrNull { it.width } ?: 0
        val h = placeables.maxOfOrNull { it.height } ?: 0
        // The layout takes no space of its own: it sits at the overlay origin and the child is placed by offset.
        layout(constraints.maxWidth, constraints.maxHeight) {
            val x = (cx * density.density - w / 2).toInt()
            val y = (cy * density.density - h / 2).toInt()
            placeables.forEach { it.place(x, y) }
        }
    }
}

@Composable
internal fun HudView(hud: HudSpec, animate: Boolean) {
    val enter by enterProgress(animate)
    CenteredAt(hud.cx, hud.cy) {
        val shape = RoundedCornerShape(50)
        Text(
            hud.text, color = Color.White, fontSize = fixedSp(16.0), fontWeight = FontWeight.SemiBold, fontFamily = Rounded,
            modifier = Modifier
                .graphicsLayer { alpha = enter; scaleX = enter; scaleY = enter }
                .shadow(4.dp, shape, clip = false, ambientColor = Color.Black.copy(0.3f), spotColor = Color.Black.copy(0.3f))
                .background(Color.Black.copy(0.50f), shape)
                .border(0.5.dp, Color.White.copy(0.3f), shape)
                .padding(horizontal = 13.dp, vertical = 7.dp),
        )
    }
}

@Composable
internal fun EmptyLabelView(label: EmptyLabelSpec) {
    CenteredAt(label.cx, label.cy) {
        val shape = RoundedCornerShape(50)
        val base = if (label.onMaterial) {
            Modifier.shadow(2.dp, shape, clip = false, ambientColor = Color.Black.copy(0.28f), spotColor = Color.Black.copy(0.28f))
                .background(Color.Black.copy(0.30f), shape).background(Color.White.copy(0.10f), shape)
                .border(0.5.dp, Color.White.copy(0.28f), shape)
        } else {
            Modifier.background(Color.Black.copy(0.6f), shape).border(0.5.dp, Color.White.copy(0.22f), shape)
        }
        Text(
            label.text, color = Color.White.copy(if (label.onMaterial) 0.85f else 0.9f),
            fontSize = 12.sp, maxLines = 1, softWrap = false, modifier = base.padding(horizontal = 12.dp, vertical = 7.dp),
        )
    }
}

/** RC `PadStripBackground`: solid black with a hairline on the edge that faces the canvas. */
@Composable
internal fun StripView(strip: PadStrip) {
    Box(Modifier.at(strip.frame).background(Color.Black)) {
        val hair = Modifier.background(Color.White.copy(0.08f))
        when (strip.edge) {
            ControlEdge.Leading -> Box(hair.align(Alignment.CenterEnd).width(0.5.dp).fillMaxHeight())
            ControlEdge.Trailing -> Box(hair.align(Alignment.CenterStart).width(0.5.dp).fillMaxHeight())
            ControlEdge.Top -> Box(hair.align(Alignment.BottomCenter).height(0.5.dp).fillMaxWidth())
            ControlEdge.Bottom -> Box(hair.align(Alignment.TopCenter).height(0.5.dp).fillMaxWidth())
        }
    }
}

/** RC `WheelPaletteView`: wedges, faces and the center disc; touches are the gesture layer's. */
@Composable
internal fun WheelView(wheel: WheelSpec, enterScale: Float, animate: Boolean, onActivate: (ShortcutItem) -> Unit) {
    val enter by enterProgress(animate)
    val density = LocalDensity.current
    val accent = MaterialTheme.colorScheme.primary
    val layout = wheel.layout
    val scale = enterScale + (1f - enterScale) * enter
    val origin = Offset(layout.center.x.toFloat(), layout.center.y.toFloat())
    Box(Modifier.fillMaxSize().graphicsLayer {
        alpha = enter; scaleX = scale; scaleY = scale
        transformOrigin = androidx.compose.ui.graphics.TransformOrigin(
            (origin.x * density.density) / size.width.coerceAtLeast(1f), (origin.y * density.density) / size.height.coerceAtLeast(1f),
        )
    }) {
        Canvas(Modifier.fillMaxSize()) {
            val k = density.density
            val c = Offset(layout.center.x.toFloat() * k, layout.center.y.toFloat() * k)
            val inner = layout.innerRadius.toFloat() * k
            val outer = layout.outerRadius.toFloat() * k
            // A soft halo stands in for the SwiftUI shadow.
            drawCircle(Color.Black.copy(0.12f), outer + 3f * k, c)
            wheel.actions.forEachIndexed { index, action ->
                val seg = layout.segments.getOrNull(index) ?: return@forEachIndexed
                val selected = action.id == wheel.selectedID
                val inset = min(0.04, (seg.endAngle - seg.startAngle) * 0.08)
                val start = Math.toDegrees(seg.startAngle + inset).toFloat()
                val sweep = Math.toDegrees(seg.endAngle - seg.startAngle - 2 * inset).toFloat()
                val path = Path().apply {
                    arcTo(Rect(c.x - outer, c.y - outer, c.x + outer, c.y + outer), start, sweep, true)
                    arcTo(Rect(c.x - inner, c.y - inner, c.x + inner, c.y + inner), start + sweep, -sweep, false)
                    close()
                }
                drawPath(path, if (selected) Color.White.copy(0.92f) else Color(0.18f, 0.18f, 0.18f, 0.9f))
                drawPath(path, if (selected) accent else Color.White.copy(0.14f), style = Stroke(width = (if (selected) 2f else 0.75f) * k))
            }
            val hole = (layout.innerRadius.toFloat() - 4f) * k
            drawCircle(Color(0.12f, 0.12f, 0.12f, 0.92f), hole, c)
            drawCircle(Color.White.copy(0.14f), hole, c, style = Stroke(0.75f * k))
        }
        val thickness = layout.outerRadius - layout.innerRadius
        wheel.actions.forEachIndexed { index, action ->
            val seg = layout.segments.getOrNull(index) ?: return@forEachIndexed
            val selected = action.id == wheel.selectedID
            val frame = CGRect(seg.labelPoint.x - thickness / 2, seg.labelPoint.y - thickness / 2, thickness, thickness)
            val face = OverlayScenes.faceFor(action.face, min(thickness, 52.0))
            Box(
                Modifier.at(frame)
                    .graphicsLayer { val s = if (selected) 1.12f else 1f; scaleX = s; scaleY = s }
                    .semantics(mergeDescendants = true) {
                        contentDescription = action.title
                        role = Role.Button
                        onClick(label = null) { onActivate(action); true }
                    },
                contentAlignment = Alignment.Center,
            ) { FaceContent(face, if (selected) Color.Black else Color.White, min(thickness, 52.0)) }
        }
        CenteredAt(layout.center.x, layout.center.y) {
            Text(wheel.centerLabel, color = Color.White, fontSize = fixedSp(17.0), fontWeight = FontWeight.SemiBold, maxLines = 1, softWrap = false)
        }
    }
}

/** RC `moveViewBanner`: the mode says so while it's on, with a way back. */
@Composable
internal fun MoveViewBanner(cx: Double, cy: Double, onReset: () -> Unit, onDone: () -> Unit) {
    val enter by enterProgress(true)
    CenteredAt(cx, cy) {
        val shape = RoundedCornerShape(50)
        val accent = Color(0xFF0A84FF)
        Row(
            Modifier
                .graphicsLayer { alpha = enter; translationY = -(1f - enter) * 40f }
                .shadow(8.dp, shape, clip = false, ambientColor = Color.Black.copy(0.25f), spotColor = Color.Black.copy(0.25f))
                .background(Color(0xF01C1C1E), shape)
                .border(0.5.dp, Color.White.copy(0.12f), shape)
                .padding(horizontal = 16.dp, vertical = 9.dp)
                .semantics(mergeDescendants = false) { },
            horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically,
        ) {
            GlyphIcon(OverlayGlyph.Move, 16.dp, Color.White)
            Text("Move View", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
            Box(Modifier.width(0.5.dp).height(18.dp).background(Color.White.copy(0.3f)))
            Text(
                "Reset", color = accent, fontSize = 15.sp, maxLines = 1,
                modifier = Modifier.clickable(role = Role.Button, onClick = onReset).padding(vertical = 8.dp),
            )
            Text(
                "Done", color = accent, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
                modifier = Modifier.clickable(role = Role.Button, onClick = onDone).padding(vertical = 8.dp),
            )
        }
    }
}

