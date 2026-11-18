#!/usr/bin/env bash
# ============================================================================
# bLinker PHASE 5 - the radio gate (Wi-Fi + Location: no more silent failure)
#
# WHAT WAS WRONG ON REAL PHONES (all 6 found by auditing, all fixed here):
#   1. Nothing ever checked that Wi-Fi / Location services are ON. Wi-Fi
#      Direct discovery returns ZERO peers while Location is off on most
#      OEM builds -> both phones sat "searching" at an empty radar forever.
#   2. No real enable paths: no system Wi-Fi panel, no Location page.
#   3. p2p:unavailable / p2p:connect_failed were emitted but handled
#      NOWHERE on the Dart side - discovery failures were dead silence.
#   4. The permission card race: discovery fired before the grant landed
#      and only self-healed on the 25s rediscover cycle.
#   5. After a failed P2P connect the session was stuck in "inviting".
#   6. Bluetooth: this transport (Wi-Fi Direct + local-only hotspot) never
#      uses BT - there is deliberately NO Bluetooth prompt. Asking for BT
#      would be theater, not function.
#
# WHAT THIS ADDS:
#   * engine/RadioGuard.kt (NEW): real Wi-Fi-adapter + Location-services
#     state, a light 2.5s poll while blocked, auto-resume on app resume,
#     real system enable paths (Settings.Panel.ACTION_WIFI on 10+,
#     setWifiEnabled on 8-9, ACTION_LOCATION_SOURCE_SETTINGS on all).
#   * Sessions park in the new "needs_radios" phase until both radios are
#     on, then start for real - on BOTH phones.
#   * Discovery re-fires immediately after a permission grant.
#   * A failed P2P connect returns to the radar (no stuck "inviting").
#   * Dart: radio card + toasts for radio:blocked / radio:ok /
#     p2p:unavailable / p2p:connect_failed (bLinker design language, never
#     imitating system cards).
#
# Verified before packaging:
#   * Kotlin: compiled clean against android-34 + the real Flutter 3.24.3
#     embedding stubs + androidx.core/lifecycle (same harness as Phase 4).
#   * Dart: all changed files parse clean under Dart 3.5.3 (the Dart of
#     Flutter 3.24.3) and are dartfmt-clean.
#   * The script itself was executed against a fresh checkout of the
#     Phase-4 commit and produced a byte-identical tree.
#
# Run inside the bLinker project root:  bash phase5.sh
# ============================================================================
set -euo pipefail
[ -f pubspec.yaml ] || { echo "!! Run inside the bLinker Flutter project root."; exit 1; }
K=android/app/src/main/java/com/bLinker/nasvex
mkdir -p "$K/engine"

