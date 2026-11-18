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
