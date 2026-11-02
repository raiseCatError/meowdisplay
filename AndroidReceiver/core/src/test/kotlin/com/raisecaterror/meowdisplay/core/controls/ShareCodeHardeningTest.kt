package com.raisecaterror.meowdisplay.core.controls

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.MessageDigest
import java.util.Base64
import java.util.zip.Deflater

/** A share code is untrusted: an imported button can't borrow a built-in's identity or store an outsized face. */
class ShareCodeHardeningTest {
    private fun code(payload: CustomLayoutShareCode.Payload): String {
        val json = SwiftJsonWriter.write(payload.toJson()).toByteArray(Charsets.UTF_8)
        val deflater = Deflater(5, true).apply { setInput(json); finish() }
        val buffer = ByteArray(64 * 1024)
        val compressed = buffer.copyOf(deflater.deflate(buffer))
        val checksum = MessageDigest.getInstance("SHA-256").digest(json).take(4).joinToString("") { "%02x".format(it.toInt() and 0xFF) }
        return "MDL1-" + Base64.getUrlEncoder().withoutPadding().encodeToString(compressed) + "." + checksum
    }

    @Test
    fun aCarriedActionCannotImpersonateABuiltInAndFacesAreBounded() {
        val forceQuit = ControlAction.KeyboardShortcutAction(KeyboardShortcut(41, ModifierChord(ControlModifier.Command, ControlModifier.Option)))
        val placements = listOf(
            CustomControlPlacement(id = "p1", kind = CustomControlKind.Function("undo"), x = 0.5, y = 0.5, size = 1.0, palette = null),
            CustomControlPlacement(id = "p2", kind = CustomControlKind.Function("mine"), x = 0.4, y = 0.5, size = 1.0, palette = null),
        )
        val arrangement = CustomControlArrangement(ControlCorner.BottomTrailing, placements)
        val payload = CustomLayoutShareCode.Payload(
            name = "Shared", landscape = arrangement, portrait = arrangement, twoHandAssist = false, assistActionIDs = emptyList(),
            functionActions = listOf(
                ShortcutItem("undo", "Undo", "Z", forceQuit, "arrow.uturn.backward", null),
                ShortcutItem("mine", "Mine", "M", forceQuit, null, ShortcutButtonDisplay.Text("A".repeat(5000))),
            ),
        )
        val result = CustomLayoutShareCode.decode(code(payload))
        assertTrue(result is ShareCodeResult.Success)
        val layout = (result as ShareCodeResult.Success).summary.layout
        val kinds = layout.landscape.placements.map { it.kind }
        assertEquals("the built-in id keeps meaning the local Undo", CustomControlKind.Function("undo"), kinds[0])
        val carried = (kinds[1] as CustomControlKind.Shortcut).item
        assertEquals(ShortcutButtonDisplay.Text("AAAA"), carried.display)
        assertEquals("⌘⌥Escape", carried.keysDescription)
    }
}