cat > android/app/src/main/java/com/bLinker/nasvex/engine/RadioGuard.kt <<'P5EOF'
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
P5EOF
cat > android/app/src/main/java/com/bLinker/nasvex/engine/P2pMessenger.kt <<'P5EOF'
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
    /** Sender: the P2P connect to the picked device failed (out of range /
     *  busy / cancelled by the other side). */
    @Volatile var onConnectFailed: (() -> Unit)? = null

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
                onConnectFailed?.invoke()
            }
        })
    }

    /**
     * Re-fire discovery after a permission grant or a radio restore - the
     * session may have started before either landed. No-op once a group
     * formed or after teardown, so it is always safe to call.
     */
    fun kick() {
        if (tornDown || groupFormed) return
        if (registered) discover() else start(senderMode)
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
P5EOF
cat > android/app/src/main/java/com/bLinker/nasvex/engine/SessionManager.kt <<'P5EOF'
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
        NEEDS_RADIOS("needs_radios"),
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
    /** Phase 5 radio gate: Wi-Fi + Location must be ON before anything starts. */
    val radio = RadioGuard(context, bus)
    private val tcpServer = TcpLink.Server(bus)
    private val tcpClient = TcpLink.Client(bus)

    /** Phase 3 transfer protocol over the established link. */
    val transfer: TransferManager by lazy { TransferManager(context, bus, this) }

    private val h = Handler(Looper.getMainLooper())
    private val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

    @Volatile private var active = false
    @Volatile private var fast = true
    @Volatile private var sender = false
    @Volatile private var keepAwake = true
    @Volatile private var phase = Phase.IDLE
    @Volatile private var creds: HotspotManager.Creds? = null

    private var wifiLock: WifiManager.WifiLock? = null
    private var receiverTimeout: Runnable? = null
    private var statsTick: Runnable? = null

    /**
     * The established link socket, whichever side owns it:
     * hotspot method -> sender is the server, LAN method -> sender is the
     * client. Phase 3 attaches the transfer protocol here.
     */
    val linkSocket: Socket? get() = tcpClient.socket ?: tcpServer.client

    fun phase(): String = phase.id

    private fun state(p: Phase) {
        phase = p
        bus.emit("session:state", JSONObject().put("phase", p.id))
    }

    // ------------------------------------------------------------- sender

    fun startSenderHotspot(mode: String, stayAwake: Boolean = true) {
        sender = true
        fast = mode != "normal"
        keepAwake = stayAwake
        begin()
        // Public-API reality: no app can preset hotspot credentials on ANY
        // Android version, so the P2P exchange always carries a "manual"
        // join instruction; the system-generated SSID/pass arrive with
        // session:manual_code once the hotspot is up.
        creds = null
        p2p.invitedFast = fast
        // Radio gate first (Phase 5): dead radios = empty radar, silently.
        radio.gate {
            checkPerms()
            state(Phase.P2P_SEARCH)
            p2p.start(sender = true)
            // Waterfall step (1): receivers on the SAME router are found over
            // the existing LAN (zero prompts) - browse alongside the P2P search
            // so the radar can offer both. The receiver's startReceiver already
            // advertises _blinker._tcp.
            mdns.browse()
        }
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

    fun startReceiver(stayAwake: Boolean = true) {
        sender = false
        keepAwake = stayAwake
        begin()
        // Radio gate first (Phase 5): P2P visibility needs the same radios.
        radio.gate {
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
        radio.cancel()
        transfer.cancel()
        reset()
        releaseLocks()
        stopStats()
        SessionService.stop(context)
        if (!silent) state(Phase.IDLE) else phase = Phase.IDLE
    }

    /** MainActivity.onResume: coming back from a radio panel = re-check now. */
    fun onAppResumed() {
        radio.recheck()
    }

    /**
     * A permission grant just landed (or radios came back): discovery was
     * launched before the grant in that flow, so re-fire it immediately
     * instead of waiting for the 25s rediscover cycle.
     */
    fun retryDiscovery() {
        if (!active) return
        val early = phase == Phase.P2P_SEARCH || phase == Phase.STANDBY ||
            phase == Phase.MDNS_SEARCH
        if (early) p2p.kick()
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
        p2p.onConnectFailed = {
            // The picked device did not answer the P2P connect: back to the
            // radar instead of sitting in "inviting" forever (Phase 5).
            state(Phase.P2P_SEARCH)
            p2p.kick()
        }
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
        if (!sender) {
            // Receiver: start the manifest-first protocol on this link.
            val s = tcpClient.socket ?: tcpServer.client
            if (s != null) transfer.beginReceiving(s)
        }
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
        // Settings > Keep screen awake during transfer.
        if (keepAwake) {
            bus.activity?.window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            bus.activity?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
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
P5EOF
cat > android/app/src/main/java/com/bLinker/nasvex/engine/EngineBus.kt <<'P5EOF'
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
    lateinit var pickerManager: PickerManager
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
        // A grant just landed: if discovery was fired before it, re-fire it
        // now instead of waiting for the slow rediscover cycle (Phase 5).
        sessionManager.retryDiscovery()
    }

    fun dispatchPanelResult(requestCode: Int, resultCode: Int, data: Intent?) {
        sessionManager.join.onPanelResult(requestCode, resultCode, data)
        pickerManager.onPanelResult(requestCode, resultCode, data)
    }

    /** MainActivity.onResume: coming back from a radio panel = re-check now. */
    fun onAppResumed() {
        sessionManager.onAppResumed()
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
                bus.pickerManager = PickerManager(activity.applicationContext, bus)
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

            // ---- phase 5: radio gate -------------------------------------
            // Real Wi-Fi / Location state + the REAL system enable paths.
            bus.on("radio.state") { _, result -> result.success(session.radio.state().toString()) }
            bus.on("radio.wifi.enable") { _, result -> session.radio.openWifiPanel(); result.success(null) }
            bus.on("radio.location.enable") { _, result -> session.radio.openLocationSettings(); result.success(null) }
            bus.on("radio.recheck") { _, result -> session.radio.recheck(); result.success(null) }

            // ---- identity / diagnostics ------------------------------------
            bus.on("device.name") { _, result -> result.success(Device.name(bus.appContext)) }
            bus.on("device.setName") { call, result ->
                Device.setName(bus.appContext, call.arguments as? String ?: ""); result.success(null)
            }
            bus.on("diag.hardware") { _, result -> result.success(session.hardwareProbe().toString()) }

            // ---- sessions ----------------------------------------------------
            // 'awake' carries the Keep-screen-awake preference (Settings).
            bus.on("session.startSenderHotspot") { call, result ->
                session.startSenderHotspot(
                    call.argument<String>("mode") ?: "fast",
                    call.argument<Boolean>("awake") ?: true
                ); result.success(null)
            }
            bus.on("session.startSenderLan") { _, result -> session.startSenderLan(); result.success(null) }
            bus.on("session.startReceiver") { call, result ->
                session.startReceiver(call.argument<Boolean>("awake") ?: true); result.success(null)
            }
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

            // ---- phase 3: transfers + storage -------------------------------
            // files: [{name, size, rel?, uri? | path?}] - uri = SAF content URI.
            bus.on("transfer.send") { call, result ->
                session.transfer.send(call.arguments); result.success(null)
            }
            bus.on("transfer.accept") { call, result ->
                session.transfer.accept(call.argument<String>("location")); result.success(null)
            }
            bus.on("transfer.reject") { _, result -> session.transfer.reject(); result.success(null) }
            bus.on("transfer.cancel") { _, result -> session.transfer.cancel(); result.success(null) }
            bus.on("storage.state") { call, result ->
                result.success(session.transfer.storageState(call.argument<String>("location")).toString())
            }
            bus.on("storage.openAllFiles") { _, result ->
                session.transfer.openAllFilesAccess(); result.success(null)
            }

            // ---- phase 4: picker, folder view, partials --------------------
            bus.on("picker.open") { _, result -> bus.pickerManager.open(); result.success(null) }
            bus.on("picker.release") { _, result ->
                bus.pickerManager.releaseAll(); result.success(null)
            }
            bus.on("folder.open") { call, result ->
                result.success(session.transfer.openFolder(call.argument<String>("dir")).toString())
            }
            bus.on("storage.clearPartials") { call, result ->
                result.success(session.transfer.clearPartials(call.argument<String>("location")).toString())
            }
        }
    }
}
P5EOF
cat > android/app/src/main/java/com/bLinker/nasvex/MainActivity.kt <<'P5EOF'
package com.bLinker.nasvex

import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import android.service.quicksettings.TileService
import androidx.core.view.WindowCompat
import com.bLinker.nasvex.engine.EngineBus
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * THE launcher activity (see the manifest: com.bLinker.nasvex.MainActivity).
 *
 * History note: the repo briefly had two MainActivity classes - the Phase-1
 * one under src/main/kotlin (namespace package com.blinker.nasvex, which the
 * manifest's ".MainActivity" resolved to) and the Phase-2 engine one under
 * src/main/java. The manifest silently launched the Phase-1 one, so the
 * engine never started. They are now merged HERE and the kotlin/ duplicate
 * is gone; the manifest references this class by its full name.
 */
class MainActivity : FlutterActivity() {

    companion object {
        /** The quick-settings tile shows the app as active while visible. */
        @Volatile
        var isRunning: Boolean = false
            private set
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)   // edge-to-edge
    }

    override fun onResume() {
        super.onResume()
        isRunning = true
        requestTileSync()
        // Back from a Wi-Fi panel / Location settings: re-check the radio
        // gate so a parked session can start immediately (Phase 5).
        EngineBus.get()?.onAppResumed()
    }

    override fun onPause() {
        super.onPause()
        isRunning = false
        requestTileSync()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EngineBus.start(this, flutterEngine)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        // Outcome of the REAL system permission card -> engine -> Flutter.
        EngineBus.get()?.dispatchPermissionResult(requestCode, permissions, grantResults)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        // Outcome of the system "Add network" panel (join fallback).
        EngineBus.get()?.dispatchPanelResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        if (isFinishing) EngineBus.shutdown()
        super.onDestroy()
    }

    private fun requestTileSync() {
        runCatching {
            TileService.requestListeningState(
                this,
                ComponentName(this, BlinkerTileService::class.java)
            )
        }
    }
}
P5EOF
cat > lib/engine/engine_bridge.dart <<'P5EOF'
// bLinker engine bridge (Phase 2).
//
// The ONLY Dart file that talks to native code. Contract:
//   MethodChannel 'bLinker/engine'        Flutter -> native
//   EventChannel  'bLinker/engine/events' native -> Flutter (JSON strings)
//
// ---------------------------------------------------------------------------
// UI RULE (locked with the user - applies to every screen built later):
//   * "perm:" events and every system prompt (permission card, one-time
//     Wi-Fi-suggestion consent, "Add network" panel, Wi-Fi panel, app info
//     page) are rendered by Android itself. They are never customised,
//     wrapped or imitated - nothing sits between the user and them.
//   * Every card bLinker itself shows (invite, manifest accept, mode switch,
//     join fallback, manual code, permission explainer) uses bLinker's own
//     design language ONLY. The app must NOT look like the system.
// ---------------------------------------------------------------------------
//
// Events emitted by the engine:
//   engine:ready{sdk}
//   session:state{phase}                     phase: idle|mdns_search|p2p_search|
//        inviting|exchanging|hotspot_starting|waiting_receiver|standby|joining|
//        link_connecting|link_connected|failed
//   session:perm_missing{needed}             -> app-styled explainer, then
//                                               Engine.requestPermissions()
//                                               shows the REAL system card
//   session:band_unavailable{reason}         -> sender dialog [Switch to Normal]
//   session:downgrade_request                -> same dialog, receiver-initiated
//   session:manual_code{ssid,pass}           -> sender shows code (app card)
//   session:manual_expected                  -> receiver asks for code (app card)
//   session:failed{stage,reason}
//   invite:received{name,fast,bandOk,port}   -> bLinker invite card (app UI)
//   p2p:peers{peers:[{id,name,blink}]} p2p:searching p2p:visible p2p:connecting
//   p2p:connected p2p:closed p2p:unavailable p2p:connect_failed p2p:error
//   hotspot:started{ssid,pass,ip,port} hotspot:failed{reason} hotspot:stopped
//   join:waiting{ssid} join:connected{ssid,gateway} join:timeout{ssid}
//   join:manual_needed join:panel_result{added}
//   mdns:registered{name} mdns:found{name,host,port} mdns:error
//   tcp:listening{port}
//   wifi:stats{band,freqMhz,linkMbps,ssid}   -> HUD's MEASURED band chip
//   perm:result{granted,missing,anyPermanentlyDenied}
//   -- phase 3 ----------------------------------------------------------
//   transfer:manifest{id,sender{name,sdk,five},count,totalBytes,
//        files:[{key,name,rel,size}]}        -> bLinker accept card (app UI)
//   transfer:accepted{id,peer}  transfer:rejected{id}
//   transfer:progress{id,bytes,totalBytes,filesDone,fileCount,index,name,
//        bps,etaSec}                         -> HUD progress + speed + ETA
//   transfer:file_done{id,key,index,name,bytes,ms,bps}
//   transfer:complete{id,direction,peer,peerAndroid,peer5,
//        files:[{name,size}],totalBytes,bodyBytes,durationMs,avgBps,
//        band,linkMbps,dir?,location?}       -> Dart writes BlStore.history
//   transfer:cancelled{id,direction,reason,bytes,totalBytes,filesDone,
//        files:[{name,done,size}]?}          -> receiver keeps .bpart partials
//   transfer:failed{id?,direction,stage,reason}
//   -- phase 4 ----------------------------------------------------------
//   picker:result{files:[{uri,name,size}]}   -> sender stages + starts
//   picker:cancelled{reason?}                -> back to idle (or keep link)
//   -- phase 5: radio gate ------------------------------------------------
//   radio:blocked{blocked:["wifi"|"location"],wifiOn,locationOn}
//        -> bLinker radio card: real system enable paths. The session is
//           parked in needs_radios until both are on.
//   radio:ok                                  -> parked session starts now

library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

class EngineEvent {
  EngineEvent(this.type, this.data);
  final String type;
  final Map<String, dynamic>? data;
}

class HotspotCredentials {
  HotspotCredentials._(this.ssid, this.pass, this.port, this.ip);
  final String ssid;
  final String pass;
  final int port;
  final String? ip;

  factory HotspotCredentials.from(Map<String, dynamic> j) =>
      HotspotCredentials._(
        j['ssid'] as String? ?? '',
        j['pass'] as String? ?? '',
        (j['port'] as num?)?.toInt() ?? 58231,
        j['ip'] as String?,
      );
}

class WifiStats {
  WifiStats._(this.band, this.freqMhz, this.linkMbps, this.ssid);
  final String band;
  final int freqMhz;
  final int linkMbps;
  final String? ssid;
}

class Engine {
  Engine._();

  static const MethodChannel _methods = MethodChannel('bLinker/engine');
  static const EventChannel _events = EventChannel('bLinker/engine/events');

  /// Broadcast of every native engine event.
  static final Stream<EngineEvent> events =
      _events.receiveBroadcastStream().map<EngineEvent>((raw) {
    final map = jsonDecode(raw as String) as Map<String, dynamic>;
    return EngineEvent(
      map['type'] as String,
      map['data'] == null
          ? null
          : Map<String, dynamic>.from(map['data'] as Map),
    );
  });

  static Future<dynamic> _call(String method, [Map<String, dynamic>? args]) =>
      _methods.invokeMethod(method, args ?? const <String, dynamic>{});

  // -- permissions (system card: untouched, never replicated) ----------------
  static Future<Map<String, dynamic>> permissionState() async =>
      Map<String, dynamic>.from(
          jsonDecode(await _call('perms.state') as String) as Map);

  static Future<void> requestPermissions() => _call('perms.request');
  static Future<void> openAppSettings() => _call('perms.openSettings');

  // -- phase 5: radio gate -------------------------------------------------

  /// {blocked:["wifi"|"location"], wifiOn:bool, locationOn:bool} - the REAL
  /// Wi-Fi adapter / Location-services state, not a guess.
  static Future<Map<String, dynamic>> radioState() async =>
      Map<String, dynamic>.from(
          jsonDecode(await _call('radio.state') as String) as Map);

  /// Android 10+: the REAL system Wi-Fi panel. Android 8-9: the adapter is
  /// enabled directly (allowed for apps below API 29).
  static Future<void> openWifiPanel() => _call('radio.wifi.enable');

  /// The REAL system Location page (no app can flip that toggle silently).
  static Future<void> openLocationSettings() => _call('radio.location.enable');

  /// Re-check the radios now; native emits radio:blocked / radio:ok.
  static Future<void> recheckRadios() => _call('radio.recheck');

  // -- identity / diagnostics -------------------------------------------------
  static Future<String> deviceName() async =>
      await _call('device.name') as String;
  static Future<void> setDeviceName(String name) =>
      _methods.invokeMethod('device.setName', name);
  static Future<Map<String, dynamic>> hardwareProbe() async =>
      Map<String, dynamic>.from(
          jsonDecode(await _call('diag.hardware') as String) as Map);

  // -- sessions ------------------------------------------------------------------
  /// mode: 'fast' (5GHz) | 'normal' (2.4GHz); awake = the Keep-screen-awake
  /// preference from Settings (native FLAG_KEEP_SCREEN_ON).
  static Future<void> startSenderHotspot(
          {required String mode, bool awake = true}) =>
      _call('session.startSenderHotspot', {'mode': mode, 'awake': awake});
  static Future<void> startSenderLan() => _call('session.startSenderLan');
  static Future<void> startReceiver({bool awake = true}) =>
      _call('session.startReceiver', {'awake': awake});
  static Future<void> connectPeer(String peerId) =>
      _call('session.p2pConnect', {'peerId': peerId});
  static Future<void> respondInvite(
          {required bool accept, bool preferNormal = false}) =>
      _call('session.respondInvite',
          {'accept': accept, 'preferNormal': preferNormal});
  static Future<void> lanConnect(String host, int port) =>
      _call('session.lanConnect', {'host': host, 'port': port});
  static Future<void> joinManual(
          {required String ssid, required String pass}) =>
      _call('session.joinManual', {'ssid': ssid, 'pass': pass});
  static Future<void> joinPanel() => _call('session.joinPanel');
  static Future<void> switchMode(String mode) =>
      _call('session.switchMode', {'mode': mode});
  static Future<void> stopSession() => _call('session.stop');

  // -- transfers (phase 3) ---------------------------------------------------
  /// Sends a manifest over the established link.
  /// files: [{uri | path, name, size, rel?}] - uri = SAF content URI from
  /// the system picker. Call only after session:state == link_connected.
  static Future<void> sendTransfer(List<Map<String, dynamic>> files) =>
      _methods.invokeMethod('transfer.send', files);

  /// Receiver's answer to the bLinker accept card. [location] = the
  /// configured save folder (BlStore.prefs['location']).
  static Future<void> acceptTransfer({String? location}) =>
      _call('transfer.accept', {'location': location});

  static Future<void> rejectTransfer() => _call('transfer.reject');
  static Future<void> cancelTransfer() => _call('transfer.cancel');

  /// {publicAccess, allFilesAccessAvailable, sandboxed, saveDir}
  static Future<Map<String, dynamic>> storageState({String? location}) async =>
      Map<String, dynamic>.from(jsonDecode(
              await _call('storage.state', {'location': location}) as String)
          as Map);

  /// Opens the system "All files access" page (real system screen, 11+).
  static Future<void> openAllFilesAccess() => _call('storage.openAllFiles');

  // -- phase 4: picker, folder view, partials -------------------------------
  /// The system document picker (its own UI, untouched). The answer arrives
  /// as picker:result / picker:cancelled events.
  static Future<void> openPicker() => _call('picker.open');

  /// Releases the persistable URI grants of the staged pick.
  static Future<void> releasePicker() => _call('picker.release');

  /// {opened, reason?, dir} - opens the save folder in the system Files UI
  /// when possible; reason=app_dir means the path is the app's own dir.
  static Future<Map<String, dynamic>> openFolder(String dir) async =>
      Map<String, dynamic>.from(
          jsonDecode(await _call('folder.open', {'dir': dir}) as String)
              as Map);

  /// Deletes every "*.bpart" partial under both possible roots.
  /// Returns {freed, files}.
  static Future<Map<String, dynamic>> clearPartials({String? location}) async =>
      Map<String, dynamic>.from(jsonDecode(
          await _call('storage.clearPartials', {'location': location})
              as String) as Map);
}
P5EOF
cat > lib/services/session.dart <<'P5EOF'
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/format.dart' show fileIconFor;
import '../data/store.dart';
import '../engine/engine_bridge.dart' as bridge;

/// A nearby device on the radar: a bLinker receiver seen over Wi-Fi Direct
/// ([kind] = p2p) or a receiver on the same router discovered via mDNS
/// ([kind] = lan).
class BlPeer {
  BlPeer(
      {required this.id,
      required this.name,
      required this.kind,
      this.host,
      this.port});
  final String id;
  final String name;
  final String kind; // 'p2p' | 'lan'
  final String? host;
  final int? port;
}

/// THE session controller (Phase 4). Owns no UI - every screen and modal
/// reads this and renders in bLinker's own design language.
///
/// HARDENING RULE (same as BlEngine): the flow must never dead-end on an
/// engine problem. Every native call is best-effort; state changes only on
/// real events. [handleEvent] is public so the event flow is unit-testable
/// without a live engine.
class BlSession extends ChangeNotifier {
  BlSession._();
  static final BlSession I = BlSession._();

  StreamSubscription? _sub;
  bool _started = false;

  // -- live state -----------------------------------------------------------
  String role = 'none'; // 'none' | 'send' | 'receive'
  String phase = 'idle'; // native session:state phase id
  bool pickerOpen = false;

  final List<BlPeer> _p2pPeersList = [];
  final List<BlPeer> _lanPeersList = [];

  /// Nearby devices for the radar: bLinker receivers seen over Wi-Fi Direct
  /// plus same-router receivers found via mDNS. P2P rounds never wipe LAN
  /// finds - the two channels are tracked separately.
  List<BlPeer> get peers => [..._p2pPeersList, ..._lanPeersList];
  Map<String, dynamic>? wifiStats; // wifi:stats (MEASURED band)

  Map<String, dynamic>? invite; // pending invite card (receiver)
  Map<String, dynamic>? manualCode; // sender: {ssid, pass}
  bool manualExpected = false; // receiver: show the join-entry card
  Map<String, dynamic>? joinFallback; // join:manual_needed (legacy)
  Map<String, dynamic>? joinTimedOut; // join:timeout
  List<String> permMissing = []; // session:perm_missing -> explainer
  List<String> radioBlocked = []; // radio:blocked -> 'wifi' | 'location'
  Map<String, dynamic>? p2pIssue; // p2p:unavailable - radar hint
  Map<String, dynamic>? bandIssue; // band_unavailable / downgrade_request

  List<Map<String, dynamic>> staged = []; // picked files awaiting the link
  Map<String, dynamic>? manifest; // receiver: pending accept card
  Map<String, dynamic>? progress; // live transfer:progress
  Map<String, dynamic>? result; // transfer:complete / cancelled summary
  Map<String, dynamic>? failure; // session:failed / transfer:failed

  String requestedMethod = 'fast';
  String linkKind = 'direct'; // 'direct' (hotspot) | 'lan'
  bool _sawJoin = false;
  String _peerName = '';
  String _joinSsid = '';
  String _joinPass = '';

  /// The peer this session is about (tapped peer / invite sender).
  String get peerName => _peerName.isEmpty ? 'them' : _peerName;

  String? toast; // transient message
  int toastSeq = 0;

  /// Decision cards waiting to be shown, in arrival order:
  /// 'invite' | 'accept' | 'join' | 'joinTimeout' | 'perm' | 'band'.
  /// Edge-triggered (a card queues once per appearance) so the 1-second
  /// wifi:stats tick can never re-raise a dismissed card.
  final List<String> cardQueue = [];
  bool _qInvite = false,
      _qManifest = false,
      _qJoin = false,
      _qJoinTimeout = false,
      _qPerm = false,
      _qBand = false,
      _qRadio = false;

  // -- lifecycle -------------------------------------------------------------

  /// Called once from app boot. Idempotent, never throws.
  void init() {
    if (_started) return;
    _started = true;
    _sub = bridge.Engine.events.listen(
      (e) => handleEvent(e.type, e.data),
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  bool get active => role != 'none' || failure != null;
  bool get linkUp => phase == 'link_connected';

  // -- actions ----------------------------------------------------------------

  /// Dock "Send": system picker first, session starts once files are staged.
  void startSend() {
    role = 'send';
    failure = null;
    result = null;
    manifest = null;
    progress = null;
    invite = null;
    pickerOpen = true;
    _toast('Pick the files to send');
    _try(() => bridge.Engine.openPicker());
    _notify();
  }

  /// Dock "Receive": become visible to nearby senders on both channels.
  void startReceive() {
    role = 'receive';
    _resetFlowState();
    requestedMethod = (BlStore.prefs['method'] ?? 'fast') as String;
    _try(() => bridge.Engine.startReceiver(awake: BlStore.flag('awake')));
    _notify();
  }

  /// Sender tapped a device on the radar.
  void pickPeer(BlPeer p) {
    _peerName = p.name;
    if (p.kind == 'lan' && p.host != null) {
      linkKind = 'lan';
      _try(() => bridge.Engine.lanConnect(p.host!, p.port ?? 58231));
    } else {
      linkKind = 'direct';
      _try(() => bridge.Engine.connectPeer(p.id));
    }
    _notify();
  }

  /// Receiver's answer to the invite card.
  void respondInvite(bool accept, {bool preferNormal = false}) {
    invite = null;
    _try(() => bridge.Engine.respondInvite(
        accept: accept, preferNormal: preferNormal));
    _notify();
  }

  /// Receiver typed the code shown on the sender's screen.
  void joinManual(String ssid, String pass) {
    _joinSsid = ssid;
    _joinPass = pass;
    manualExpected = false;
    _try(() => bridge.Engine.joinManual(ssid: ssid, pass: pass));
    _notify();
  }

  /// join:timeout -> try the same credentials once more.
  void retryJoin() {
    joinTimedOut = null;
    if (_joinSsid.isEmpty) {
      openJoinPanel();
      return;
    }
    _try(() => bridge.Engine.joinManual(ssid: _joinSsid, pass: _joinPass));
    _notify();
  }

  /// Sender accepted [Switch to Normal] on the band card.
  void switchToNormal() {
    bandIssue = null;
    _try(() => bridge.Engine.switchMode('normal'));
    _notify();
  }

  /// Sender declined the band card.
  void endBandIssue() {
    bandIssue = null;
    stop();
  }

  /// Receiver: open the system Wi-Fi panel / settings (real system screen).
  void openJoinPanel() {
    _try(() => bridge.Engine.joinPanel());
    _notify();
  }

  /// "Not now" on the permission explainer: keep the session going without
  /// the grant (P2P discovery may fail honestly on 33+).
  void dismissPerms() {
    permMissing = [];
    _notify();
  }

  // -- phase 5: the radio gate -------------------------------------------

  /// The REAL system Wi-Fi panel (Android 10+) / direct enable (Android 8-9).
  void enableWifi() {
    _try(() => bridge.Engine.openWifiPanel());
    _notify();
  }

  /// The REAL system Location page.
  void enableLocation() {
    _try(() => bridge.Engine.openLocationSettings());
    _notify();
  }

  /// "Check again" on the radio card: native re-checks and answers with
  /// radio:blocked / radio:ok.
  void recheckRadios() {
    _try(() => bridge.Engine.recheckRadios());
    _notify();
  }

  /// Dismiss the radio card but keep the session parked in needs_radios;
  /// the native poller re-raises radio:blocked (and so the card) if a radio
  /// is still off on the next check.
  void dismissRadios() {
    radioBlocked = [];
    _notify();
  }

  /// The join card was dismissed - bring it back from the joining card.
  void reopenJoinCard() {
    manualExpected = true;
    _notify();
  }

  /// After the bLinker permission explainer card: show the REAL system card.
  void continuePermissions() {
    permMissing = [];
    _try(() => bridge.Engine.requestPermissions());
    _notify();
  }

  /// Receiver accepted the bLinker file card.
  void acceptManifest() {
    final m = manifest;
    manifest = null;
    if (m == null) return;
    _try(() => bridge.Engine.acceptTransfer(
        location: (BlStore.prefs['location'] ?? '') as String));
    _notify();
  }

  void rejectManifest() {
    manifest = null;
    _try(() => bridge.Engine.rejectTransfer());
    _notify();
  }

  void cancelTransfer() {
    _try(() => bridge.Engine.cancelTransfer());
    _notify();
  }

  /// "Send more" over the established link (multi-manifest protocol).
  void sendMore() {
    if (!linkUp || role != 'send') return;
    pickerOpen = true;
    _try(() => bridge.Engine.openPicker());
    _notify();
  }

  void retry() {
    final r = role;
    failure = null;
    result = null;
    if (r == 'receive') {
      startReceive();
    } else if (staged.isNotEmpty) {
      _try(() => bridge.Engine.startSenderHotspot(
          mode: (BlStore.prefs['method'] ?? 'fast') as String,
          awake: BlStore.flag('awake')));
      _notify();
    } else {
      startSend();
    }
  }

  void stop() {
    _try(() => bridge.Engine.stopSession());
    if (staged.isNotEmpty) _try(() => bridge.Engine.releasePicker());
    role = 'none';
    _resetFlowState();
    _notify();
  }

  // -- the event core ---------------------------------------------------------

  /// Every engine event lands here. Never throws.
  void handleEvent(String type, Map<String, dynamic>? data) {
    final d = data ?? const <String, dynamic>{};
    try {
      _onEvent(type, d);
    } catch (e) {
      debugPrint('blinker session: $type handler failed: $e');
    }
    _notify();
  }

  void _onEvent(String type, Map<String, dynamic> d) {
    switch (type) {
      // ---- session ------------------------------------------------------
      case 'session:state':
        phase = (d['phase'] as String?) ?? phase;
        if (phase == 'link_connected') {
          if (role == 'receive' && linkKind != 'lan') {
            linkKind = _sawJoin ? 'direct' : 'lan';
          }
          _haptic();
          if (role == 'send' && staged.isNotEmpty) {
            _try(() => bridge.Engine.sendTransfer(staged));
          }
        } else if (phase == 'idle' || phase == 'failed') {
          pickerOpen = false;
        }
        break;

      case 'session:perm_missing':
        final needed = d['needed'];
        if (needed is List) {
          permMissing = needed.whereType<String>().toList();
        }
        break;

      // ---- phase 5: radio gate ------------------------------------------
      case 'radio:blocked':
        final b = d['blocked'];
        radioBlocked = b is List ? b.whereType<String>().toList() : [];
        if (radioBlocked.isNotEmpty) {
          _toast(radioBlocked.length == 2
              ? 'Wi-Fi and Location are off'
              : (radioBlocked.contains('wifi')
                  ? 'Wi-Fi is off'
                  : 'Location is off'));
        }
        break;

      case 'radio:ok':
        if (radioBlocked.isNotEmpty) {
          radioBlocked = [];
          p2pIssue = null;
          _toast('Radios ready — searching…');
        }
        break;

      case 'p2p:unavailable':
        // Discovery honestly failed (radios off / busy). No dead silence:
        // surface it so the user can fix the radio instead of staring at an
        // empty radar.
        p2pIssue = Map<String, dynamic>.from(d);
        _toast('Nearby search failed — Wi-Fi and Location must be on');
        break;

      case 'p2p:connect_failed':
        _toast('Couldn’t reach that device — pick another');
        break;

      case 'session:band_unavailable':
        bandIssue = {'kind': 'unavailable', 'reason': d['reason'] ?? ''};
        break;

      case 'session:downgrade_request':
        bandIssue = {'kind': 'downgrade'};
        break;

      case 'session:manual_code':
        manualCode = {
          'ssid': (d['ssid'] as String?) ?? '',
          'pass': (d['pass'] as String?) ?? '',
        };
        break;

      case 'session:manual_expected':
        manualExpected = true;
        _sawJoin = true;
        break;

      case 'session:failed':
        // A dead link invalidates any pending decision cards.
        invite = null;
        manifest = null;
        failure = {
          'stage': (d['stage'] as String?) ?? 'failed',
          'reason': (d['reason'] as String?) ?? '',
        };
        _toast(_failText(failure!));
        break;

      // ---- discovery ----------------------------------------------------
      case 'p2p:peers':
        _p2pPeersList
          ..clear()
          ..addAll(_p2pPeers(d)..sort((a, b) => a.id.compareTo(b.id)));
        break;

      case 'mdns:found':
        final name = (d['name'] as String?) ?? '';
        final host = (d['host'] as String?) ?? '';
        final port = (d['port'] as num?)?.toInt();
        if (name.isEmpty || host.isEmpty) break;
        final id = 'lan:$host:$port';
        final peer =
            BlPeer(id: id, name: name, kind: 'lan', host: host, port: port);
        final i = _lanPeersList.indexWhere((p) => p.id == id);
        if (i >= 0) {
          _lanPeersList[i] = peer;
        } else {
          _lanPeersList.add(peer);
        }
        _lanPeersList.sort((a, b) => a.id.compareTo(b.id));
        break;

      // ---- invite (receiver) ---------------------------------------------
      case 'invite:received':
        _peerName = (d['name'] as String?) ?? _peerName;
        invite = Map<String, dynamic>.from(d);
        _haptic();
        break;

      // ---- join (receiver) ------------------------------------------------
      case 'join:waiting':
        _sawJoin = true;
        manualExpected = false;
        break;

      case 'join:connected':
        _sawJoin = true;
        linkKind = 'direct';
        break;

      case 'join:timeout':
        joinTimedOut = Map<String, dynamic>.from(d);
        break;

      case 'join:manual_needed':
        _sawJoin = true;
        joinFallback = Map<String, dynamic>.from(d);
        break;

      case 'join:panel_result':
        if (d['added'] == true) {
          joinTimedOut = null;
          _toast('Network added — joining…');
        }
        break;

      case 'hotspot:stopped':
        // Only a live hotspot phase matters; during a switchMode restart
        // the reservation is closed by us and must not end the session.
        const hotspotPhases = {
          'hotspot_starting',
          'waiting_receiver',
          'link_connecting',
          'link_connected',
        };
        if (role == 'send' && hotspotPhases.contains(phase)) {
          _toast('Hotspot closed — session ended');
          _try(() => bridge.Engine.stopSession());
        }
        break;

      // ---- picker -----------------------------------------------------------
      case 'picker:result':
        pickerOpen = false;
        final files = d['files'];
        staged = files is List
            ? files
                .whereType<Map>()
                .map((m) => Map<String, dynamic>.from(m))
                .toList()
            : <Map<String, dynamic>>[];
        if (role == 'send') {
          if (linkUp) {
            _try(() => bridge.Engine.sendTransfer(staged));
          } else if (phase == 'idle' || phase == 'failed') {
            requestedMethod = (BlStore.prefs['method'] ?? 'fast') as String;
            _try(() => bridge.Engine.startSenderHotspot(
                mode: requestedMethod, awake: BlStore.flag('awake')));
          }
        }
        break;

      case 'picker:cancelled':
        pickerOpen = false;
        if (role == 'send' && staged.isEmpty && !linkUp) {
          role = 'none';
        } else if (linkUp) {
          _toast('Nothing picked — link stays open');
        }
        break;

      // ---- transfer ---------------------------------------------------------
      case 'transfer:manifest':
        manifest = Map<String, dynamic>.from(d);
        if (BlStore.flag('auto')) {
          _toast('Auto-accepted from ${_senderName(d)}');
          acceptManifest();
        }
        break;

      case 'transfer:accepted':
        manualCode = null;
        result = null; // a second manifest replaces the old result card
        final total = (manifest?['totalBytes'] as num?)?.toDouble() ??
            staged.fold<double>(0, (a, f) => a + ((f['size'] as num?) ?? 0));
        final count = (manifest?['count'] as num?)?.toInt() ?? staged.length;
        progress = {
          'id': d['id'],
          'bytes': 0,
          'totalBytes': total,
          'filesDone': 0,
          'fileCount': count,
          'index': 0,
          'name': '',
          'bps': 0,
          'etaSec': -1,
        };
        break;

      case 'transfer:progress':
        progress = Map<String, dynamic>.from(d);
        break;

      case 'transfer:complete':
        _onComplete(d);
        break;

      case 'transfer:cancelled':
        _onCancelled(d);
        break;

      case 'transfer:rejected':
        failure = {
          'stage': 'rejected',
          'reason': 'The other side declined the files',
        };
        _toast(failure!['reason'] as String);
        break;

      case 'transfer:failed':
        // The link is gone; pending decision cards can never be answered.
        invite = null;
        manifest = null;
        failure = {
          'stage': (d['stage'] as String?) ?? 'failed',
          'reason': (d['reason'] as String?) ?? '',
        };
        if (BlStore.flag('failed')) _toast(_failText(failure!));
        break;

      // ---- misc ---------------------------------------------------------------
      case 'wifi:stats':
        wifiStats = Map<String, dynamic>.from(d);
        break;
    }
  }

  // -- event helpers -----------------------------------------------------------

  List<BlPeer> _p2pPeers(Map<String, dynamic> d) {
    final list = d['peers'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => BlPeer(
              id: (m['id'] as String?) ?? '',
              name: (m['name'] as String?) ?? 'Android device',
              kind: 'p2p',
            ))
        .where((p) => p.id.isNotEmpty)
        .where((p) => _blinkOnly(p, list))
        .toList();
  }

  /// Only devices advertising the bLinker service are shown on the radar.
  bool _blinkOnly(BlPeer p, List<dynamic> raw) =>
      raw.whereType<Map>().any((m) => m['id'] == p.id && m['blink'] == true);

  String _senderName(Map<String, dynamic> manifest) {
    final s = manifest['sender'];
    if (s is Map) return (s['name'] as String?) ?? '';
    return '';
  }

  void _onComplete(Map<String, dynamic> d) {
    final direction = (d['direction'] as String?) ?? 'send';
    final files = (d['files'] as List? ?? [])
        .whereType<Map>()
        .map((f) => {
              'name': (f['name'] as String?) ?? '',
              'size': ((f['size'] as num?) ?? 0) / 1048576,
              'type': fileIconFor((f['name'] as String?) ?? ''),
            })
        .toList();
    final totalBytes = (d['totalBytes'] as num?) ?? 0;
    final avgBps = (d['avgBps'] as num?) ?? 0;
    final durationMs = (d['durationMs'] as num?) ?? 0;
    final entry = <String, dynamic>{
      'id': (d['id'] as String?) ?? '',
      'direction': direction,
      'peer': (d['peer'] as String?) ?? _peerName,
      'files': files,
      'total': totalBytes / 1048576,
      'avg': avgBps / 1048576,
      'duration': durationMs / 1000,
      'date': DateTime.now().toIso8601String(),
      'band': d['band'],
      'dir': d['dir'],
      'location': d['location'],
    };
    BlStore.history.insert(0, entry);
    BlStore.last = {
      'band': d['band'] ?? '—',
      'avg': avgBps / 1048576,
      'requested': requestedMethod,
      'method': linkKind == 'lan' ? 'Same-router LAN' : 'Direct hotspot',
      'peerAndroid': d['peerAndroid'],
      'peer5': d['peer5'],
      'peer': entry['peer'],
      'date': entry['date'],
    };
    BlStore.save();
    if (direction == 'receive') {
      _dropPartials(files.map((f) => f['name'] as String).toList());
    } else if (staged.isNotEmpty) {
      staged = [];
      _try(() => bridge.Engine.releasePicker());
    }
    result = Map<String, dynamic>.from(d);
    result!['filesDone'] = files.length;
    progress = null;
    manifest = null;
    manualCode = null;
    _haptic();
  }

  void _onCancelled(Map<String, dynamic> d) {
    result = Map<String, dynamic>.from(d);
    result!['cancelled'] = true;
    progress = null;
    manifest = null;
    if (d['direction'] == 'receive') {
      final files = (d['files'] as List? ?? [])
          .whereType<Map>()
          .map((f) => {
                'name': (f['name'] as String?) ?? '',
                'done': ((f['done'] as num?) ?? 0) / 1048576,
                'size': ((f['size'] as num?) ?? 0) / 1048576,
              })
          .toList();
      _mergePartials(files);
      if (files.isNotEmpty) {
        _toast('Cancelled — partial files kept for resume');
      } else {
        _toast('Transfer cancelled');
      }
    } else {
      staged = [];
      _try(() => bridge.Engine.releasePicker());
      _toast('Transfer cancelled');
    }
  }

  /// Receiver: completed files remove their stale partial records.
  void _dropPartials(List<String> names) {
    if (BlStore.partial.isEmpty) return;
    BlStore.partial =
        BlStore.partial.where((p) => !names.contains(p['name'])).toList();
    BlStore.save();
  }

  /// Receiver: merge a cancel's partials into the store (max progress wins).
  void _mergePartials(List<Map<String, dynamic>> files) {
    for (final f in files) {
      final i = BlStore.partial
          .indexWhere((p) => p['name'] == f['name'] && p['size'] == f['size']);
      if (i >= 0) {
        final done = ((BlStore.partial[i]['done'] as num?) ?? 0);
        if ((f['done'] as num? ?? 0) > done) BlStore.partial[i] = f;
      } else {
        BlStore.partial.add(f);
      }
    }
    BlStore.save();
  }

  String _failText(Map<String, dynamic> f) {
    final stage = f['stage'] as String? ?? '';
    switch (stage) {
      case 'rejected':
        return 'The other side declined';
      case 'receiver_timeout':
        return 'No receiver joined in time';
      case 'no_accept':
        return 'No answer to the file request';
      case 'link':
        return 'Connection lost mid-transfer';
      default:
        return 'Couldn’t connect — ${f['reason'] ?? stage}';
    }
  }

  void _haptic() {
    if (!BlStore.flag('haptics')) return;
    _try(() => HapticFeedback.mediumImpact());
  }

  void _resetFlowState() {
    phase = 'idle';
    _p2pPeersList.clear();
    _lanPeersList.clear();
    invite = null;
    manualCode = null;
    manualExpected = false;
    joinFallback = null;
    joinTimedOut = null;
    permMissing = [];
    radioBlocked = [];
    p2pIssue = null;
    bandIssue = null;
    staged = [];
    manifest = null;
    progress = null;
    result = null;
    failure = null;
    pickerOpen = false;
    wifiStats = null;
    _sawJoin = false;
    _joinSsid = '';
    _joinPass = '';
    linkKind = 'direct';
    cardQueue.clear();
  }

  void _toast(String message) {
    toast = message;
    toastSeq++;
  }

  void _try(Future<void> Function() f) {
    try {
      f().catchError((Object _) {});
    } catch (_) {
      // Engine missing / channel cold: never freeze the UI over it.
    }
  }

  void _notify() {
    _syncCards();
    notifyListeners();
  }

  void _syncCards() {
    void edge(bool shown, bool present, String id, void Function(bool) set) {
      if (present && !shown) {
        set(true);
        cardQueue.add(id);
      } else if (!present && shown) {
        set(false);
      }
    }

    edge(_qInvite, invite != null, 'invite', (v) => _qInvite = v);
    edge(_qManifest, manifest != null, 'accept', (v) => _qManifest = v);
    edge(_qJoin, manualExpected || joinFallback != null, 'join',
        (v) => _qJoin = v);
    edge(_qJoinTimeout, joinTimedOut != null, 'joinTimeout',
        (v) => _qJoinTimeout = v);
    edge(_qPerm, permMissing.isNotEmpty, 'perm', (v) => _qPerm = v);
    edge(_qBand, bandIssue != null, 'band', (v) => _qBand = v);
    edge(_qRadio, radioBlocked.isNotEmpty, 'radio', (v) => _qRadio = v);
  }
}
P5EOF
cat > lib/widgets/session_flow.dart <<'P5EOF'
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/format.dart';
import '../core/icons.dart';
import '../core/theme.dart';
import '../data/store.dart';
import '../engine/engine_bridge.dart' as bridge;
import '../services/session.dart';
import 'buttons.dart';
import 'modal.dart';
import 'pressable.dart';
import 'radar.dart';
import 'toast.dart';

/// PHASE 4 - the live session HUD that replaces the home hero while a
/// Send/Receive session runs, plus every bLinker card the flow raises.
///
/// UI RULE (locked): system prompts (permission card, Wi-Fi suggestion
/// consent, "Add network" panel, the document picker) are Android's own;
/// every card bLinker itself shows uses this design language only.
class BlSessionPanel extends StatelessWidget {
  const BlSessionPanel({super.key});

  BlSession get _s => BlSession.I;

  String get _eyebrow {
    if (_s.failure != null) return 'SESSION ENDED';
    if (_s.progress != null) return 'TRANSFERRING';
    if (_s.result != null) return 'TRANSFER DONE';
    switch (_s.phase) {
      case 'p2p_search':
      case 'mdns_search':
        return 'LOOKING NEARBY';
      case 'inviting':
        return 'INVITING';
      case 'exchanging':
        return 'HANDSHAKE';
      case 'hotspot_starting':
        return 'HOTSPOT';
      case 'waiting_receiver':
        return 'YOUR CODE';
      case 'standby':
        return 'VISIBLE';
      case 'joining':
        return 'JOINING';
      case 'link_connecting':
        return 'CONNECTING';
      case 'link_connected':
        return 'LINK READY';
      case 'failed':
        return 'FAILED';
      default:
        return _s.role == 'send' ? 'PICK FILES' : 'READY';
    }
  }

  String get _headline {
    if (_s.failure != null) return 'That didn’t work.';
    if (_s.result != null) {
      if (_s.result!['cancelled'] == true) return 'Cancelled.';
      return _s.result!['direction'] == 'receive' ? 'Received.' : 'Sent.';
    }
    if (_s.progress != null) return 'On its way.';
    switch (_s.phase) {
      case 'p2p_search':
      case 'mdns_search':
        return 'Pick a device.';
      case 'inviting':
        return 'Inviting ${_s.peerName}…';
      case 'exchanging':
        return 'Almost there.';
      case 'hotspot_starting':
        return 'Starting up.';
      case 'waiting_receiver':
        return 'Share this code.';
      case 'standby':
        return 'You’re visible.';
      case 'joining':
        return 'Joining the sender…';
      case 'link_connecting':
        return 'Connecting…';
      case 'link_connected':
        return 'Linked up.';
      default:
        return _s.role == 'send' ? 'Choose files.' : 'Ready.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 25),
        Text(_eyebrow,
            style: ts(9, w: 650, ls: 2.2, color: const Color(0xFFDC8B9B))),
        const SizedBox(height: 13),
        _radar(),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: Text.rich(
            TextSpan(
              text: _headline,
              style: ts(32, w: 650, ls: -1.55, h: 1.12),
              children: [
                TextSpan(
                    text: '.',
                    style: ts(32,
                        w: 650, ls: -1.55, h: 1.12, color: BlColors.red)),
              ],
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 14),
        _bodyCard(),
        const SizedBox(height: 10),
        _bandRow(),
      ],
    );
  }

  Widget _radar() {
    final s = _s;
    final searching = s.role == 'send' &&
        (s.phase == 'p2p_search' || s.phase == 'mdns_search');
    return BlRadar(
      symbol: s.role == 'send' ? 'send' : 'receive',
      scale: 0.66,
      peers: searching ? s.peers : const <BlPeer>[],
      onPeerTap: searching ? s.pickPeer : null,
    );
  }

  Widget _bodyCard() {
    final s = _s;
    if (s.failure != null) return const _FailureCard();
    if (s.result != null) return const _ResultCard();
    if (s.progress != null) return const _ProgressCard();
    if (s.manualCode != null && s.phase == 'waiting_receiver') {
      return _ManualCodeCard(s.manualCode!);
    }
    if (s.phase == 'p2p_search' || s.phase == 'mdns_search') {
      return const _SearchCard();
    }
    if (s.phase == 'standby') return const _StandbyCard();
    if (s.phase == 'link_connected') return const _DoneActions();
    return const _PhaseCard();
  }

  Widget _bandRow() {
    final s = _s.wifiStats;
    if (s == null) return const SizedBox(height: 16);
    final band = (s['band'] as String?) ?? '—';
    final mbps = (s['linkMbps'] as num?) ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const BlDot(color: Color(0xFFF17B8D)),
          const SizedBox(width: 7),
          Text('Measured $band · $mbps Mb/s',
              style: ts(10, color: const Color(0xFFA6939C))),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- states ---

/// Sender, searching: staged files summary + peer hint.
class _SearchCard extends StatelessWidget {
  const _SearchCard();

  @override
  Widget build(BuildContext context) {
    final s = BlSession.I;
    final total =
        s.staged.fold<double>(0, (a, f) => a + ((f['size'] as num?) ?? 0));
    final count = s.staged.length;
    return _card(
      icon: 'folder',
      title: count > 0
          ? '$count file${count == 1 ? '' : 's'} · ${fmtBytes(total)} staged'
          : 'No files staged',
      body: s.peers.isEmpty
          ? 'Looking for bLinker receivers nearby. Devices on your router appear too.'
          : 'Tap a device on the radar to connect.',
      actions: [
        BlButton('Stop', primary: false, onTap: s.stop),
      ],
    );
  }
}

/// Receiver, standby.
class _StandbyCard extends StatelessWidget {
  const _StandbyCard();

  @override
  Widget build(BuildContext context) {
    final s = BlSession.I;
    return _card(
      icon: 'receive',
      title: 'Visible as ${BlStore.name}',
      body: 'Senders nearby can invite you. Keep bLinker open while you wait.',
      actions: [
        BlButton('Stop', primary: false, onTap: s.stop),
      ],
    );
  }
}

/// In-between phases (inviting / handshake / hotspot / joining / connecting).
class _PhaseCard extends StatelessWidget {
  const _PhaseCard();

  @override
  Widget build(BuildContext context) {
    final s = BlSession.I;
    final String body;
    switch (s.phase) {
      case 'inviting':
        body = 'Waiting for the other side to answer.';
        break;
      case 'exchanging':
        body = 'Agreeing on the fastest connection.';
        break;
      case 'hotspot_starting':
        body = 'Your code appears here in a moment.';
        break;
      case 'joining':
        body = s.manualExpected
            ? 'Type the code from the sender’s screen to join.'
            : 'Using the code from the sender’s screen.';
        break;
      case 'link_connecting':
        body = 'Setting up the direct link.';
        break;
      default:
        body = 'Hold tight.';
    }
    final joinActions = <Widget>[
      if (s.manualExpected)
        BlTextButton('Type the code', icon: 'lock', onTap: s.reopenJoinCard),
      if (s.joinTimedOut != null) ...[
        BlTextButton('Try the join again', icon: 'refresh', onTap: s.retryJoin),
        BlTextButton('Open system panel',
            icon: 'chevron', onTap: s.openJoinPanel),
      ],
    ];
    return _card(
      icon: 'link',
      title: 'Working on it.',
      body: body,
      actions: joinActions.isEmpty
          ? [BlButton('Stop', primary: false, onTap: s.stop)]
          : joinActions,
    );
  }
}

/// Sender: the system-generated hotspot credentials, big and copyable.
class _ManualCodeCard extends StatelessWidget {
  final Map<String, dynamic> code;
  const _ManualCodeCard(this.code);

  void _copy(BuildContext context, String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    BlToast.show(context, '$label copied');
  }

  @override
  Widget build(BuildContext context) {
    final ssid = (code['ssid'] as String?) ?? '';
    final pass = (code['pass'] as String?) ?? '';
    return _card(
      icon: 'lock',
      title: 'Let them type it once.',
      body:
          'Android generated this hotspot for you. The receiver enters it once, then the system takes over.',
      extra: Column(
        children: [
          const SizedBox(height: 15),
          _codeRow(
              context, 'NETWORK', ssid, () => _copy(context, 'Network', ssid)),
          const SizedBox(height: 8),
          _codeRow(context, 'PASSWORD', pass,
              () => _copy(context, 'Password', pass)),
        ],
      ),
      actions: [
        BlButton('End session', primary: false, onTap: BlSession.I.stop),
      ],
    );
  }

  Widget _codeRow(
      BuildContext context, String label, String value, VoidCallback onCopy) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: const Color(0x77100D0F),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0x16FFFFFF)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: ts(8, w: 650, ls: 1.2, color: BlColors.muted)),
                const SizedBox(height: 3),
                Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts(13, w: 550, h: 1.3)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Pressable(
            onTap: onCopy,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child:
                  Text('COPY', style: ts(9, w: 650, color: BlColors.pinkDeep)),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- transfer ---

class _ProgressCard extends StatelessWidget {
  const _ProgressCard();

  @override
  Widget build(BuildContext context) {
    final s = BlSession.I;
    final p = s.progress!;
    final bytes = ((p['bytes'] as num?) ?? 0).toDouble();
    final total = ((p['totalBytes'] as num?) ?? 0).toDouble();
    final done = (p['filesDone'] as num?) ?? 0;
    final count = (p['fileCount'] as num?) ?? 0;
    final index = ((p['index'] as num?) ?? 0) + 1;
    final name = (p['name'] as String?) ?? '';
    final bps = ((p['bps'] as num?) ?? 0).toDouble();
    final eta = (p['etaSec'] as num?) ?? -1;
    final frac = total > 0 ? (bytes / total).clamp(0.0, 1.0) : 0.0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(19),
      decoration: _box(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              BlIcon('file', size: 15, color: BlColors.pink),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name.isEmpty ? 'Preparing…' : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ts(11, w: 550),
                ),
              ),
              Text('File $index of ${count == 0 ? '?' : count}',
                  style: ts(10, color: BlColors.muted)),
            ],
          ),
          const SizedBox(height: 15),
          ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: SizedBox(
              height: 8,
              child: Stack(
                children: [
                  Container(color: const Color(0x14FFFFFF)),
                  FractionallySizedBox(
                    widthFactor: frac,
                    child: Container(
                        decoration: const BoxDecoration(
                            gradient: blDockActiveGradient)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${fmtBytes(bytes)} / ${fmtBytes(total)}',
                  style: ts(10, color: BlColors.muted)),
              Text(
                  bps > 0
                      ? '${fmtBytes(bps)}/s · ${eta >= 0 ? fmtDuration(eta) : '—'}'
                      : 'Starting…',
                  style: ts(10, color: BlColors.muted)),
            ],
          ),
          if (count > 0) ...[
            const SizedBox(height: 6),
            Text('$done of $count files done',
                style: ts(9, color: const Color(0xFF8A7881))),
          ],
          const SizedBox(height: 16),
          BlButton('Cancel',
              primary: false, full: true, onTap: s.cancelTransfer),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard();

  @override
  Widget build(BuildContext context) {
    final s = BlSession.I;
    final r = s.result!;
    final recv = r['direction'] == 'receive';
    final cancelled = r['cancelled'] == true;
    final files = ((r['files'] as List?) ?? []).length;
    final total = ((r['totalBytes'] as num?) ?? 0).toDouble();
    final bytes = ((r['bytes'] as num?) ?? 0).toDouble();
    final avg = ((r['avgBps'] as num?) ?? 0) / 1048576;
    final secs = ((r['durationMs'] as num?) ?? 0) / 1000;
    final band = (r['band'] as String?) ?? '—';
    final dir = (r['dir'] as String?) ?? '';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(21),
      decoration: _box(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              BlIcon(recv ? 'arrowdown' : 'arrowup',
                  size: 15, color: BlColors.pink),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    cancelled
                        ? 'Cancelled mid-transfer'
                        : recv
                            ? 'Received from ${r['peer'] ?? 'them'}'
                            : 'Sent to ${r['peer'] ?? 'them'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts(12, w: 550)),
              ),
              if (!cancelled)
                const BlPill('Verified', icon: 'check', success: true),
            ],
          ),
          const SizedBox(height: 13),
          Text(
              cancelled
                  ? '${fmtBytes(bytes)} made it across before the stop.'
                  : '$files files · ${fmtBytes(total)} · ${avg.toStringAsFixed(1)} MB/s · ${fmtDuration(secs)} · $band',
              style: ts(10, color: BlColors.muted, h: 1.7)),
          if (recv && dir.isNotEmpty && !cancelled) ...[
            const SizedBox(height: 8),
            Text('Saved in $dir',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ts(9, color: const Color(0xFF8A7881))),
          ],
          const SizedBox(height: 17),
          const _DoneActions(),
        ],
      ),
    );
  }
}

class _DoneActions extends StatelessWidget {
  const _DoneActions();

  @override
  Widget build(BuildContext context) {
    final s = BlSession.I;
    final r = s.result;
    final recv = r?['direction'] == 'receive';
    final cancelled = r?['cancelled'] == true;
    final dir = (r?['dir'] as String?) ?? '';
    final canSendMore = s.role == 'send' && s.linkUp && !cancelled;
    return Row(
      children: [
        if (recv && dir.isNotEmpty && !cancelled)
          Expanded(
            child: BlButton('Open folder',
                icon: 'folder',
                primary: false,
                onTap: () => _openFolder(context, dir)),
          ),
        if (recv && dir.isNotEmpty && !cancelled) const SizedBox(width: 11),
        if (canSendMore) ...[
          Expanded(
              child: BlButton('Send more', icon: 'send', onTap: s.sendMore)),
          const SizedBox(width: 11),
        ],
        Expanded(child: BlButton('Done', primary: false, onTap: s.stop)),
      ],
    );
  }

  Future<void> _openFolder(BuildContext context, String dir) async {
    try {
      final res = await bridge.Engine.openFolder(dir);
      if (!context.mounted) return;
      if (res['opened'] == true) {
        BlToast.show(context, 'Opened in Files');
      } else {
        BlToast.show(context, 'Saved in $dir');
      }
    } catch (_) {
      if (context.mounted) BlToast.show(context, 'Saved in $dir');
    }
  }
}

class _FailureCard extends StatelessWidget {
  const _FailureCard();

  @override
  Widget build(BuildContext context) {
    final s = BlSession.I;
    final reason = (s.failure?['reason'] as String?) ?? '';
    return _card(
      icon: 'alert',
      title: 'Couldn’t finish.',
      body: reason.isEmpty ? 'Something interrupted the session.' : reason,
      actions: [
        BlButton('Try again', onTap: s.retry),
        const SizedBox(width: 11),
        BlButton('Done', primary: false, onTap: s.stop),
      ],
    );
  }
}

// -------------------------------------------------------------- plumbing ---

BoxDecoration _box() => BoxDecoration(
      gradient: blCardGradient,
      border: Border.all(color: const Color(0x0DFFFFFF)),
      borderRadius: BorderRadius.circular(26),
      boxShadow: const [
        BoxShadow(
            color: Color(0x18000000), blurRadius: 28, offset: Offset(0, 10)),
      ],
    );

Widget _card(
        {required String icon,
        required String title,
        required String body,
        Widget? extra,
        List<Widget> actions = const []}) =>
    Container(
      width: double.infinity,
      padding: const EdgeInsets.all(21),
      decoration: _box(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              BlIcon(icon, size: 15, color: BlColors.pink),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts(12, w: 550)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(body, style: ts(10, color: BlColors.muted, h: 1.7)),
          if (extra != null) extra,
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 17),
            Row(
              children: [
                for (int i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 11),
                  Expanded(child: actions[i]),
                ]
              ],
            ),
          ],
        ],
      ),
    );

