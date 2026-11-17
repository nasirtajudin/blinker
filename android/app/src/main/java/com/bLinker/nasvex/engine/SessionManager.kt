package com.bLinker.nasvex.engine

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.WindowManager
import org.json.JSONObject
import java.net.Socket

/**
 * Orchestrates the method waterfall:
 *
 *   (1) same router -> mDNS, zero prompts, straight over the LAN
 *   (2) Wi-Fi Direct messenger + local-only hotspot (Fast 5GHz / Normal 2.4GHz)
 *   (3) manual code / system Wi-Fi panel fallback
 *
 * Emits "session:state" {phase} plus decision events (invite:received,
 * session:band_unavailable, session:downgrade_request, session:manual_code,
 * ...) which Flutter renders in bLinker's own design language. Nothing here
 * ever mimics a system dialog.
 */
class SessionManager(private val context: Context, private val bus: EngineBus) {

    companion object {
        const val RECEIVER_TIMEOUT_MS = 30_000L
        const val MANUAL_TIMEOUT_MS = 120_000L
    }

    enum class Phase(val id: String) {
        IDLE("idle"),
        MDNS_SEARCH("mdns_search"),
        P2P_SEARCH("p2p_search"),
        INVITING("inviting"),
        EXCHANGING("exchanging"),
        HOTSPOT_STARTING("hotspot_starting"),
        WAITING_RECEIVER("waiting_receiver"),
        STANDBY("standby"),
        JOINING("joining"),
        LINK_CONNECTING("link_connecting"),
        LINK_CONNECTED("link_connected"),
        FAILED("failed")
    }

    val hotspot = HotspotManager(context, bus)
    val join = JoinManager(context, bus)
    val p2p = P2pMessenger(context, bus)
    val mdns = MdnsBeacon(context, bus)
    private val tcpServer = TcpLink.Server(bus)
    private val tcpClient = TcpLink.Client(bus)

    private val h = Handler(Looper.getMainLooper())
    private val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

    @Volatile private var active = false
    @Volatile private var fast = true
    @Volatile private var sender = false
    @Volatile private var phase = Phase.IDLE
    @Volatile private var creds: HotspotManager.Creds? = null
    @Volatile private var manualMode = false

    private var wifiLock: WifiManager.WifiLock? = null
    private var receiverTimeout: Runnable? = null
    private var statsTick: Runnable? = null

    /** The established link socket; Phase 3 (transfer) attaches here. */
    val linkSocket: Socket? get() = if (sender) tcpServer.client else tcpClient.socket

    fun phase(): String = phase.id

    private fun state(p: Phase) {
        phase = p
        bus.emit("session:state", JSONObject().put("phase", p.id))
    }

    // ------------------------------------------------------------- sender

    fun startSenderHotspot(mode: String) {
        sender = true
        fast = mode != "normal"
        manualMode = Build.VERSION.SDK_INT < 33
        begin()
        checkPerms()
        // Android 13+: credentials exist before the hotspot does, so they can
        // travel over the P2P messenger. 8-12: system generates them later.
        creds = if (Build.VERSION.SDK_INT >= 33) hotspot.generateCreds() else null
        p2p.credsForExchange = creds?.toJson(null)
        p2p.invitedFast = fast
        state(Phase.P2P_SEARCH)
        p2p.start(sender = true)
    }

    fun startSenderLan() {
        sender = true
        begin()
        state(Phase.MDNS_SEARCH)
        mdns.browse()
    }

    /** Sender picked a LAN receiver from the radar (same-router method). */
    fun lanConnect(host: String, port: Int) {
        state(Phase.LINK_CONNECTING)
        tcpClient.connect(host, port, Net.currentWifiNetwork,
            onConnected = { onLinkEstablished() },
            onFailed = { fail("lan_connect", it) })
    }

    /** Sender picked a nearby device from the radar (P2P messenger). */
    fun connectPeer(peerId: String) {
        state(Phase.INVITING)
        p2p.connectTo(peerId)
    }

    // ------------------------------------------------------------ receiver

    fun startReceiver() {
        sender = false
        begin()
        checkPerms()
        // LAN visibility (method 1) - works with zero permissions.
        tcpServer.listen(
            onClient = {
                p2p.teardown()
                mdns.stop()
                onLinkEstablished()
            },
            onFailed = { fail("tcp_listen", it) })
        mdns.advertise(Device.name(context), TcpLink.PORT)
        // P2P visibility (method 2 messenger).
        p2p.start(sender = false)
        state(Phase.STANDBY)
    }

