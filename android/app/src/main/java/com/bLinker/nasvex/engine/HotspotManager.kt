package com.bLinker.nasvex.engine

import android.content.Context
import android.net.wifi.SoftApConfiguration
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import org.json.JSONObject

/**
 * Sender side of the transport link: a local-only hotspot.
 *
 * PUBLIC-API REALITY (verified against the SDK android.jar, API 26-35):
 * third-party apps cannot preset the SSID/passphrase or the band of a
 * local-only hotspot - SoftApConfiguration's builder/band constants and the
 * config-taking hotspot overloads are not part of the public SDK on ANY
 * Android version. The system generates a random SSID + WPA2 passphrase the
 * moment the hotspot starts, on every version.
 *
 * So the pairing flow on every Android version is:
 *   1. Wi-Fi Direct carries invite -> accept/reject (+ band preference) ->
 *      a "manual" join instruction -> ack (see [P2pMessenger]).
 *   2. Both sides tear the P2P link down (most radios cannot run P2P and AP
 *      together, and the radio must be free for the hotspot anyway).
 *   3. The sender starts the hotspot, reads the system-generated
 *      credentials back from the reservation and shows them on screen
 *      (session:manual_code). The receiver joins with them - one typed
 *      entry, then WifiNetworkSuggestion / system panel take over
 *      (see [JoinManager]).
 *
 * [fast] is the 5GHz preference: the system honours it where the radio and
 * region allow; the HUD always shows the band MEASURED by WifiInfo
 * (wifi:stats), never the requested one.
 */
class HotspotManager(private val context: Context, private val bus: EngineBus) {

    class Creds(val ssid: String, val pass: String, val port: Int) {
        fun toJson(ip: String?): JSONObject = JSONObject()
            .put("ssid", ssid).put("pass", pass).put("port", port)
            .put("ip", ip ?: JSONObject.NULL)
    }

    /** Sender wiring (Kotlin-side callbacks in addition to bus events). */
    @Volatile var onStarted: ((Creds) -> Unit)? = null
    @Volatile var onFailed: ((String) -> Unit)? = null

    private val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null

    /**
     * Start the local-only hotspot. The (callback, handler) overload is the
     * ONLY one in the public SDK; it exists since API 26 (= our minSdk).
     */
    fun start(fast: Boolean) {
        wm.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
            override fun onStarted(r: WifiManager.LocalOnlyHotspotReservation) {
                reservation = r
                val creds = readCreds(r)
                if (creds == null) {
                    bus.emit("hotspot:failed",
                        JSONObject().put("reason", "no_credentials").put("fast", fast))
                    onFailed?.invoke("no_credentials")
                    return
                }
                bus.emit("hotspot:started", creds.toJson(Net.senderApIpv4()))
                onStarted?.invoke(creds)
            }

            override fun onFailed(reason: Int) {
                val name = reasonName(reason)
                bus.emit("hotspot:failed",
                    JSONObject().put("reason", name).put("fast", fast))
                onFailed?.invoke(name)
            }

            override fun onStopped() {
                reservation = null
                bus.emit("hotspot:stopped", null)
            }
        }, Handler(Looper.getMainLooper()))
    }

    /**
     * The system-generated credentials of a live hotspot reservation.
     * API 30+: SoftApConfiguration; API 26-29: the deprecated WifiConfiguration.
     */
    private fun readCreds(r: WifiManager.LocalOnlyHotspotReservation): Creds? {
        val ssid: String?
        val pass: String?
        if (Build.VERSION.SDK_INT >= 30) {
            val c: SoftApConfiguration? = r.softApConfiguration
            ssid = Net.cleanSsid(c?.ssid)
            pass = c?.passphrase
        } else {
            @Suppress("DEPRECATION")
            val c: WifiConfiguration? = r.wifiConfiguration
            ssid = Net.cleanSsid(c?.SSID)
            @Suppress("DEPRECATION")
            pass = c?.preSharedKey
        }
        if (ssid.isNullOrBlank() || pass.isNullOrBlank()) return null
        return Creds(ssid, pass, TcpLink.PORT)
    }

    private fun reasonName(reason: Int): String = when (reason) {
        WifiManager.LocalOnlyHotspotCallback.ERROR_NO_CHANNEL -> "no_channel"
        WifiManager.LocalOnlyHotspotCallback.ERROR_INCOMPATIBLE_MODE -> "incompatible_mode"
        WifiManager.LocalOnlyHotspotCallback.ERROR_TETHERING_DISALLOWED -> "tethering_disallowed"
        else -> "generic"
    }

    fun stop() {
        runCatching { reservation?.close() }
        reservation = null
    }
}