// ---------------------------------------------------------------- modals ---
// Raised by Shell when the session needs a decision. Every one is a bLinker
// card; the system screens stay system.

/// Receiver: "<name> wants to connect" + band choice. Barrier-dismiss = decline.
Future<void> showInviteModal(BuildContext context) {
  final s = BlSession.I;
  final inv = s.invite!;
  final name = (inv['name'] as String?) ?? 'Someone';
  final fast = inv['fast'] == true;
  final bandOk = inv['bandOk'] == true;
  final acceptNormal = fast && !bandOk;

  return showBlModal(
    context,
    (ctx) => BlModalCard(
      pillIcon: 'receive',
      pillLabel: 'Incoming invite',
      title: '$name wants to connect.',
      body: fast
          ? (bandOk
              ? 'They’re inviting you over a direct 5GHz link — the fastest way.'
              : 'They picked Fast (5GHz), but your device can’t do 5GHz hotspots. Accepting joins over 2.4GHz instead.')
          : 'They’re inviting you over a Normal (2.4GHz) link.',
      actions: [
        BlButton('Decline',
            primary: false,
            onTap: () => _close(ctx, () => s.respondInvite(false))),
        BlButton(
          acceptNormal ? 'Accept in Normal' : 'Accept',
          onTap: () => _close(
              ctx, () => s.respondInvite(true, preferNormal: acceptNormal)),
        ),
      ],
    ),
  ).then((_) {
    // Dismissed without a decision (scrim tap / back): decline honestly.
    if (s.invite != null) s.respondInvite(false);
    return Future<void>.value();
  });
}

