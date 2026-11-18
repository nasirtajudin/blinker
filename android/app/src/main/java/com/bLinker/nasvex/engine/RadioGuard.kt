package com.bLinker.nasvex.engine

import android.content.Context
import android.content.Intent
import android.location.LocationManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import org.json.JSONArray
import org.json.JSONObject

/**
 * THE radio gate (Phase 5).
 *
 * Real-device reality the first four phases missed: Wi-Fi Direct discovery
 * and the local-only hotspot both need (a) the Wi-Fi adapter ON and (b)
 * Location services ON - most OEM builds (Samsung / Xiaomi / OPPO / ...)
 * return ZERO peers from discoverPeers() while Location is off, and the
 * hotspot fails with no_channel. Nothing ever checked this, so both phones
 * just sat "searching" forever with an empty radar.
 *
 * Before any session starts, [gate] verifies both radios. If one is off the
 * session parks in needs_radios, Flutter shows a bLinker card with the REAL
 * system enable paths, and a light poller (plus every app resume) re-checks.
 * The moment both are on the parked session starts for real.
 *
 * What each fix really is (public API only, never a fake toggle):
 *  - Wi-Fi, Android 9-: WifiManager.setWifiEnabled(true) - genuinely turns
 *    the adapter on, allowed for apps holding CHANGE_WIFI_STATE below API 29.
 *  - Wi-Fi, Android 10+: Settings.Panel.ACTION_WIFI - Android's own panel,
 *    the user flips the real toggle.
 *  - Location, any version: Settings.ACTION_LOCATION_SOURCE_SETTINGS - the
 *    real system page. (No app can silently flip Location on any Android -
 *    anything that looks like that would be a fake.)
 */
class RadioGuard(private val context: Context, private val bus: EngineBus) {

    private val wm =
        context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val h = Handler(Looper.getMainLooper())

    /** The session start block parked while a radio is off. */
    private var pendingStart: (() -> Unit)? = null
    private var poller: Runnable? = null
    @Volatile private var gating = false

    // ------------------------------------------------------------ state

    fun isWifiOn(): Boolean = runCatching { wm.isWifiEnabled }.getOrDefault(true)

    /** LOCATION_MODE works on every API level (deprecated 31+, still live). */
    fun isLocationOn(): Boolean {
        if (Build.VERSION.SDK_INT >= 28) {
            val lm = context.applicationContext
                .getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            val on = runCatching { lm?.isLocationEnabled }.getOrNull()
            if (on != null) return on
        }
        return runCatching {
            @Suppress("DEPRECATION")
            Settings.Secure.getInt(
                context.contentResolver, Settings.Secure.LOCATION_MODE, 0
            )
        }.getOrDefault(0) > 0
    }

    /** JSON: {blocked:["wifi","location"], wifiOn:bool, locationOn:bool} */
    fun state(): JSONObject {
        val wifiOn = isWifiOn()
        val locationOn = isLocationOn()
        val blocked = JSONArray()
        if (!wifiOn) blocked.put("wifi")
        if (!locationOn) blocked.put("location")
        return JSONObject()
            .put("blocked", blocked)
            .put("wifiOn", wifiOn)
            .put("locationOn", locationOn)
    }

    // ------------------------------------------------------------- gate

    /**
     * Run [then] now if both radios are on; otherwise park the session,
     * tell Flutter which radio is missing, and re-check until both are on.
     */
    fun gate(then: () -> Unit) {
        cancel()
        if (isWifiOn() && isLocationOn()) {
            then()
            return
        }
        gating = true
        pendingStart = then
        bus.emit("radio:blocked", state())
        startPolling()
    }

    /** Re-check on demand (app resume / the Check-again button). */
    fun recheck() {
        if (!gating) return
        if (isWifiOn() && isLocationOn()) {
            cancel()
            bus.emit("radio:ok", null)
            pendingStart?.invoke()
            pendingStart = null
        } else {
            bus.emit("radio:blocked", state())
        }
    }

    fun cancel() {
        gating = false
        pendingStart = null
        poller?.let { h.removeCallbacks(it) }
        poller = null
    }

    /**
     * A light poll while parked: the Wi-Fi panel and the Location page are
     * other apps, so broadcasts/resume alone would miss flips made in the
     * quick-settings shade. 2.5s, stops the moment the gate clears.
     */
    private fun startPolling() {
        val r = object : Runnable {
            override fun run() {
                if (!gating) return
                if (isWifiOn() && isLocationOn()) recheck()
                else h.postDelayed(this, 2_500)
            }
        }
        poller = r
        h.postDelayed(r, 2_500)
    }

    // -------------------------------------------------------- actions

    /** Real system path to get Wi-Fi on. See class doc for the version split. */
    fun openWifiPanel() {
        if (isWifiOn()) return
        if (Build.VERSION.SDK_INT < 29) {
            // Android 8-9: the app may enable the adapter itself.
            @Suppress("DEPRECATION")
            runCatching { wm.setWifiEnabled(true) }
            return
        }
        val a = bus.activity ?: return
        runCatching { a.startActivity(Intent(Settings.Panel.ACTION_WIFI)) }
    }

    /** Real system page for the Location toggle (no app can flip it directly). */
    fun openLocationSettings() {
        if (isLocationOn()) return
        val a = bus.activity ?: return
        runCatching { a.startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)) }
    }
}
