package com.raisecaterror.meowdisplay.core.workspace

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LockMacWireTest {
    @Test fun requestMatchesTheMac() {
        assertEquals("""{"type":"lockMac","req":3}""", LockMacWire.request(3).toString())
    }

    @Test fun parsesEveryResultAndRejectsUnknown() {
        for (r in LockMacResult.entries) assertEquals(r, LockMacResult.parse(buildJsonObject { put("type", LockMacWire.RESULT); put("result", r.wire) }))
        assertNull(LockMacResult.parse(buildJsonObject { put("result", "unlocked") }))
        assertNull(LockMacResult.parse(buildJsonObject { put("result", 1) }))
    }
}