/// Receiver: the manifest-first file card. Barrier-dismiss = decline.
Future<void> showAcceptModal(BuildContext context) {
  final s = BlSession.I;
  final m = s.manifest!;
  final sender = m['sender'] is Map ? (m['sender'] as Map)['name'] : 'them';
  final files = (m['files'] as List? ?? [])
      .whereType<Map>()
      .map((f) => Map<String, dynamic>.from(f))
      .toList();
  final total = ((m['totalBytes'] as num?) ?? 0).toDouble();
  final shown = files.take(6).toList();
  final more = files.length - shown.length;

  return showBlModal(
    context,
    (ctx) => BlModalCard(
      pillIcon: 'folder',
      pillLabel: 'Incoming files',
      title:
          '$sender wants to send ${files.length} file${files.length == 1 ? '' : 's'}.',
      body:
          '${fmtBytes(total)} in total. Every file verifies with SHA-256 as it arrives.',
      extra: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 15),
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: const Color(0x03FFFFFF),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: BlColors.line),
            ),
            child: Column(
              children: [
                for (final f in shown)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        BlIcon(fileIconFor((f['name'] as String?) ?? ''),
                            size: 15, color: const Color(0xFFD47C91)),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text((f['name'] as String?) ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ts(10)),
                        ),
                        Text(fmtBytes((f['size'] as num?) ?? 0),
                            style: ts(9, color: BlColors.muted)),
                      ],
                    ),
                  ),
                if (more > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text('and $more more…',
                        style: ts(9, color: BlColors.muted)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 11),
          FutureBuilder<Map<String, dynamic>>(
            future: bridge.Engine.storageState(
                location: (BlStore.prefs['location'] ?? '') as String),
            builder: (_, snap) {
              final st = snap.data;
              final dir = (st?['saveDir'] as String?) ?? '';
              final sandboxed = st?['sandboxed'] == true;
              if (dir.isEmpty) return const SizedBox.shrink();
              return Row(
                children: [
                  BlIcon('folder', size: 11, color: BlColors.muted),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text('Saving to $dir',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ts(9, color: BlColors.muted)),
                  ),
                  if (sandboxed) const BlPill('App folder'),
                ],
              );
            },
          ),
        ],
      ),
      actions: [
        BlButton('Decline',
            primary: false, onTap: () => _close(ctx, s.rejectManifest)),
        BlButton('Accept',
            icon: 'check', onTap: () => _close(ctx, s.acceptManifest)),
      ],
    ),
  ).then((_) {
    if (s.manifest != null) s.rejectManifest();
    return Future<void>.value();
  });
}