    /** Receiver's answer to the bLinker invite card. */
    fun respondInvite(accept: Boolean, preferNormal: Boolean) {
        state(if (accept) Phase.EXCHANGING else Phase.IDLE)
        p2p.respond(accept, preferNormal)
    }

    /** Receiver typed the sender's manual code (Android 8-12 fallback). */
    fun joinManual(ssid: String, pass: String) {
        if (ssid.isBlank() || pass.isBlank()) return
        state(Phase.JOINING)
        join.join(HotspotManager.Creds(ssid, pass, TcpLink.PORT)) { gateway ->
            connectToSender(gateway, JSONObject().put("port", TcpLink.PORT))
        }
    }

    /** Fallback after join:timeout - opens the system panel (untouched). */
    fun joinPanel() {
        join.openJoinPanel(creds)
    }

    /** [Switch to Normal] accepted on the sender: teardown, fresh creds, re-discovery. */
    fun switchMode(mode: String) {
        val keepSender = sender
        stop(silent = true)
        if (keepSender) startSenderHotspot(mode)
    }

    fun stop(silent: Boolean = false) {
        active = false
        reset()
        releaseLocks()
        stopStats()
        SessionService.stop(context)
        if (!silent) state(Phase.IDLE) else phase = Phase.IDLE
    }

    // ---------------------------------------------------------- internals

    private fun begin() {
        active = true
        reset()
        Net.startWatch(context)
        acquireLocks()
        wireP2pCallbacks()
        wireHotspotCallbacks()
        SessionService.start(context, "Preparing transfer link")
        startStats()
    }

    private fun reset() {
        receiverTimeout?.let { h.removeCallbacks(it) }
        receiverTimeout = null
        p2p.teardown()
        mdns.stop()
        hotspot.stop()
        tcpServer.stop()
        tcpClient.stop()
        join.stopPolling()
        join.forget()
    }

    private fun checkPerms() {
        val needed = if (Build.VERSION.SDK_INT >= 33) listOf(
            Manifest.permission.NEARBY_WIFI_DEVICES,
            Manifest.permission.POST_NOTIFICATIONS
        ) else listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        val missing = needed.filter {
            context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) {
            bus.emit("session:perm_missing", JSONObject().put("needed", missing))
        }
    }

    private fun wireP2pCallbacks() {
        p2p.onInvite = { invite ->
            // Enriched for the UI: can this receiver do the invited band?
            val enriched = invite.put("bandOk", !invite.optBoolean("fast") || wm.is5GHzBandSupported)
            bus.emit("invite:received", enriched)
        }
        p2p.onCredsReceived = { json ->
            if (json == null) {
                // Android 8-12: sender shows a code, receiver enters it.
                stopLanStack()
                state(Phase.JOINING)
                bus.emit("session:manual_expected", null)
            } else {
                val ssid = json.optString("ssid")
                val pass = json.optString("pass")
                val port = json.optInt("port", TcpLink.PORT)
                creds = HotspotManager.Creds(ssid, pass, port)
                stopLanStack()
                state(Phase.JOINING)
                join.join(creds!!) { gateway -> connectToSender(gateway, json) }
            }
        }
        p2p.onHandshakeComplete = {
            // P2P is closed and the radio is free - now bring up the hotspot.
            state(Phase.HOTSPOT_STARTING)
            hotspot.start(creds, fast)
        }
        p2p.onDowngradeRequested = {
            // Receiver hardware can't do 5GHz: sender gets the
            // [Switch to Normal] bLinker dialog.
            bus.emit("session:downgrade_request", null)
        }
        p2p.onRejected = { fail("rejected", "The other side declined") }
        p2p.onError = { fail("p2p_exchange", it) }
    }

