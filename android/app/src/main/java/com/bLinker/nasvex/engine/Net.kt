package com.bLinker.nasvex.engine

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.Socket

/**
 * Network plumbing: Wi-Fi network tracking, gateway lookup, socket binding.
 *
 * Golden rule of every file-transfer app: a socket NOT bound to the Wi-Fi
 * [Network] gets routed over the default network (usually cellular), and
 * connect() to a 192.168.x.x hotspot address then hangs until timeout.
 * Always create client sockets through [socketFor].
 */
object Net {

    @Volatile var currentWifiNetwork: Network? = null
        private set
    @Volatile var currentWifiSsid: String? = null
        private set

    @Volatile private var watching = false

    fun startWatch(ctx: Context) {
        synchronized(this) {
            if (watching) return
            val cm = ctx.applicationContext.getSystemService(ConnectivityManager::class.java) ?: return
            watching = true
            // Local-only hotspots have NO INTERNET capability - keep them matched.
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            cm.registerNetworkCallback(request, object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    currentWifiNetwork = network
                }
                override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                    currentWifiNetwork = network
                    if (Build.VERSION.SDK_INT >= 29) {
                        (caps.transportInfo as? WifiInfo)?.let { currentWifiSsid = cleanSsid(it.ssid) }
                    }
                }
                override fun onLost(network: Network) {
                    if (currentWifiNetwork == network) {
                        currentWifiNetwork = null
                        currentWifiSsid = null
                    }
                }
            })
        }
    }

    fun cleanSsid(raw: String?): String? {
        if (raw.isNullOrBlank()) return null
        var s = raw.trim()
        if (s.length >= 2 && s.startsWith("\"") && s.endsWith("\"")) s = s.substring(1, s.length - 1)
        if (s.isBlank() || s == "<unknown ssid>" || s == "unknown ssid") return null
        return s
    }

    /** A client socket guaranteed to leave through the given Wi-Fi network. */
    fun socketFor(network: Network?): Socket = network?.socketFactory?.createSocket() ?: Socket()

    /** DHCP server (= hotspot owner) address of the current Wi-Fi link. */
    fun gateway(ctx: Context, network: Network?): String? {
        val cm = ctx.applicationContext.getSystemService(ConnectivityManager::class.java)
        if (cm != null && network != null && Build.VERSION.SDK_INT >= 31) {
            cm.getLinkProperties(network)?.dhcpServerAddress?.hostAddress?.let { return it }
        }
        val wm = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return null
        @Suppress("DEPRECATION")
        val d = runCatching { wm.dhcpInfo }.getOrNull() ?: return null
        val gw = d.gateway
        if (gw == 0) return null
        return "%d.%d.%d.%d".format(gw and 0xFF, gw shr 8 and 0xFF, gw shr 16 and 0xFF, gw shr 24 and 0xFF)
    }

    /** Best-effort IPv4 of THIS device's hotspot interface (sender side). */
    fun senderApIpv4(): String? {
        val list = runCatching { NetworkInterface.getNetworkInterfaces().asSequence().toList() }
            .getOrNull().orEmpty()
        fun ip(ni: NetworkInterface): String? =
            ni.interfaceAddresses.firstOrNull { it.address is Inet4Address }?.address?.hostAddress
        val up = list.filter { runCatching { it.isUp }.getOrDefault(false) && !it.isLoopback }
        up.firstOrNull { it.name == "ap0" || it.name.startsWith("swlan") }?.let { return ip(it) }
        up.firstOrNull { Regex("wlan[1-9][0-9]*").matches(it.name) }?.let { return ip(it) }
        // STA radio free (P2P torn down, not on a router) -> wlan0 IS the AP.
        if (currentWifiSsid == null) up.firstOrNull { it.name == "wlan0" }?.let { return ip(it) }
        return null
    }

    class WifiStats(val band: String, val freqMhz: Int, val linkMbps: Int, val ssid: String?)

    /** Ground truth for the HUD chip: the MEASURED band, never the requested one. */
    fun currentStats(ctx: Context): WifiStats? {
        val wm = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return null
        @Suppress("DEPRECATION")
        val info = runCatching { wm.connectionInfo }.getOrNull() ?: return null
        val freq = info.frequency
        if (freq <= 0) return null
        val band = when {
            freq >= 4900 -> "5GHz"
            freq in 2400..2500 -> "2.4GHz"
            else -> "?"
        }
        return WifiStats(band, freq, info.linkSpeed, cleanSsid(info.ssid))
    }
}
