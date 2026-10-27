package com.raisecaterror.meowdisplay.android

import android.app.Application
import com.raisecaterror.meowdisplay.android.discovery.Bonjour
import com.raisecaterror.meowdisplay.android.identity.DeviceIdentity
import com.raisecaterror.meowdisplay.android.pairing.PairingController
import com.raisecaterror.meowdisplay.android.trust.PinStore

/** Process-wide receiver services: one identity, one pin store, one pairing listener. */
class MeowReceiverApplication : Application() {
    val identity: DeviceIdentity by lazy { DeviceIdentity.load(this) }
    val pins: PinStore by lazy { PinStore(this) }
    val bonjour: Bonjour by lazy { Bonjour(this) }
    val pairing: PairingController by lazy {
        PairingController(identity, pins, bonjour, localName = { DeviceIdentity.displayName(this) })
    }
}