    private fun wireHotspotCallbacks() {
        hotspot.onStarted = { startedCreds ->
            val pre = creds
            creds = startedCreds
            // If the system altered our pre-shared credentials (shouldn't on
            // 13+, can on some OEMs), fall back to the code path.
            if (pre != null && (pre.ssid != startedCreds.ssid || pre.pass != startedCreds.pass)) {
                manualMode = true
            }
            if (manualMode) {
                bus.emit("session:manual_code", JSONObject()
                    .put("ssid", startedCreds.ssid)
                    .put("pass", startedCreds.pass))
            }
            state(Phase.WAITING_RECEIVER)
            SessionService.start(context, "Waiting for the receiver")
            tcpServer.listen(
                onClient = { onLinkEstablished() },
                onFailed = { fail("tcp_listen", it) })
            val r = Runnable {
                if (phase == Phase.WAITING_RECEIVER) {
                    fail("receiver_timeout", "No receiver joined in time")
                }
            }
            receiverTimeout = r
            h.postDelayed(r, if (manualMode) MANUAL_TIMEOUT_MS else RECEIVER_TIMEOUT_MS)
        }
        hotspot.onFailed = { reason ->
            if (fast && (reason == "no_channel" || reason == "generic")) {
                // 5GHz could not be brought up - sender decides about Normal.
                state(Phase.FAILED)
                bus.emit("session:band_unavailable", JSONObject().put("reason", reason))
            } else {
                fail("hotspot", reason)
            }
        }
    }

    private fun connectToSender(gateway: String?, credsJson: JSONObject) {
        state(Phase.LINK_CONNECTING)
        val advertised = if (credsJson.isNull("ip")) null else credsJson.optString("ip")
        val host = advertised ?: gateway
        if (host == null) { fail("no_route", "Sender address unknown"); return }
        // Wait briefly for the Wi-Fi Network object (socket binding needs it).
        waitForNetwork(0) {
            tcpClient.connect(host, credsJson.optInt("port", TcpLink.PORT), Net.currentWifiNetwork,
                onConnected = {
                    mdns.stop()
                    onLinkEstablished()
                },
                onFailed = { fail("tcp_connect", it) })
        }
    }

    private fun waitForNetwork(elapsedMs: Long, then: () -> Unit) {
        if (Net.currentWifiNetwork != null || elapsedMs >= 3_000) { then(); return }
        h.postDelayed({ waitForNetwork(elapsedMs + 200, then) }, 200)
    }

    private fun onLinkEstablished() {
        receiverTimeout?.let { h.removeCallbacks(it) }
        receiverTimeout = null
        state(Phase.LINK_CONNECTED)
        SessionService.start(context, "Link established")
    }

    private fun stopLanStack() {
        mdns.stop()
        tcpServer.stop()
    }

    private fun fail(stage: String, message: String?) {
        state(Phase.FAILED)
        bus.emit("session:failed", JSONObject()
            .put("stage", stage)
            .put("reason", message ?: stage))
        stop(silent = true)
    }

    private fun acquireLocks() {
        releaseLocks()
        val mode = if (Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                   else WifiManager.WIFI_MODE_FULL
        @Suppress("DEPRECATION")
        wifiLock = wm.createWifiLock(mode, "bLinker.session").apply {
            setReferenceCounted(false)
            acquire()
        }
        bus.activity?.window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun releaseLocks() {
        runCatching { if (wifiLock?.isHeld == true) wifiLock?.release() }
        wifiLock = null
        bus.activity?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun startStats() {
        stopStats()
        val r = object : Runnable {
            override fun run() {
                if (!active) return
                Net.currentStats(context)?.let {
                    bus.emit("wifi:stats", JSONObject()
                        .put("band", it.band)
                        .put("freqMhz", it.freqMhz)
                        .put("linkMbps", it.linkMbps)
                        .put("ssid", it.ssid ?: JSONObject.NULL))
                }
                h.postDelayed(this, 1_000)
            }
        }
        statsTick = r
        h.post(r)
    }

    private fun stopStats() {
        statsTick?.let { h.removeCallbacks(it) }
        statsTick = null
    }

    /** Hardware probe for Onboarding + Settings > Diagnostics. */
    fun hardwareProbe(): JSONObject {
        val locationOn = runCatching {
            Settings.Secure.getInt(context.contentResolver, Settings.Secure.LOCATION_MODE, 0)
        }.getOrDefault(0) > 0
        val stats = Net.currentStats(context)
        return JSONObject()
            .put("model", Build.MODEL)
            .put("sdk", Build.VERSION.SDK_INT)
            .put("wifi5ghz", wm.is5GHzBandSupported)
            .put("wifiDirect", context.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT))
            .put("networkSuggestions", Build.VERSION.SDK_INT >= 29)
            .put("customHotspotCredentials", Build.VERSION.SDK_INT >= 33)
            .put("locationServicesOn", locationOn)
            .put("measuredBand", stats?.band ?: JSONObject.NULL)
            .put("measuredLinkMbps", stats?.linkMbps ?: JSONObject.NULL)
    }
}
