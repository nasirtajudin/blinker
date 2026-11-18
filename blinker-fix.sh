#!/usr/bin/env bash
# bLinker fix script - engine public-API reality + UI fixes.
# Generated from a verified tree: Kotlin compiled against the real
# android-34 jar + Flutter 3.24.3 embedding; Dart passed flutter analyze.
#
# Fixes:
#  1. BUILD: HotspotManager/P2pMessenger referenced non-public Android APIs
#     (SoftApConfiguration.Builder, band constants, executor overloads,
#     android.annotation.RequiresApi) and wrong Wi-Fi Direct package paths.
#     Rewritten against the real public SDK (verified with android.jar).
#  2. BUILD: EngineBus invoked MethodCall.arguments as a function.
#  3. CRASH: manifest declared a quick-settings tile service class that
#     does not exist (crash when the tile is added). Removed (Phase 5).
#  4. UI: yellow underline under text in modals/toasts - overlays had no
#     Material ancestor; modal + toast now wrap in a transparent Material.
#  5. UI: Android back button from Settings closed the app - Settings,
#     Diagnostics and Detail are real routes now (back pops them).
#  6. UI: slow fade between pages replaced with fast slides (190/150 ms).
#  7. LOGIC: hardware probe used a misspelled channel + nonexistent method,
#     so 5GHz detection always failed; now goes through the real bridge.
#  8. CI: push trigger branch pattern was broken; pushes build again.
set -e
cd "$(dirname "$0")"
[ -f pubspec.yaml ] || { echo "Run this from the blinker repo root."; exit 1; }
echo "-- writing engine + UI files --"
cat > android/app/src/main/java/com/bLinker/nasvex/engine/HotspotManager.kt <<'BLINKER_EOF'
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
BLINKER_EOF
cat > android/app/src/main/java/com/bLinker/nasvex/engine/P2pMessenger.kt <<'BLINKER_EOF'
package com.bLinker.nasvex.engine

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceInfo
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Wi-Fi Direct is a MESSENGER ONLY.
 *
 * It carries: invite -> accept/reject (+ band preference) -> the join
 * instruction ("manual": join the sender's hotspot and read the code from
 * its screen) -> ack. Then both sides tear the P2P link down so the radio
 * is free for the local-only hotspot. File data NEVER flows over Wi-Fi
 * Direct. (Public-API reality: hotspot credentials cannot be preset by any
 * app, so they never travel over this link - the sender's screen and the
 * receiver's one-time typed entry carry them instead.)
 *
 * Either side may end up group owner; the non-owner connects to the owner on
 * CTRL_PORT. The sender always speaks first (INVITE frame). Devices that
 * advertise the bLinker P2P service are flagged in the peer list so the radar
 * can show only bLinker devices.
 */
class P2pMessenger(private val context: Context, private val bus: EngineBus) : BroadcastReceiver() {

    companion object {
        const val CTRL_PORT = 58232
        private const val TAG = "bLinker.P2P"
        private const val INVITE_TIMEOUT_MS = 45_000L
        private const val ACK_TIMEOUT_MS = 15_000L
    }

    private val pm = context.applicationContext.getSystemService(Context.WIFI_P2P_SERVICE) as WifiP2pManager
    private var channel: WifiP2pManager.Channel? = null
    private var registered = false
    private var senderMode = false
    private val blinkerPeers = HashSet<String>()
    @Volatile private var groupFormed = false
    @Volatile private var tornDown = false

    private var exchangeSocket: Socket? = null
    private var exchangeServer: ServerSocket? = null
    private val io = Executors.newSingleThreadExecutor()
    private val h = Handler(Looper.getMainLooper())

    /** Sender: invite advertises this band preference. */
    @Volatile var invitedFast = true

    /** Receiver: raw invite for the bLinker invite card (app UI, never system-styled). */
    @Volatile var onInvite: ((JSONObject) -> Unit)? = null
    /** Receiver: join instruction received - always the manual path now. */
    @Volatile var onCredsReceived: ((JSONObject?) -> Unit)? = null
    /** Sender: receiver ACKed; P2P already torn down -> bring up the hotspot. */
    @Volatile var onHandshakeComplete: (() -> Unit)? = null
    /** Sender: receiver asked for Normal mode instead of Fast. */
    @Volatile var onDowngradeRequested: (() -> Unit)? = null
    /** Sender: receiver rejected. */
    @Volatile var onRejected: (() -> Unit)? = null
    /** Either: exchange failed (timeout / broken link). */
    @Volatile var onError: ((String) -> Unit)? = null

    private var inviteDecision: CompletableFuture<Pair<Boolean, Boolean>>? = null

    fun start(sender: Boolean) {
        senderMode = sender
        tornDown = false
        groupFormed = false
        synchronized(blinkerPeers) { blinkerPeers.clear() }
        if (channel == null) {
            channel = pm.initialize(context.applicationContext, Looper.getMainLooper(), null)
        }
        if (!registered) {
            val filter = IntentFilter().apply {
                addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
                addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            }
            // WIFI_P2P_* are protected system broadcasts, so the receiver
            // works with the flag on 33+ and without it below.
            if (Build.VERSION.SDK_INT >= 33) {
                context.registerReceiver(this, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                context.registerReceiver(this, filter)
            }
            registered = true
        }
        if (sender) listenForBlinkerServices() else advertiseBlinkerService()
        discover()
        scheduleRediscover()
        bus.emit(if (sender) "p2p:searching" else "p2p:visible", null)
    }

    private fun discover() {
        val ch = channel ?: return
        pm.discoverPeers(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {}
            override fun onFailure(reason: Int) {
                bus.emit("p2p:unavailable", JSONObject().put("reason", reason))
            }
        })
    }

    /** Discovery results go stale after ~a minute; keep the radar alive. */
    private fun scheduleRediscover() {
        h.postDelayed({
            if (registered && !groupFormed && !tornDown) {
                discover()
                scheduleRediscover()
            }
        }, 25_000)
    }

    /** Receiver: advertise the bLinker service so senders can flag us. */
    private fun advertiseBlinkerService() {
        val ch = channel ?: return
        val info = WifiP2pDnsSdServiceInfo.newInstance("_blinker", "_tcp", mapOf("app" to "bLinker"))
        pm.addLocalService(ch, info, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {}
            override fun onFailure(reason: Int) {
                bus.emit("p2p:unavailable", JSONObject().put("reason", reason))
            }
        })
    }

    /**
     * Sender: discover which of the found devices answers as bLinker.
     * DNS-SD responses only arrive after a service REQUEST is registered,
     * so we add one for the _blinker._tcp service alongside the listener.
     */
    private fun listenForBlinkerServices() {
        val ch = channel ?: return
        pm.setDnsSdResponseListeners(ch,
            { instanceName, registrationType, srcDevice ->
                val hit = (registrationType ?: "").contains("blinker") ||
                    (instanceName ?: "").contains("blinker", ignoreCase = true)
                if (hit && srcDevice != null) {
                    synchronized(blinkerPeers) { blinkerPeers.add(srcDevice.deviceAddress) }
                }
            },
            null)
        pm.addServiceRequest(ch, WifiP2pDnsSdServiceRequest.newInstance(),
            object : WifiP2pManager.ActionListener {
                override fun onSuccess() {}
                override fun onFailure(reason: Int) {
                    bus.emit("p2p:unavailable", JSONObject().put("reason", reason))
                }
            })
    }

    override fun onReceive(ctx: Context, intent: Intent) {
        val ch = channel ?: return
        when (intent.action) {
            WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                pm.requestPeers(ch) { peerList ->
                    val arr = JSONArray()
                    peerList.deviceList.forEach { d ->
                        arr.put(JSONObject()
                            .put("id", d.deviceAddress)
                            .put("name", if (d.deviceName.isNullOrBlank()) "Android device" else d.deviceName)
                            .put("blink", synchronized(blinkerPeers) { blinkerPeers.contains(d.deviceAddress) }))
                    }
                    bus.emit("p2p:peers", JSONObject().put("peers", arr))
                }
            }
            WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                pm.requestConnectionInfo(ch) { info -> onConnectionInfo(info) }
            }
        }
    }

    /** Sender picked a device from the radar. */
    fun connectTo(deviceAddress: String) {
        val ch = channel ?: return
        val config = WifiP2pConfig().apply { this.deviceAddress = deviceAddress }
        pm.connect(ch, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() { bus.emit("p2p:connecting", null) }
            override fun onFailure(reason: Int) {
                bus.emit("p2p:connect_failed", JSONObject().put("reason", reason))
            }
        })
    }

    private fun onConnectionInfo(info: WifiP2pInfo) {
        if (!info.groupFormed) {
            if (groupFormed) teardown()   // group dropped mid-exchange
            return
        }
        if (groupFormed) return
        groupFormed = true
        bus.emit("p2p:connected", null)
        io.execute {
            try {
                if (info.isGroupOwner) serveSide() else clientSide(info)
            } catch (t: Throwable) {
                Log.w(TAG, "exchange failed", t)
                teardown()
                onError?.invoke(t.message ?: "exchange failed")
            }
        }
    }

    private fun serveSide() {
        val server = ServerSocket()
        server.reuseAddress = true
        server.bind(InetSocketAddress(CTRL_PORT))
        exchangeServer = server
        val socket = server.accept()          // exactly one client
        exchangeSocket = socket
        talk(socket)
    }

    private fun clientSide(info: WifiP2pInfo) {
        val owner = info.groupOwnerAddress ?: throw IllegalStateException("no group owner")
        val socket = Socket()
        socket.tcpNoDelay = true
        socket.soTimeout = INVITE_TIMEOUT_MS.toInt()
        socket.connect(InetSocketAddress(owner, CTRL_PORT), 10_000)
        exchangeSocket = socket
        talk(socket)
    }

    private fun talk(socket: Socket) {
        val out: OutputStream = socket.getOutputStream()
        val ins: InputStream = socket.getInputStream()

        fun send(frame: JSONObject) {
            val body = frame.toString().toByteArray(Charsets.UTF_8)
            val head = byteArrayOf(
                (body.size shr 24).toByte(), (body.size shr 16).toByte(),
                (body.size shr 8).toByte(), body.size.toByte()
            )
            out.write(head); out.write(body); out.flush()
        }

        fun recv(timeoutMs: Int): JSONObject {
            socket.soTimeout = timeoutMs
            fun readFully(n: Int): ByteArray {
                val b = ByteArray(n)
                var off = 0
                while (off < n) {
                    val r = ins.read(b, off, n - off)
                    if (r < 0) throw EOFException("link closed")
                    off += r
                }
                return b
            }
            val head = readFully(4)
            val len = ((head[0].toInt() and 0xFF) shl 24) or ((head[1].toInt() and 0xFF) shl 16) or
                ((head[2].toInt() and 0xFF) shl 8) or (head[3].toInt() and 0xFF)
            return JSONObject(String(readFully(len), Charsets.UTF_8))
        }

        if (senderMode) {
            send(JSONObject()
                .put("type", "invite")
                .put("name", Device.name(context))
                .put("port", TcpLink.PORT)
                .put("fast", invitedFast))
            when (recv(INVITE_TIMEOUT_MS.toInt()).optString("type")) {
                "accept" -> {
                    // Credentials are system-generated when the hotspot starts
                    // (no public API presets them) -> manual join instruction.
                    send(JSONObject().put("type", "manual").put("port", TcpLink.PORT))
                    if (recv(ACK_TIMEOUT_MS.toInt()).optString("type") == "ack") {
                        teardown()
                        onHandshakeComplete?.invoke()
                    } else teardown()
                }
                "accept_normal" -> {
                    teardown()
                    onDowngradeRequested?.invoke()
                }
                else -> {
                    teardown()
                    onRejected?.invoke()
                }
            }
        } else {
            val invite = recv(INVITE_TIMEOUT_MS.toInt())
            if (invite.optString("type") != "invite") throw IllegalStateException("protocol mismatch")
            val decision = CompletableFuture<Pair<Boolean, Boolean>>()
            inviteDecision = decision
            onInvite?.invoke(invite)   // Flutter renders the bLinker invite card
            val (accept, preferNormal) = try {
                decision.get(INVITE_TIMEOUT_MS, TimeUnit.SECONDS)
            } catch (e: Exception) {
                throw java.util.concurrent.TimeoutException("no invite decision")
            } finally {
                inviteDecision = null
            }
            if (!accept) {
                send(JSONObject().put("type", "reject"))
                teardown()
                return
            }
            send(JSONObject().put("type", if (preferNormal) "accept_normal" else "accept"))
            val msg = recv(ACK_TIMEOUT_MS.toInt())
            when (msg.optString("type")) {
                "manual" -> {
                    send(JSONObject().put("type", "ack"))
                    teardown()
                    onCredsReceived?.invoke(null)   // manual join path
                }
                else -> teardown()
            }
        }
    }

    /** Receiver's answer to the invite card. Called from the main thread. */
    fun respond(accept: Boolean, preferNormal: Boolean) {
        inviteDecision?.complete(Pair(accept, preferNormal))
    }

    fun teardown() {
        if (tornDown) return
        tornDown = true
        groupFormed = false
        runCatching { exchangeSocket?.close() }
        runCatching { exchangeServer?.close() }
        val ch = channel
        if (ch != null) {
            runCatching { pm.stopPeerDiscovery(ch, null) }
            runCatching { pm.clearLocalServices(ch, null) }
            runCatching { pm.clearServiceRequests(ch, null) }
            runCatching { pm.removeGroup(ch, null) }
        }
        if (registered) {
            runCatching { context.unregisterReceiver(this) }
            registered = false
        }
        bus.emit("p2p:closed", null)
    }
}
BLINKER_EOF
cat > android/app/src/main/java/com/bLinker/nasvex/engine/SessionManager.kt <<'BLINKER_EOF'
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
        begin()
        checkPerms()
        // Public-API reality: no app can preset hotspot credentials on ANY
        // Android version, so the P2P exchange always carries a "manual"
        // join instruction; the system-generated SSID/pass arrive with
        // session:manual_code once the hotspot is up.
        creds = null
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
        p2p.onCredsReceived = {
            // Manual path (universal): the sender's screen shows the code,
            // the receiver joins with it - typed once, then the suggestion /
            // system panel take over.
            stopLanStack()
            state(Phase.JOINING)
            bus.emit("session:manual_expected", null)
        }
        p2p.onHandshakeComplete = {
            // P2P is closed and the radio is free - now bring up the hotspot.
            state(Phase.HOTSPOT_STARTING)
            hotspot.start(fast)
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
            creds = startedCreds
            // The system chose the SSID/passphrase (no app can preset them):
            // surface them so the receiver can join. bLinker card, never a
            // system look-alike.
            bus.emit("session:manual_code", JSONObject()
                .put("ssid", startedCreds.ssid)
                .put("pass", startedCreds.pass))
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
            h.postDelayed(r, MANUAL_TIMEOUT_MS)
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
            .put("customHotspotCredentials", false)
            .put("locationServicesOn", locationOn)
            .put("measuredBand", stats?.band ?: JSONObject.NULL)
            .put("measuredLinkMbps", stats?.linkMbps ?: JSONObject.NULL)
    }
}
BLINKER_EOF
cat > android/app/src/main/java/com/bLinker/nasvex/engine/EngineBus.kt <<'BLINKER_EOF'
package com.bLinker.nasvex.engine

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.lang.ref.WeakReference