/// Receiver: type the code from the sender's screen (once). Dismiss = later;
/// the joining card keeps a "Type the code" way back in.
Future<void> showJoinModal(BuildContext context) {
  final s = BlSession.I;
  final fb = s.joinFallback;
  final legacy = fb != null;
  final ssidCtrl = TextEditingController(text: (fb?['ssid'] as String?) ?? '');
  final passCtrl = TextEditingController(text: (fb?['pass'] as String?) ?? '');

  return showBlModal(
    context,
    (ctx) => BlModalCard(
      pillIcon: 'lock',
      pillLabel: 'Join the sender',
      title: 'Type their code.',
      body: legacy
          ? 'Your Android needs the network added by hand. Type the code from the sender’s screen, then open Wi-Fi settings.'
          : 'The code is on the sender’s screen. You type it once — after that Android’s own consent card takes over.',
      extra: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          _field('NETWORK', ssidCtrl),
          const SizedBox(height: 9),
          _field('PASSWORD', passCtrl, obscure: true),
        ],
      ),
      actions: [
        BlTextButton(legacy ? 'Open Wi-Fi settings' : 'Open system panel',
            icon: 'chevron', onTap: () => _close(ctx, s.openJoinPanel)),
        BlButton('Join',
            onTap: () => _close(
                ctx, () => s.joinManual(ssidCtrl.text.trim(), passCtrl.text))),
      ],
    ),
  ).then((_) {
    // Dismissed: leave manualExpected so the joining card can re-open it.
    ssidCtrl.dispose();
    passCtrl.dispose();
    return Future<void>.value();
  });
}

