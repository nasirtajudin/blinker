package com.bLinker.nasvex.engine

import android.annotation.RequiresApi
import android.content.Context
import android.net.wifi.SoftApConfiguration
import android.net.wifi.WifiManager
import android.os.Build
import org.json.JSONObject
import java.security.SecureRandom
import java.util.concurrent.Executor

/** Cryptographically random, human-typable tokens. */
object Token {
    private const val CS = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789"
    private val rnd = SecureRandom()
    fun make(n: Int): String = buildString { repeat(n) { append(CS[rnd.nextInt(CS.length)]) } }
}

/**
 * Sender side of the transport link: a local-only hotspot on the negotiated band.
 *
 *  - Android 13+: we own the SSID/passphrase (SoftApConfiguration overload of
 *    startLocalOnlyHotspot), so credentials travel over the Wi-Fi Direct
 *    messenger BEFORE the hotspot starts. The user never types anything.
 *  - Android 8-12: the system generates random credentials at hotspot start;
 *    they are unknown during the P2P exchange -> manual code path.
 *
 * Must start only AFTER the Wi-Fi Direct link is torn down: most radios can't
 * run P2P and AP together, and the 5GHz request only takes effect once the
 * radio is free.
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
    private val direct: Executor = Executor { it.run() }

    /** Pre-generated credentials for Android 13+ (sent over the P2P messenger). */
    fun generateCreds(): Creds = Creds("bLinker-" + Token.make(4), Token.make(18), TcpLink.PORT)

    fun start(creds: Creds?, fast: Boolean) {
        if (creds != null && Build.VERSION.SDK_INT >= 33) startCustom(creds, fast)
        else startLegacy()
    }

    @RequiresApi(33)
    private fun startCustom(creds: Creds, fast: Boolean) {
        val builder = SoftApConfiguration.Builder()
            .setSsid(creds.ssid)
            .setPassphrase(creds.pass, SoftApConfiguration.SECURITY_TYPE_WPA2_PSK)
        builder.setBand(if (fast) SoftApConfiguration.BAND_5GHZ else SoftApConfiguration.BAND_2GHZ)
        wm.startLocalOnlyHotspot(builder.build(), direct, object : WifiManager.LocalOnlyHotspotCallback() {
            override fun onStarted(r: WifiManager.LocalOnlyHotspotReservation) {
                reservation = r
                val eff = r.softApConfiguration
                val finalCreds = if (!eff.ssid.isNullOrBlank() && !eff.passphrase.isNullOrBlank())
                    Creds(eff.ssid, eff.passphrase, creds.port) else creds
                bus.emit("hotspot:started", finalCreds.toJson(Net.senderApIpv4()))
                onStarted?.invoke(finalCreds)
            }
            override fun onFailed(reason: Int) {
                val name = reasonName(reason)
                bus.emit("hotspot:failed", JSONObject().put("reason", name).put("fast", fast))
                onFailed?.invoke(name)
            }
            override fun onStopped() { bus.emit("hotspot:stopped", null) }
        })
    }

    @Suppress("DEPRECATION")
    private fun startLegacy() {
        wm.startLocalOnlyHotspot(direct, object : WifiManager.LocalOnlyHotspotCallback() {
            override fun onStarted(r: WifiManager.LocalOnlyHotspotReservation) {
                reservation = r
                val ssid: String?
                val pass: String?
                if (Build.VERSION.SDK_INT >= 30) {
                    val c = r.softApConfiguration
                    ssid = Net.cleanSsid(c?.ssid)
                    pass = c?.passphrase
                } else {
                    val c = r.wifiConfiguration
                    ssid = Net.cleanSsid(c?.ssid)
                    pass = c?.preSharedKey
                }
                if (ssid.isNullOrBlank() || pass.isNullOrBlank()) {
                    bus.emit("hotspot:failed", JSONObject().put("reason", "no_credentials"))
                    onFailed?.invoke("no_credentials")
                } else {
                    val creds = Creds(ssid, pass, TcpLink.PORT)
                    bus.emit("hotspot:started", creds.toJson(Net.senderApIpv4()))
                    onStarted?.invoke(creds)
                }
            }
            override fun onFailed(reason: Int) {
                val name = reasonName(reason)
                bus.emit("hotspot:failed", JSONObject().put("reason", name))
                onFailed?.invoke(name)
            }
            override fun onStopped() { bus.emit("hotspot:stopped", null) }
        })
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