/**
 * The single bridge between Flutter and the native engine.
 *   MethodChannel "bLinker/engine"        : Flutter -> native
 *   EventChannel  "bLinker/engine/events" : native -> Flutter (JSON string)
 * Events carry {type, data}.
 */
class EngineBus private constructor(val appContext: Context) {

    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var eventChannel: EventChannel? = null
    private var methodChannel: MethodChannel? = null
    private val handlers = HashMap<String, (MethodCall, MethodChannel.Result) -> Unit>()

    private var activityRef: WeakReference<Activity>? = null
    val activity: Activity? get() = activityRef?.get()

    lateinit var permManager: PermissionsManager
        private set
    lateinit var sessionManager: SessionManager
        private set
    @Volatile private var wired = false

    fun on(method: String, handler: (MethodCall, MethodChannel.Result) -> Unit) {
        handlers[method] = handler
    }

    fun attach(activity: Activity, flutter: FlutterEngine) {
        activityRef = WeakReference(activity)
        val dart = flutter.dartExecutor
        eventChannel?.setStreamHandler(null)
        methodChannel?.setMethodCallHandler(null)
        eventChannel = EventChannel(dart, EVENTS).also { channel ->
            channel.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) {
                    sink = events
                    emit("engine:ready", JSONObject().put("sdk", android.os.Build.VERSION.SDK_INT))
                }
                override fun onCancel(args: Any?) { sink = null }
            })
        }
        methodChannel = MethodChannel(dart, METHODS).also { channel ->
            channel.setMethodCallHandler { call, result ->
                val handler = handlers[call.method]
                if (handler == null) { result.notImplemented(); return@setMethodCallHandler }
                try {
                    handler(call, result)
                } catch (t: Throwable) {
                    Log.e(TAG, "method ${call.method} failed", t)
                    result.error("engine", t.message ?: t.javaClass.simpleName, null)
                }
            }
        }
    }

    /** Emit an event to Dart. Safe from any thread. */
    fun emit(type: String, data: Any? = null) {
        val payload = JSONObject()
        payload.put("type", type)
        payload.put("data", if (data == null) JSONObject.NULL else data)
        main.post {
            val s = sink ?: return@post
            try { s.success(payload.toString()) } catch (t: Throwable) {
                Log.w(TAG, "event $type dropped", t)
            }
        }
    }

    fun dispatchPermissionResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        permManager.dispatchResult(requestCode, permissions, grantResults)
    }

    fun dispatchPanelResult(requestCode: Int, resultCode: Int, data: Intent?) {
        sessionManager.join.onPanelResult(requestCode, resultCode, data)
    }

    companion object {
        private const val TAG = "bLinker.EngineBus"
        const val METHODS = "bLinker/engine"
        const val EVENTS = "bLinker/engine/events"

        @Volatile private var instance: EngineBus? = null

        @SuppressLint("StaticFieldLeak") // app context only; Activity is a WeakReference
        fun start(activity: Activity, flutter: FlutterEngine): EngineBus {
            val bus = instance ?: EngineBus(activity.applicationContext).also { instance = it }
            if (!bus.wired) {
                bus.wired = true
                bus.permManager = PermissionsManager(bus)
                bus.sessionManager = SessionManager(activity.applicationContext, bus)
                registerMethods(bus)
            }
            bus.attach(activity, flutter)
            return bus
        }

        fun get(): EngineBus? = instance

        fun shutdown() {
            instance?.sessionManager?.stop(silent = true)
            instance = null
        }

        private fun registerMethods(bus: EngineBus) {
            val perms = bus.permManager
            val session = bus.sessionManager

            // ---- permissions ----------------------------------------------
            // The system permission card is Android's own: "perms.request" goes
            // straight to it. Never customised, never replicated.
            bus.on("perms.state") { _, result -> result.success(perms.state().toString()) }
            bus.on("perms.request") { _, result -> perms.requestSystemPermissions(); result.success(null) }
            bus.on("perms.openSettings") { _, result -> perms.openSystemAppSettings(); result.success(null) }

            // ---- identity / diagnostics ------------------------------------
            bus.on("device.name") { _, result -> result.success(Device.name(bus.appContext)) }
            bus.on("device.setName") { call, result ->
                Device.setName(bus.appContext, call.arguments as? String ?: ""); result.success(null)
            }
            bus.on("diag.hardware") { _, result -> result.success(session.hardwareProbe().toString()) }

            // ---- sessions ----------------------------------------------------
            bus.on("session.startSenderHotspot") { call, result ->
                session.startSenderHotspot(call.argument<String>("mode") ?: "fast"); result.success(null)
            }
            bus.on("session.startSenderLan") { _, result -> session.startSenderLan(); result.success(null) }
            bus.on("session.startReceiver") { _, result -> session.startReceiver(); result.success(null) }
            bus.on("session.p2pConnect") { call, result ->
                session.connectPeer(call.argument<String>("peerId") ?: ""); result.success(null)
            }
            bus.on("session.respondInvite") { call, result ->
                session.respondInvite(
                    call.argument<Boolean>("accept") ?: false,
                    call.argument<Boolean>("preferNormal") ?: false
                ); result.success(null)
            }
            bus.on("session.lanConnect") { call, result ->
                session.lanConnect(
                    call.argument<String>("host") ?: "",
                    call.argument<Int>("port") ?: TcpLink.PORT
                ); result.success(null)
            }
            bus.on("session.joinManual") { call, result ->
                session.joinManual(
                    call.argument<String>("ssid") ?: "",
                    call.argument<String>("pass") ?: ""
                ); result.success(null)
            }
            bus.on("session.joinPanel") { _, result -> session.joinPanel(); result.success(null) }
            bus.on("session.switchMode") { call, result ->
                session.switchMode(call.argument<String>("mode") ?: "normal"); result.success(null)
            }
            bus.on("session.stop") { _, result -> session.stop(); result.success(null) }
            bus.on("session.state") { _, result -> result.success(session.phase()) }
        }
    }
}
BLINKER_EOF
cat > android/app/src/main/AndroidManifest.xml <<'BLINKER_EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">

    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
    <uses-permission android:name="android.permission.CHANGE_WIFI_STATE" />
    <uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />
    <uses-permission
        android:name="android.permission.NEARBY_WIFI_DEVICES"
        android:usesPermissionFlags="neverForLocation"
        android:required="false"
        tools:targetApi="tiramisu" />
    <uses-permission
        android:name="android.permission.ACCESS_FINE_LOCATION"
        android:maxSdkVersion="32"
        android:required="false" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"
        android:required="false" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"
        android:required="false" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC"
        android:required="false" />
    <uses-permission android:name="android.permission.WAKE_LOCK"
        android:required="false" />
    <uses-feature
        android:name="android.hardware.wifi.direct"
        android:required="false" />

    <application
        android:label="bLinker"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher"
        android:enableOnBackInvokedCallback="true"
        tools:targetApi="34">

        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTask"
            android:theme="@style/LaunchTheme"
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            android:hardwareAccelerated="true"
            android:windowSoftInputMode="adjustResize">
            <meta-data
                android:name="io.flutter.embedding.android.NormalTheme"
                android:resource="@style/NormalTheme" />
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

        <meta-data
            android:name="flutterEmbedding"
            android:value="2" />
        <service android:name=".engine.SessionService" android:exported="false" android:foregroundServiceType="connectedDevice"/>