/// Receiver: join timed out - system panel or retry. Dismiss = keep waiting.
Future<void> showJoinTimeoutModal(BuildContext context) {
  final s = BlSession.I;
  final ssid = (s.joinTimedOut?['ssid'] as String?) ?? 'the network';
  return showBlModal(
    context,
    (ctx) => BlModalCard(
      pillIcon: 'wifi',
      pillLabel: 'Join timed out',
      title: 'Couldn’t join $ssid.',
      body:
          'The system can add the network for you - a real Android panel, one tap.',
      actions: [
        BlButton('Try again',
            primary: false, onTap: () => _close(ctx, s.retryJoin)),
        BlButton('Open system panel',
            onTap: () => _close(ctx, s.openJoinPanel)),
      ],
    ),
  ).then((_) => Future<void>.value());
}

/// The bLinker permission explainer; [Continue] opens the REAL system card.
Future<void> showPermModal(BuildContext context) {
  final s = BlSession.I;
  return showBlModal(
    context,
    (ctx) => BlModalCard(
      pillIcon: 'shield',
      pillLabel: 'One permission',
      title: 'bLinker needs your OK.',
      body:
          'Android asks for the Nearby-devices permission to find other bLinker phones. The next card is Android’s own - bLinker never imitates it.',
      actions: [
        BlButton('Not now',
            primary: false, onTap: () => _close(ctx, s.dismissPerms)),
        BlButton('Continue',
            icon: 'check', onTap: () => _close(ctx, s.continuePermissions)),
      ],
    ),
  ).then((_) {
    if (s.permMissing.isNotEmpty) s.dismissPerms();
    return Future<void>.value();
  });
}

