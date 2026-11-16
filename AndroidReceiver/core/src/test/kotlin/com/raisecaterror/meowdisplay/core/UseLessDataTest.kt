package com.raisecaterror.meowdisplay.core

import com.raisecaterror.meowdisplay.core.session.HelloFields
import com.raisecaterror.meowdisplay.core.session.InMemorySessionPolicyStore
import com.raisecaterror.meowdisplay.core.session.MediaLink
import com.raisecaterror.meowdisplay.core.session.NetworkCostHint
import com.raisecaterror.meowdisplay.core.session.NetworkCostMapper
import com.raisecaterror.meowdisplay.core.session.PathConfidence
import com.raisecaterror.meowdisplay.core.session.PathCost
import com.raisecaterror.meowdisplay.core.session.PathCostFlags
import com.raisecaterror.meowdisplay.core.session.PathInterface
import com.raisecaterror.meowdisplay.core.session.ReceiverMessages
import com.raisecaterror.meowdisplay.core.session.PathCostTable
import com.raisecaterror.meowdisplay.core.session.ReceiverSession
import com.raisecaterror.meowdisplay.core.session.TrackedPath
import com.raisecaterror.meowdisplay.core.session.UseLessData
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** "Use less data" (#123, PROTOCOL.md 6.20): the cost-hint mapper, the hello keys and the re-announce. */
class UseLessDataTest {
    private fun hint(
        flags: PathCostFlags, dataSaver: Boolean = false, ownPath: Boolean = true,
    ) = NetworkCostMapper.hint(flags, dataSaver, ownPath)

    private fun expect(cost: PathCost, confidence: PathConfidence, iface: PathInterface) = NetworkCostHint(cost, confidence, iface)

    // MARK: - Mapper truth table

    @Test
    fun cellularIsMeteredAndDataSaverMakesItConstrained() {
        val cellular = PathCostFlags(cellular = true)
        assertEquals(expect(PathCost.Expensive, PathConfidence.High, PathInterface.Cellular), hint(cellular))
        assertEquals(expect(PathCost.Constrained, PathConfidence.High, PathInterface.Cellular), hint(cellular, dataSaver = true))
    }

    @Test
    fun unmeteredWifiIsUnmeteredEvenWithDataSaver() {
        val wifi = PathCostFlags(wifi = true, notMetered = true)
        assertEquals(expect(PathCost.Unmetered, PathConfidence.High, PathInterface.WiFi), hint(wifi))
        assertEquals("Data Saver only restricts metered networks", expect(PathCost.Unmetered, PathConfidence.High, PathInterface.WiFi), hint(wifi, dataSaver = true))
    }

    @Test
    fun aHotspotIsWifiThatIsMetered() {
        val hotspot = PathCostFlags(wifi = true, notMetered = false)
        assertEquals(expect(PathCost.Expensive, PathConfidence.High, PathInterface.WiFi), hint(hotspot))
        assertEquals(expect(PathCost.Constrained, PathConfidence.High, PathInterface.WiFi), hint(hotspot, dataSaver = true))
    }

    @Test
    fun ethernetIsWiredAndUnmetered() {
        val wired = PathCostFlags(ethernet = true, notMetered = true)
        assertEquals(expect(PathCost.Unmetered, PathConfidence.High, PathInterface.Wired), hint(wired))
        assertEquals(expect(PathCost.Expensive, PathConfidence.High, PathInterface.Wired), hint(PathCostFlags(ethernet = true)))
    }

    @Test
    fun aVpnOverCellularIsATunnelNeverCellular() {
        // A VPN network usually reports the transport it rides on as well.
        val vpnOverCellular = PathCostFlags(cellular = true, vpn = true)
        val plain = hint(vpnOverCellular)
        assertEquals(PathInterface.Tunnel, plain?.iface)
        assertEquals(expect(PathCost.Expensive, PathConfidence.Medium, PathInterface.Tunnel), plain)
        val saver = hint(vpnOverCellular, dataSaver = true)
        assertEquals(expect(PathCost.Constrained, PathConfidence.Medium, PathInterface.Tunnel), saver)
        for (flags in listOf(vpnOverCellular, vpnOverCellular.copy(notMetered = true), vpnOverCellular.copy(wifi = true))) {
            for (dataSaver in listOf(false, true)) {
                assertNotEquals(PathInterface.Cellular, hint(flags, dataSaver)?.iface)
            }
        }
    }

    @Test
    fun notMeteredSeenThroughAVpnIsUnknownAndOmitted() {
        val vpnOverWifi = PathCostFlags(wifi = true, vpn = true, notMetered = true)
        assertNull("not metered through a tunnel says nothing", hint(vpnOverWifi))
        assertNull(hint(PathCostFlags(vpn = true, notMetered = true)))
        assertEquals(
            "Data Saver is the person's own setting, whatever the tunnel hides",
            expect(PathCost.Constrained, PathConfidence.Medium, PathInterface.Tunnel), hint(vpnOverWifi, dataSaver = true),
        )
    }

    @Test
    fun anUnknownNetworkStaysUnknown() {
        assertNull(hint(PathCostFlags()))
        assertNull("metered alone is no evidence on a network of no known kind", hint(PathCostFlags(notMetered = false)))
        assertNull(hint(PathCostFlags(notMetered = true)))
        assertEquals(expect(PathCost.Constrained, PathConfidence.Medium, PathInterface.Unknown), hint(PathCostFlags(), dataSaver = true))
    }

    @Test
    fun aDefaultNetworkGuessIsNeverHighConfidence() {
        assertEquals(
            expect(PathCost.Unmetered, PathConfidence.Medium, PathInterface.WiFi),
            hint(PathCostFlags(wifi = true, notMetered = true), ownPath = false),
        )
        assertEquals(
            expect(PathCost.Expensive, PathConfidence.Medium, PathInterface.Tunnel),
            hint(PathCostFlags(vpn = true), ownPath = false),
        )
    }

    @Test
    fun cellularWinsOverWifiWhenBothAreReported() {
        assertEquals(PathInterface.Cellular, hint(PathCostFlags(cellular = true, wifi = true))?.iface)
    }

    // MARK: - Which network a connection runs over, and pausing the monitor

    private val wifiAddress = byteArrayOf(10, 0, 0, 5)
    private val cellularAddress = byteArrayOf(100, 64, 1, 2)
    private val hotspotAddress = byteArrayOf(192.toByte(), 168.toByte(), 43, 1)
    private val wifiPath = TrackedPath(listOf(wifiAddress), PathCostFlags(wifi = true, notMetered = true))
    private val cellularPath = TrackedPath(listOf(cellularAddress), PathCostFlags(cellular = true))
    private val wifiHint = expect(PathCost.Unmetered, PathConfidence.High, PathInterface.WiFi)

    private fun tableWithWifiAndCellular() = PathCostTable<String>().apply {
        update("wifi", wifiPath)
        update("cell", cellularPath)
        setDefault("cell")
    }

    @Test
    fun theNetworkThatOwnsTheLocalAddressIsTheConnectionsOwnPath() {
        val table = tableWithWifiAndCellular()
        assertEquals(wifiHint, table.hint(wifiAddress, dataSaver = false))
        assertEquals(expect(PathCost.Expensive, PathConfidence.High, PathInterface.Cellular), table.hint(cellularAddress, dataSaver = false))
    }

    @Test
    fun anUnknownLocalAddressFallsBackToTheDefaultNetworkAtMediumConfidence() {
        assertEquals(
            expect(PathCost.Expensive, PathConfidence.Medium, PathInterface.Cellular),
            tableWithWifiAndCellular().hint(null, dataSaver = false),
        )
    }

    @Test
    fun aKnownLocalAddressThatMatchesNoNetworkIsUnknownNotTheDefaultNetwork() {
        // The phone's own hotspot, a USB tether or Wi-Fi Direct is no tracked network: never call it cellular.
        val table = tableWithWifiAndCellular()
        assertNull(table.hint(hotspotAddress, dataSaver = false))
        assertNull(table.hint(hotspotAddress, dataSaver = true))
        assertNull(
            NetworkCostMapper.hintFor(hotspotAddress, mapOf("cell" to cellularPath), defaultNetwork = "cell", dataSaver = true),
        )
    }

    @Test
    fun noDefaultNetworkAndNoLocalAddressIsUnknown() {
        assertNull(PathCostTable<String>().hint(null, dataSaver = false))
        assertNull(PathCostTable<String>().apply { update("wifi", wifiPath) }.hint(null, dataSaver = false))
    }

    @Test
    fun pausingTheMonitorKeepsTheLastKnownHint() {
        val table = tableWithWifiAndCellular()
        table.pause()
        assertEquals("paused is not unknown", wifiHint, table.hint(wifiAddress, dataSaver = false))
        assertEquals(
            expect(PathCost.Expensive, PathConfidence.Medium, PathInterface.Cellular),
            table.hint(null, dataSaver = false),
        )
    }

    @Test
    fun theFirstFreshCallbackAfterARestartReplacesEverythingKept() {
        val table = tableWithWifiAndCellular()
        table.pause()
        // The restart replays only the networks that still exist: Wi-Fi is gone, a new one appeared.
        val newWifiAddress = byteArrayOf(172.toByte(), 16, 0, 9)
        table.update("wifi2", TrackedPath(listOf(newWifiAddress), PathCostFlags(wifi = true, notMetered = true)))
        assertNull("the old Wi-Fi must not survive a real network change", table.hint(wifiAddress, dataSaver = false))
        assertNull("nor the old default", table.hint(null, dataSaver = false))
        assertEquals(wifiHint, table.hint(newWifiAddress, dataSaver = false))
        table.setDefault("wifi2")
        assertEquals(
            expect(PathCost.Unmetered, PathConfidence.Medium, PathInterface.WiFi),
            table.hint(null, dataSaver = false),
        )
    }

    @Test
    fun aNetworkLostOrDefaultClearedAfterARestartAlsoStartsFromScratch() {
        val table = tableWithWifiAndCellular()
        table.pause()
        table.remove("cell")
        assertNull(table.hint(wifiAddress, dataSaver = false))

        val second = tableWithWifiAndCellular()
        second.pause()
        second.clearDefault("cell")
        assertNull(second.hint(cellularAddress, dataSaver = false))
        assertNull(second.hint(null, dataSaver = false))
    }

    @Test
    fun staleNetworksNoCallbackConfirmedAreDroppedWhenTheRestartSettles() {
        val table = tableWithWifiAndCellular()
        table.pause()
        table.expireStale()
        assertNull(table.hint(wifiAddress, dataSaver = false))
        assertNull(table.hint(null, dataSaver = false))
    }

    @Test
    fun expiringWithoutAPauseKeepsLiveNetworks() {
        val table = tableWithWifiAndCellular()
        table.expireStale()
        assertEquals(wifiHint, table.hint(wifiAddress, dataSaver = false))
    }

    @Test
    fun aPausedTableStillAnswersWithTheCurrentDataSaverSetting() {
        val table = tableWithWifiAndCellular()
        table.pause()
        assertEquals(
            expect(PathCost.Constrained, PathConfidence.High, PathInterface.Cellular),
            table.hint(cellularAddress, dataSaver = true),
        )
    }

    // MARK: - Wire names (Shared/NetworkCost.swift raw values)

    @Test
    fun wireNamesAreTheOnesTheMacParses() {
        assertEquals(listOf("unmetered", "expensive", "constrained"), PathCost.entries.map { it.wire })
        assertEquals(listOf("low", "medium", "high"), PathConfidence.entries.map { it.wire })
        assertEquals(listOf("wifi", "wired", "cellular", "tunnel", "unknown"), PathInterface.entries.map { it.wire })
        assertEquals(listOf("auto", "on", "off"), UseLessData.entries.map { it.raw })
    }

    // MARK: - Hello

    private val base = HelloFields(1080, 2400, 2.75, "id")

    @Test
    fun aHelloWithoutTheSettingOrAHintCarriesNeitherKey() {
        val hello = ReceiverMessages.hello(base)
        assertNull(hello["saveData"])
        assertNull(hello["cost"])
        assertAdaptiveKeysNeverSent(hello)
    }

    @Test
    fun theSettingTravelsAsSaveDataWithoutACostHintWhenThePathIsUnknown() {
        for (setting in UseLessData.entries) {
            val hello = ReceiverMessages.hello(base.copy(useLessData = setting))
            assertEquals(setting.raw, hello["saveData"]!!.jsonPrimitive.content)
            assertNull("an unknown path sends no hint", hello["cost"])
        }
    }

    @Test
    fun theCostHintIsAnObjectWithCostConfAndIface() {
        val hello = ReceiverMessages.hello(
            base.copy(useLessData = UseLessData.Automatic, cost = NetworkCostHint(PathCost.Constrained, PathConfidence.High, PathInterface.Cellular)),
        )
        assertEquals("auto", hello["saveData"]!!.jsonPrimitive.content)
        assertEquals(
            """{"cost":"constrained","conf":"high","iface":"cellular"}""",
            hello["cost"]!!.jsonObject.toString(),
        )
        assertAdaptiveKeysNeverSent(hello)
    }

    @Test
    fun theNewKeysAreTheOnlyDifferenceFromTheOldHello() {
        val full = ReceiverMessages.hello(
            base.copy(useLessData = UseLessData.On, cost = NetworkCostHint(PathCost.Expensive, PathConfidence.Medium, PathInterface.Tunnel)),
        )
        assertEquals(ReceiverMessages.hello(base), JsonObject(full.filterKeys { it != "saveData" && it != "cost" }))
    }

    private fun assertAdaptiveKeysNeverSent(hello: JsonObject) {
        for (key in listOf("effHz", "adaptiveTelemetry", "saveDataAnswer", "diag")) assertNull("$key is not sent by Android", hello[key])
    }

    // MARK: - Re-announce on the live connection

    private class FakeLink(override val peerID: String, override val localAddress: java.net.InetAddress?) : MediaLink {
        val hellos = mutableListOf<JsonObject>()
        override fun send(payload: ByteArray): Boolean {
            val message = Json.parseToJsonElement(String(payload)).jsonObject
            if (message["type"]?.jsonPrimitive?.content == "hello") hellos += message
            return true
        }
        override fun close() = Unit
    }

    private val local = java.net.InetAddress.getByAddress(byteArrayOf(10, 0, 0, 5))
    private var setting = UseLessData.Automatic
    private var pathHint: NetworkCostHint? = null
    private val askedFor = mutableListOf<java.net.InetAddress?>()
    private val session = ReceiverSession(
        InMemorySessionPolicyStore(), { mapOf("mac" to byteArrayOf(1)) }, { base.copy(useLessData = setting) }, { },
        pathCost = { address -> askedFor += address; pathHint },
    )

    @Test
    fun theHelloAsksForThePathOfThisConnectionsOwnAddressAndOmitsAnUnknownOne() {
        val link = FakeLink("mac", local)
        session.adopt(link)
        assertEquals(listOf<java.net.InetAddress?>(local), askedFor)
        assertEquals("auto", link.hellos.single()["saveData"]!!.jsonPrimitive.content)
        assertNull(link.hellos.single()["cost"])
    }

    @Test
    fun aChangedSettingOrPathIsReannouncedAndAnUnchangedOneIsNot() {
        val link = FakeLink("mac", local)
        session.adopt(link)
        session.resendHello()
        assertEquals("nothing changed", 1, link.hellos.size)

        setting = UseLessData.Off
        session.resendHello()
        assertEquals(2, link.hellos.size)
        assertEquals("off", link.hellos.last()["saveData"]!!.jsonPrimitive.content)

        pathHint = NetworkCostHint(PathCost.Expensive, PathConfidence.High, PathInterface.Cellular)
        session.resendHello()
        assertEquals(3, link.hellos.size)
        assertEquals("expensive", link.hellos.last()["cost"]!!.jsonObject["cost"]!!.jsonPrimitive.content)

        session.resendHello()
        assertEquals(3, link.hellos.size)

        pathHint = null
        session.resendHello()
        assertEquals(4, link.hellos.size)
        assertTrue("the hint goes away when the path becomes unknown", link.hellos.last()["cost"] == null)
    }
}