</application>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"/>
</manifest>
BLINKER_EOF
cat > lib/core/routes.dart <<'BLINKER_EOF'
import 'package:flutter/material.dart';
import 'theme.dart';

/// bLinker navigation: FAST horizontal slides between screens
/// (190 ms in / 150 ms out) - no fades, no slow zooms.
class BlPageRoute<T> extends PageRouteBuilder<T> {
  BlPageRoute({required WidgetBuilder builder})
      : super(
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionDuration: const Duration(milliseconds: 190),
          reverseTransitionDuration: const Duration(milliseconds: 150),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(1, 0),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            );
          },
        );
}

Future<T?> blPush<T>(BuildContext context, Widget page) =>
    Navigator.of(context).push<T>(BlPageRoute<T>(builder: (_) => page));

/// Full-screen wrapper for pushed screens: keeps the bLinker background and
/// handles the status-bar inset so the screens themselves stay simple.
class BlScreen extends StatelessWidget {
  final Widget child;
  const BlScreen({super.key, required this.child});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: BlColors.bg,
        body: SafeArea(
          bottom: false,
          child: child,
        ),
      );
}
BLINKER_EOF
cat > lib/widgets/modal.dart <<'BLINKER_EOF'
import 'dart:ui';
import 'package:flutter/material.dart';
import '../core/theme.dart';
import 'buttons.dart';

