package com.raisecaterror.meowdisplay.core.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteMacStoreTest {
    private val storage = InMemoryRemoteMacStorage()
    private val mac = RemoteEndpoint("mac.tailnet.ts.net", 9003)

    private fun reload() = RemoteMacStore(storage)

    @Test
    fun noPriorDataIsAnEmptyList() {
        assertTrue(RemoteMacStore(InMemoryRemoteMacStorage()).macs.value.isEmpty())
        assertTrue(RemoteMacStore(InMemoryRemoteMacStorage("")).macs.value.isEmpty())
    }

    @Test
    fun addEditAndRemoveKeepOneAddressPerMac() {
        val store = RemoteMacStore(storage)
        assertTrue(store.save("A", mac))
        assertEquals(mac, store.endpoint("A"))
        assertTrue(store.save("A", RemoteEndpoint("100.64.0.9", 9010)))
        assertEquals("an edit replaces; it never adds a second address", 1, store.macs.value.size)
        assertEquals(RemoteEndpoint("100.64.0.9", 9010), store.endpoint("A"))
        assertTrue(store.remove("A"))
        assertNull(store.endpoint("A"))
        assertTrue("removing what isn't there is fine", store.remove("A"))
    }

    @Test
    fun theSameAddressForASecondMacIsAllowedAndShown() {
        val store = RemoteMacStore(storage)
        store.save("A", mac)
        store.save("B", RemoteEndpoint("MAC.tailnet.ts.net", 9003))
        store.save("C", RemoteEndpoint("mac.tailnet.ts.net", 9010))
        assertEquals(listOf("B"), store.sharedWith("A"))
        assertEquals(listOf("A"), store.sharedWith("B"))
        assertEquals("another port is another address", emptyList<String>(), store.sharedWith("C"))
        assertEquals(mac, store.endpoint("A"))
    }

    @Test
    fun forgetTakesTheAddressAndLeavesOtherMacsAlone() {
        val store = RemoteMacStore(storage)
        store.save("A", mac)
        store.save("B", RemoteEndpoint("100.64.0.2", 9003))
        store.forget("A")
        assertNull(store.endpoint("A"))
        assertEquals(RemoteEndpoint("100.64.0.2", 9003), store.endpoint("B"))
        assertNull("gone after a restart too", reload().endpoint("A"))
    }

    @Test
    fun addressesSurviveARestart() {
        val store = RemoteMacStore(storage)
        store.save("A", mac)
        store.save("B", RemoteEndpoint("fd7a:115c:a1e0::2", 9010))
        val again = reload()
        assertEquals(mac, again.endpoint("A"))
        assertEquals(RemoteEndpoint("fd7a:115c:a1e0::2", 9010), again.endpoint("B"))
    }

    @Test
    fun anUnknownSchemaIsDiscardedNotGuessedAt() {
        storage.text = """{"A":{"version":2,"host":"mac.ts.net","port":9003},
            "B":{"version":1,"host":"ok.ts.net","port":9003},
            "C":{"host":"nover.ts.net","port":9003},
            "D":{"version":1,"host":"bad host","port":9003},
            "E":{"version":1,"host":"mac.ts.net","port":0},
            "F":{"version":1,"host":"mac.ts.net"},
            "G":"text","H":{"version":"1","host":"x","port":9003}}"""
        val store = reload()
        assertEquals(setOf("B"), store.macs.value.keys)
        storage.text = "not json at all {"
        assertTrue(reload().macs.value.isEmpty())
        storage.text = "[1,2]"
        assertTrue(reload().macs.value.isEmpty())
    }

    @Test
    fun aFailedWriteChangesNothing() {
        val store = RemoteMacStore(storage)
        store.save("A", mac)
        storage.failWrites = true
        assertFalse(store.save("A", RemoteEndpoint("100.64.0.9", 9003)))
        assertFalse(store.remove("A"))
        assertEquals(mac, store.endpoint("A"))
        assertEquals(mac, reload().endpoint("A"))
    }

    @Test
    fun addressesOfMacsThatAreNoLongerPairedAreDropped() {
        val store = RemoteMacStore(storage)
        store.save("A", mac)
        store.save("B", RemoteEndpoint("100.64.0.2", 9003))
        store.retainOnly(setOf("B"))
        assertEquals(setOf("B"), reload().macs.value.keys)
    }

    @Test
    fun theAddressIsOnlyAHintKeyedByPeerIDNeverByAddress() {
        val store = RemoteMacStore(storage)
        store.save("A", mac)
        assertNull(store.endpoint("mac.tailnet.ts.net"))
        assertFalse("an empty peer ID has no address", store.save("", mac))
    }
}
