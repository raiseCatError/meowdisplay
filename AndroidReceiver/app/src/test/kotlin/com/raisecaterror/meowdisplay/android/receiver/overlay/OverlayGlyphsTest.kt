package com.raisecaterror.meowdisplay.android.receiver.overlay

import com.raisecaterror.meowdisplay.core.controls.ControlTrayItem
import com.raisecaterror.meowdisplay.core.controls.FunctionTrayProfile
import com.raisecaterror.meowdisplay.core.controls.ShortcutButtonFace
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class OverlayGlyphsTest {
    @Test
    fun everySymbolTheSpecListsHasAGlyph() {
        val names = listOf(
            "gearshape.fill", "keyboard", "dock.rectangle", "keyboard.chevron.compact.down", "return",
            "arrow.up.and.down.and.arrow.left.and.right", "plus.magnifyingglass", "minus.magnifyingglass",
            "arrow.uturn.backward", "arrow.uturn.forward", "menubar.rectangle", "square.grid.3x3", "rectangle.dashed",
            "switch.2", "sparkles", "star", "bolt", "paintbrush", "pencil", "scissors", "textformat", "underline", "bold",
            "italic", "folder", "magnifyingglass", "play", "arrow.clockwise", "camera", "square.and.arrow.down",
            "wand.and.stars", "command", "hammer", "hand.tap",
        )
        for (name in names) assertNotEquals("$name has no glyph", OverlayGlyph.Unknown, OverlayGlyphs.forSymbol(name))
    }

    @Test
    fun unknownNamesFallBackToTheRingGlyph() {
        assertEquals(OverlayGlyph.Unknown, OverlayGlyphs.forSymbol("no.such.symbol"))
    }

    @Test
    fun theTrayItemsAndDefaultFunctionButtonsAllResolve() {
        for (item in listOf(ControlTrayItem.Dock, ControlTrayItem.Keyboard, ControlTrayItem.Settings)) {
            assertNotEquals(OverlayGlyph.Unknown, OverlayGlyphs.forSymbol(item.displayLabel))
        }
        for (button in FunctionTrayProfile.canonical().allItems) {
            val face = button.face
            if (face is ShortcutButtonFace.Symbol) assertNotEquals("${button.id} -> ${face.name}", OverlayGlyph.Unknown, OverlayGlyphs.forSymbol(face.name))
        }
    }
}