/// bLinker's own modal - bottom-anchored card over a blurred scrim.
/// FAST: 200 ms in / 150 ms out. The [Material] wrapper (transparent) gives
/// every [Text]/[TextField] inside a proper text style - without it Flutter
/// falls back to the debug default style and draws yellow underlines under
/// the text (this only affected overlays: modals + toasts).
Future<T?> showBlModal<T>(BuildContext context, WidgetBuilder builder) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, __, ___) => const SizedBox.shrink(),
    transitionBuilder: (ctx, anim, __, ___) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: const Cubic(0.22, 1, 0.36, 1),
        reverseCurve: const Cubic(0.4, 0, 1, 1),
      );
      return BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.06), end: Offset.zero)
                .animate(curved),
            child: Builder(builder: (ctx) => _ModalScope(child: builder(ctx))),
          ),
        ),
      );
    },
  );
}

class _ModalScope extends StatelessWidget {
  final Widget child;
  const _ModalScope({required this.child});
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Material(
      type: MaterialType.transparency,
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Container(
          color: const Color(0x8A000000),
          padding: EdgeInsets.fromLTRB(
              14, 20, 14, 20 + mq.viewInsets.bottom),
          alignment: Alignment.bottomCenter,
          child: GestureDetector(
            onTap: () {},
            child: Container(
              constraints: const BoxConstraints(maxWidth: 430, maxHeight: 600),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF211A20),
                borderRadius: BorderRadius.circular(29),
                border: Border.all(color: const Color(0x14FFFFFF)),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x90000000),
                      blurRadius: 90,
                      offset: Offset(0, 30)),
                ],
              ),
              child: SingleChildScrollView(child: child),
            ),
          ),
        ),
      ),
    );
  }
}

