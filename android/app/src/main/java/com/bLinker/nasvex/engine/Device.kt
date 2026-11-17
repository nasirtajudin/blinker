package com.bLinker.nasvex.engine

import android.content.Context
import android.os.Build
import android.provider.Settings

/** Device identity: the name shown on the other phone's radar. */
object Device {
    private const val SP = "blinker"
    private const val KEY = "device_name"

    fun name(ctx: Context): String {
        val sp = ctx.applicationContext.getSharedPreferences(SP, Context.MODE_PRIVATE)
        sp.getString(KEY, null)?.takeIf { it.isNotBlank() }?.let { return it }
        val bt = runCatching {
            Settings.Secure.getString(ctx.contentResolver, "bluetooth_name")
        }.getOrNull()
        return bt?.takeIf { it.isNotBlank() } ?: Build.MODEL
    }

    fun setName(ctx: Context, name: String) {
        ctx.applicationContext.getSharedPreferences(SP, Context.MODE_PRIVATE)
            .edit().putString(KEY, name.trim()).apply()
    }
}
