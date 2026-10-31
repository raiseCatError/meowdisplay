package com.raisecaterror.meowdisplay.android.remote

import android.annotation.SuppressLint
import android.content.Context
import com.raisecaterror.meowdisplay.core.remote.RemoteMacStorage

/**
 * Where the saved remote addresses live: app-private, excluded from backup and device transfer like
 * the pins (res/xml/data_extraction_rules.xml excludes all shared preferences). They are routing
 * hints, not secrets, but a restored device should pair and add addresses afresh.
 */
class RemoteMacPrefs(context: Context) : RemoteMacStorage {
    private val prefs = context.getSharedPreferences("remoteMacs", Context.MODE_PRIVATE)

    override fun read(): String? = prefs.getString(KEY, null)

    // commit(): a removed address must stay removed across a crash right after.
    @SuppressLint("ApplySharedPref", "UseKtx")
    override fun write(text: String): Boolean = prefs.edit().putString(KEY, text).commit()

    private companion object { const val KEY = "macs.v1" }
}

/** Tailscale addresses paired Macs reported (PROTOCOL.md 6.17): the same app-private file, its own key. */
class AutomaticEndpointPrefs(context: Context) : RemoteMacStorage {
    private val prefs = context.getSharedPreferences("remoteMacs", Context.MODE_PRIVATE)

    override fun read(): String? = prefs.getString(KEY, null)

    @SuppressLint("ApplySharedPref", "UseKtx")
    override fun write(text: String): Boolean = prefs.edit().putString(KEY, text).commit()

    private companion object { const val KEY = "automatic.v1" }
}

/** The Automatic Remote Access switch (on unless turned off). */
class AutomaticRemoteAccessPrefs(context: Context) {
    private val prefs = context.getSharedPreferences("remoteMacs", Context.MODE_PRIVATE)

    var enabled: Boolean
        get() = prefs.getBoolean(KEY, true)
        @SuppressLint("ApplySharedPref", "UseKtx")
        set(value) { prefs.edit().putBoolean(KEY, value).commit() }

    private companion object { const val KEY = "automatic.enabled" }
}