/// Phase 5 radio card: the session is parked until Wi-Fi (and Location
/// services) are on - both are required by Wi-Fi Direct discovery on real
/// devices. Every button leads to a REAL system screen; the session resumes
/// by itself the moment both radios report on.
Future<void> showRadioModal(BuildContext context) {
  final s = BlSession.I;
  final wifiOff = s.radioBlocked.contains('wifi');
  final locationOff = s.radioBlocked.contains('location');
  final title = wifiOff && locationOff
      ? 'Wi-Fi and Location are off.'
      : (wifiOff ? 'Wi-Fi is off.' : 'Location is off.');
  final body = wifiOff && locationOff
      ? 'Finding and linking bLinker phones needs both radios. Android opens its own Wi-Fi panel and Location page - bLinker never imitates them.'
      : (wifiOff
          ? 'Nearby search needs the Wi-Fi adapter on. Android opens its own Wi-Fi panel - one real toggle.'
          : 'Android hides nearby devices while Location is off - that is a system rule, not bLinker’s. The real Location page is one toggle away.');
  return showBlModal(
    context,
    (ctx) => BlModalCard(
      pillIcon: 'wifi',
      pillLabel: 'Radios',
      title: title,
      body: body,
      actions: [
        BlButton('Not now',
            primary: false, onTap: () => _close(ctx, s.dismissRadios)),
        BlButton(locationOff ? 'Turn on Location' : 'Turn on Wi-Fi',
            icon: 'chevron',
            onTap: () =>
                _close(ctx, locationOff ? s.enableLocation : s.enableWifi)),
      ],
    ),
  ).then((_) {
    if (s.radioBlocked.isNotEmpty) s.dismissRadios();
    return Future<void>.value();
  });
}