class BlModalCard extends StatelessWidget {
  final String? pillIcon;
  final String? pillLabel;
  final String title;
  final String? body;
  final Widget? extra;
  final List<Widget> actions;
  const BlModalCard(
      {super.key,
      this.pillIcon,
      this.pillLabel,
      required this.title,
      this.body,
      this.extra,
      this.actions = const []});
  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              width: 31,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: const Color(0x20FFFFFF),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          if (pillIcon != null) ...[
            BlPill(pillLabel ?? '', icon: pillIcon),
            const SizedBox(height: 8),
          ],
          Text(title, style: ts(22, w: 600, ls: -0.7)),
          if (body != null) ...[
            const SizedBox(height: 10),
            Text(body!, style: ts(12, color: BlColors.muted, h: 1.65)),
          ],
          if (extra != null) extra!,
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 23),
            Row(
              children: [
                for (int i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 11),
                  Expanded(child: actions[i]),
                ],
              ],
            ),
          ],
        ],
      );
}
BLINKER_EOF
cat > lib/widgets/toast.dart <<'BLINKER_EOF'
import 'package:flutter/material.dart';
import '../core/theme.dart';

/// bLinker's in-app notification bubble. Rendered via the root Overlay, so
/// it must carry its own [Material] (transparent): overlay subtrees have no
/// Material ancestor and text would otherwise render with Flutter's debug
/// fallback style (yellow underlines).
class BlToast {
  static OverlayEntry? _entry;
  static void show(BuildContext context, String text) {
    _dismiss();
    final entry = OverlayEntry(builder: (_) => _ToastBubble(text: text));
    _entry = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
    Future.delayed(const Duration(milliseconds: 3500), _dismiss);
  }

