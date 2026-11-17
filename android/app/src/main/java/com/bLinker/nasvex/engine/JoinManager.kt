package com.bLinker.nasvex.engine

import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSuggestion
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import org.json.JSONObject

/**
 * Receiver side: join the sender's hotspot.
 *
 * Primary path is a WifiNetworkSuggestion: Android shows its own one-time
 * system consent card the first time, then silently joins whenever the
 * network appears. That consent card is a system card - untouched.
 *
 * Fallbacks (both real system screens, untouched):
 *  - Android 10+: the pre-filled system "Add network" panel (one tap).
 *  - Android 8-9 : the system Wi-Fi settings (manual code entry).
 */
class JoinManager(private val context: Context, private val bus: EngineBus) {

    companion object { const val PANEL_REQ = 58233 }

    private val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val h = Handler(Looper.getMainLooper())
    private var pending: WifiNetworkSuggestion? = null
    private var poller: Runnable? = null

    fun join(creds: HotspotManager.Creds, onConnected: (gateway: String?) -> Unit) {
        stopPolling()
        forget()
        if (Build.VERSION.SDK_INT < 29) {
            bus.emit("join:manual_needed", creds.toJson(null))
            return
        }
        val suggestion = WifiNetworkSuggestion.Builder()
            .setSsid(creds.ssid)
            .setWpa2Passphrase(creds.pass)
            .build()
        val status = runCatching { wm.addNetworkSuggestions(listOf(suggestion)) }.getOrDefault(-1)
        if (status != WifiManager.STATUS_NETWORK_SUGGESTIONS_SUCCESS) {
            bus.emit("join:manual_needed", creds.toJson(null))
            return
        }
        pending = suggestion
        bus.emit("join:waiting", JSONObject().put("ssid", creds.ssid))
        poll(creds, SystemClock.elapsedRealtime(), 30_000, onConnected)
    }

    private fun poll(creds: HotspotManager.Creds, t0: Long, timeout: Long, onConnected: (String?) -> Unit) {
        val r = Runnable {
            val ssid = Net.currentWifiSsid ?: currentSsidCompat()
            if (ssid == creds.ssid) {
                val network = Net.currentWifiNetwork
                val gateway = Net.gateway(context, network)
                bus.emit("join:connected", JSONObject()
                    .put("ssid", ssid)
                    .put("gateway", gateway ?: JSONObject.NULL))
                onConnected(gateway)
            } else if (SystemClock.elapsedRealtime() - t0 > timeout) {
                bus.emit("join:timeout", JSONObject().put("ssid", creds.ssid))
            } else {
                h.postDelayed(poller ?: return@Runnable, 800)
            }
        }
        poller = r
        h.post(r)
    }

    private fun currentSsidCompat(): String? {
        @Suppress("DEPRECATION")
        return runCatching { wm.connectionInfo?.ssid }.getOrNull()?.let { Net.cleanSsid(it) }
    }

    fun stopPolling() {
        poller?.let { h.removeCallbacks(it) }
        poller = null
    }

    /** Remove our suggestion so we never pollute the system's auto-join list. */
    fun forget() {
        pending?.let { s -> runCatching { wm.removeNetworkSuggestions(listOf(s)) } }
        pending = null
    }

    /** Fallback: system "Add network" panel pre-filled with the sender's creds. */
    fun openJoinPanel(creds: HotspotManager.Creds?) {
        val a = bus.activity ?: return
        if (Build.VERSION.SDK_INT < 29 || creds == null) {
            a.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
            return
        }
        val suggestion = WifiNetworkSuggestion.Builder()
            .setSsid(creds.ssid).setWpa2Passphrase(creds.pass).build()
        val i = Intent(Settings.ACTION_WIFI_ADD_NETWORKS)
            .putParcelableArrayListExtra(Settings.EXTRA_WIFI_NETWORK_LIST, arrayListOf(suggestion))
        a.startActivityForResult(i, PANEL_REQ)
    }

    /** Outcome of the system panel; forwarded from MainActivity. */
    fun onPanelResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PANEL_REQ) return
        val results = data?.extras?.getIntegerArrayList(Settings.EXTRA_WIFI_NETWORK_RESULT_LIST)
        bus.emit("join:panel_result", JSONObject()
            .put("added", results?.contains(WifiManager.STATUS_NETWORK_SUGGESTIONS_SUCCESS) == true))
        // The poller keeps running: join:connected is the source of truth.
    }
}