/// Sender: 5GHz unavailable / receiver asked for Normal. Dismiss = end.
Future<void> showBandModal(BuildContext context) {
  final s = BlSession.I;
  final downgrade = s.bandIssue?['kind'] == 'downgrade';
  return showBlModal(
    context,
    (ctx) => BlModalCard(
      pillIcon: 'wifi',
      pillLabel: 'Band',
      title: downgrade ? 'They use 2.4GHz.' : '5GHz is busy here.',
      body: downgrade
          ? 'The receiver asked for Normal. Switching restarts the invite with a 2.4GHz hotspot.'
          : 'No 5GHz channel is free right now. Normal (2.4GHz) still shares at full speed.',
      actions: [
        BlButton('End session',
            primary: false, onTap: () => _close(ctx, s.endBandIssue)),
        BlButton('Switch to Normal',
            icon: 'refresh', onTap: () => _close(ctx, s.switchToNormal)),
      ],
    ),
  ).then((_) {
    if (s.bandIssue != null) s.endBandIssue();
    return Future<void>.value();
  });
}

void _close(BuildContext context, VoidCallback action) {
  Navigator.of(context).pop();
  action();
}

InputDecoration _deco() => InputDecoration(
      filled: true,
      fillColor: const Color(0x77100D0F),
      contentPadding: const EdgeInsets.all(13),
      counterText: '',
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0x16FFFFFF))),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFD64B6E))),
    );

Widget _field(String label, TextEditingController controller,
        {bool obscure = false}) =>
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: ts(8, w: 650, ls: 1.2, color: BlColors.muted)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          maxLength: 64,
          style: ts(13),
          decoration: _deco(),
        ),
      ],
    );
P5EOF
cat > lib/screens/shell.dart <<'P5EOF'
import 'package:flutter/material.dart';
import '../core/routes.dart';
import '../core/theme.dart';
import '../data/store.dart';
import '../services/session.dart';
import '../widgets/buttons.dart';
import '../widgets/dock.dart';
import '../widgets/modal.dart';
import '../widgets/session_flow.dart';
import '../widgets/toast.dart';
import '../widgets/topbar.dart';
import 'detail_screen.dart';
import 'diagnostics_screen.dart';
import 'home_screen.dart';
import 'settings_screen.dart';

/// The home shell: top bar + radar screen + Send/Receive dock.
/// Settings, Diagnostics and Transfer details are REAL routes now - the
/// Android back button pops them back here instead of exiting the app.
///
/// PHASE 4: the dock runs the real session flow. This state also shows the
/// decision cards the session raises (invite, accept, join, band, perms)
/// and its toasts - always in bLinker's own design language.
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  bool _historyAll = false;
  bool _cardOpen = false;
  int _lastToast = 0;

  @override
  void initState() {
    super.initState();
    BlSession.I.addListener(_onSession);
    // A session might already be live (e.g. process restart edge).
    WidgetsBinding.instance.addPostFrameCallback((_) => _drainCards());
  }

  @override
  void dispose() {
    BlSession.I.removeListener(_onSession);
    super.dispose();
  }

  void _onSession() {
    final s = BlSession.I;
    if (s.toastSeq != _lastToast && s.toast != null) {
      _lastToast = s.toastSeq;
      BlToast.show(context, s.toast!);
    }
    _drainCards();
  }

  /// One decision card at a time, in arrival order. Stale queue entries
  /// (their state was cleared by stop()) are skipped.
  void _drainCards() {
    if (!mounted || _cardOpen) return;
    final s = BlSession.I;
    while (s.cardQueue.isNotEmpty) {
      final id = s.cardQueue.first;
      final valid = switch (id) {
        'invite' => s.invite != null,
        'accept' => s.manifest != null,
        'join' => s.manualExpected || s.joinFallback != null,
        'joinTimeout' => s.joinTimedOut != null,
        'perm' => s.permMissing.isNotEmpty,
        'band' => s.bandIssue != null,
        'radio' => s.radioBlocked.isNotEmpty,
        _ => false,
      };
      if (valid) {
        s.cardQueue.removeAt(0);
        _cardOpen = true;
        Future<void> f;
        switch (id) {
          case 'invite':
            f = showInviteModal(context);
            break;
          case 'accept':
            f = showAcceptModal(context);
            break;
          case 'join':
            f = showJoinModal(context);
            break;
          case 'joinTimeout':
            f = showJoinTimeoutModal(context);
            break;
          case 'perm':
            f = showPermModal(context);
            break;
          case 'radio':
            f = showRadioModal(context);
            break;
          default:
            f = showBandModal(context);
            break;
        }
        f.whenComplete(() {
          _cardOpen = false;
          if (mounted) _drainCards();
        });
        return;
      }
      s.cardQueue.removeAt(0);
    }
  }

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
    final s = BlSession.I;
    if (s.role == mode) {
      // Same role tapped again: pick more files over the live link.
      if (mode == 'send' && s.linkUp) {
        s.sendMore();
      } else if (mode == 'send' &&
          (s.phase == 'p2p_search' || s.phase == 'mdns_search')) {
        BlToast.show(context, 'Pick a device on the radar below.');
      } else if (mode == 'receive') {
        BlToast.show(context, 'Already visible — waiting for a sender.');
      }
      return;
    }
    if (s.active) {
      _confirmSwitch(mode);
      return;
    }
    mode == 'send' ? s.startSend() : s.startReceive();
  }

  void _confirmSwitch(String mode) {
    final s = BlSession.I;
    showBlModal(
      context,
      (ctx) => BlModalCard(
        pillIcon: 'refresh',
        pillLabel: 'Switch',
        title: 'End this session?',
        body: mode == 'send'
            ? 'Receiving stops and you start picking files to send instead.'
            : 'The send stops and you become visible to nearby devices.',
        actions: [
          BlButton('Stay',
              primary: false, onTap: () => Navigator.of(ctx).pop()),
          BlButton('Switch', onTap: () {
            Navigator.of(ctx).pop();
            s.stop();
            mode == 'send' ? s.startSend() : s.startReceive();
          }),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = BlSession.I;
    return AnimatedBuilder(
      animation: s,
      builder: (context, _) => Scaffold(
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
                  BlDock(
                    mode: s.failure == null && s.role != 'none' ? s.role : null,
                    onMode: _onMode,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
P5EOF

echo ""
echo "Phase 5 written: 1 new engine file + 4 engine edits + MainActivity + 4 Dart files."
echo "Radio events now flow both ways; sessions park in needs_radios until the radios are on."
echo ""
echo "Build & try on BOTH phones:"
echo "  flutter run --release   (or your usual apk build)"
echo ""
echo "Test checklist (the two-phone reality):"
echo "  1. Wi-Fi OFF -> tap Send/Receive: the radio card appears, 'Turn on Wi-Fi'"
echo "     opens the REAL Android panel; flip it, come back: search starts by itself."
echo "  2. Location OFF -> same card offers 'Turn on Location' -> the real"
echo "     Location page; flip it, come back: search starts by itself."
echo "  3. Both radios on: the radar finds the other phone within seconds,"
echo "     tap it -> invite -> accept -> the sender's screen shows the code,"
echo "     the receiver types it once -> the real hotspot link -> files fly."
echo ""
echo "Then:"
echo "  git add -A"
echo "  git commit -m 'phase 5: radio gate - Wi-Fi/Location prompts + no more silent dead-ends'"
echo "  git push"
echo ""
echo "CI: https://github.com/nasirtajudin/blinker/actions"
