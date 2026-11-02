package com.raisecaterror.meowdisplay.android

import com.raisecaterror.meowdisplay.android.discovery.ServiceTypes
import org.junit.Assert.assertEquals
import org.junit.Test

/** The advertisement Apple senders browse for (PROTOCOL.md 2.1, 2.2a). */
class ServiceTypesTest {
    @Test
    fun theReceiverAdvertisesTheAppleServiceTypesAndPorts() {
        assertEquals("_opensidecar._tcp", ServiceTypes.MEDIA)
        assertEquals("_opendisplay-pair._tcp", ServiceTypes.PAIRING)
        assertEquals("_opendisplay-mac-pair._tcp", ServiceTypes.MAC_PAIRING)
        assertEquals(9001, ServiceTypes.MEDIA_PORT)
        assertEquals(9002, ServiceTypes.PAIRING_PORT)
    }

    @Test
    fun thePairingTxtCarriesIdAndVersionsOnly() {
        assertEquals(
            mapOf("id" to "1A2B3C4D-5E6F-4071-8293-A4B5C6D7E8F9", "pv" to "22", "pp" to "13"),
            ServiceTypes.pairingTxt("1A2B3C4D-5E6F-4071-8293-A4B5C6D7E8F9", 22, 13),
        )
    }

    @Test
    fun theMediaAdvertisementCarriesOnlyIdAndProtocolVersion() {
        assertEquals(mapOf("id" to "ID", "pv" to "22"), ServiceTypes.mediaTxt("ID", 22))
        assertEquals(9001, ServiceTypes.MEDIA_PORT)
    }
}