  static void _dismiss() {
    _entry?.remove();
    _entry = null;
  }
}

class _ToastBubble extends StatelessWidget {
  final String text;
  const _ToastBubble({required this.text});
  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.only(bottom: 125 + pad.bottom),
        child: IgnorePointer(
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width - 48,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF45323E),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0x14FFFFFF)),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x55000000),
                      blurRadius: 20,
                      offset: Offset(0, 8)),
                ],
              ),
              child: Text(text, style: ts(11), textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    );
  }
}
BLINKER_EOF
cat > lib/screens/shell.dart <<'BLINKER_EOF'
import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../core/routes.dart';
import '../data/store.dart';
import '../widgets/dock.dart';
import '../widgets/toast.dart';
import '../widgets/topbar.dart';
import 'detail_screen.dart';
import 'diagnostics_screen.dart';
import 'home_screen.dart';
import 'settings_screen.dart';

/// The home shell: top bar + radar screen + Send/Receive dock.
/// Settings, Diagnostics and Transfer details are REAL routes now - the
/// Android back button pops them back here instead of exiting the app.
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  bool _historyAll = false;

  void _openSettings({bool autoFocusName = false}) {
    blPush(
      context,
      BlScreen(
        child: SettingsScreen(
          onBack: () => Navigator.of(context).pop(),
          onDiagnostics: () => blPush(
            context,
            BlScreen(
              child: DiagnosticsScreen(
                onBack: () => Navigator.of(context).pop(),
              ),
            ),
          ),
          autoFocusName: autoFocusName,
        ),
      ),
    );
  }

  void _onMode(String mode) {
    BlToast.show(context,
        'Send & Receive go live with the transfer engine — next build.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BlColors.bg,
      body: Column(
        children: [
          BlTopBar(
            name: BlStore.name,
            method: (BlStore.prefs['method'] ?? 'fast') as String,
            onName: () => _openSettings(autoFocusName: true),
            onMethod: () => _openSettings(),
            onSettings: () => _openSettings(),
          ),
          Expanded(
            child: Stack(
              children: [
                HomeScreen(
                  historyAll: _historyAll,
                  onHistoryAll: () =>
                      setState(() => _historyAll = !_historyAll),
                  onDetail: (id) => blPush(
                    context,
                    BlScreen(
                      child: DetailScreen(
                        id: id,
                        onBack: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ),
                ),
                BlDock(mode: null, onMode: _onMode),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
BLINKER_EOF
cat > lib/services/engine.dart <<'BLINKER_EOF'
import '../engine/engine_bridge.dart' as bridge;

/// Convenience wrapper the Phase-1 screens use (onboarding, settings,
/// diagnostics). Talks to native EXCLUSIVELY through the real bridge
/// (channel 'bLinker/engine') - the old direct channel here was misspelled
/// ('blinker/engine') and called a method name that never existed, which
/// made every hardware probe silently fail.
class BlEngine {
  static bool _supports5 = false;
  static bool _p2p = false;
  static int _android = 0;
  static bool _warmed = false;

  /// Live hardware probe, straight from the engine:
  /// {model, sdk, wifi5ghz, wifiDirect, networkSuggestions,
  ///  customHotspotCredentials, locationServicesOn, measuredBand, ...}
  static Future<Map<String, dynamic>> probe() {
    return bridge.Engine.hardwareProbe();
  }

  static Future<void> warm() async {
    if (_warmed) return;
    try {
      final p = await bridge.Engine.hardwareProbe();
      _supports5 = p['wifi5ghz'] == true;
      _p2p = p['wifiDirect'] == true;
      _android = (p['sdk'] as num?)?.toInt() ?? 0;
    } catch (_) {
      // Engine not attached yet (very first frame / tests): defaults stay.
    }
    _warmed = true;
  }

  static bool get supports5GHz => _supports5;
  static bool get p2p => _p2p;
  static int get android => _android;
}
BLINKER_EOF

echo "-- patching small spots --"
if ! grep -q "core/routes.dart" lib/screens/onboarding_screen.dart; then
  sed -i "s|import 'package:flutter/material.dart';|import 'package:flutter/material.dart';\nimport '../core/routes.dart';|" lib/screens/onboarding_screen.dart
  sed -i "s|MaterialPageRoute(builder: (_) => const Shell())|BlPageRoute(builder: (_) => const Shell())|" lib/screens/onboarding_screen.dart
  sed -i "s|probe\['supports5GHz'\]|probe['wifi5ghz']|" lib/screens/onboarding_screen.dart
fi
sed -i "/^import '\.\.\/core\/icons\.dart';$/d" lib/screens/detail_screen.dart
sed -i "s|branches: ain]|branches: [main]|" .github/workflows/build-apk.yml

echo "-- sanity checks --"
grep -q "startLocalOnlyHotspot(object" android/app/src/main/java/com/bLinker/nasvex/engine/HotspotManager.kt && echo "OK hotspot: public overload"
grep -q "android.net.wifi.p2p.WifiP2pManager" android/app/src/main/java/com/bLinker/nasvex/engine/P2pMessenger.kt && echo "OK p2p: package paths"
grep -q "MaterialType.transparency" lib/widgets/modal.dart && echo "OK modal: Material wrap"
grep -q "BlPageRoute" lib/core/routes.dart && echo "OK routes: fast slide"
grep -q "main\]" .github/workflows/build-apk.yml && echo "OK ci: push trigger"
grep -rq "MaterialPageRoute" lib/ && echo "!! MaterialPageRoute still present somewhere" || echo "OK no MaterialPageRoute left"

cat <<'BLINKER_EOF'

Done. Push it:

  git add -A
  git commit -m "fix: engine public-API reality, back navigation, fast slides, overlay text"
  git push

CI: https://github.com/nasirtajudin/blinker/actions
BLINKER_EOF
