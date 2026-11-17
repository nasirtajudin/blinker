#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  bLinker - Phase 2: connectivity engine (Kotlin + Dart bridge)
#  Run inside the project root:  bash phase2.sh
# ============================================================
set -euo pipefail

[ -f pubspec.yaml ] || { echo "!! Run inside the bLinker Flutter project root."; exit 1; }
M=android/app/src/main/AndroidManifest.xml
[ -f "$M" ] || { echo "!! AndroidManifest.xml not found - run Phase 1 first."; exit 1; }

K=android/app/src/main/java/com/bLinker/nasvex
mkdir -p "$K/engine" lib/engine

# Phase 1 only scaffolded; drop placeholders the real engine replaces.
rm -f "$K/Engine.kt" "$K/engine/EngineBridge.kt" "$K/engine/Stub.kt"

cat > "$K/MainActivity.kt" <<'EOF'
package com.bLinker.nasvex

import com.bLinker.nasvex.engine.EngineBus
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

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

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        // Outcome of the system "Add network" panel (join fallback).
        EngineBus.get()?.dispatchPanelResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        if (isFinishing) EngineBus.shutdown()
        super.onDestroy()
    }
}
EOF

cat > "$K/engine/EngineBus.kt" <<'EOF'
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
                Device.setName(bus.appContext, call.arguments<String>() ?: ""); result.success(null)
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
EOF

cat > "$K/engine/Device.kt" <<'EOF'
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
EOF

cat > "$K/engine/Net.kt" <<'EOF'
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
EOF

cat > "$K/engine/PermissionsManager.kt" <<'EOF'
package com.bLinker.nasvex.engine

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import org.json.JSONObject

/**
 * Runtime permissions.
 *
 * UI RULE (locked with the user):
 *  - The permission card Android shows IS the system card. Requests go
 *    straight to it - never customised, wrapped or replicated.
 *  - Anything bLinker itself renders (explainers, invite, manifest, dialogs)
 *    uses the bLinker design language only and must NOT imitate system cards.
 *    The app must never look like the system.
 */
class PermissionsManager(private val bus: EngineBus) {

    companion object {
        const val REQUEST_CODE = 58231

        /** Everything a discovery/transfer session needs, by platform. */
        fun sessionPerms(): List<String> =
            if (Build.VERSION.SDK_INT >= 33) listOf(
                Manifest.permission.NEARBY_WIFI_DEVICES,
                Manifest.permission.POST_NOTIFICATIONS
            )
            else listOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }

    private fun granted(p: String): Boolean =
        bus.appContext.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    /** JSON: {granted:[..], missing:[..], anyPermanentlyDenied:bool} */
    fun state(): JSONObject {
        val perms = sessionPerms()
        val missing = perms.filter { !granted(it) }
        return JSONObject()
            .put("granted", perms.filter { granted(it) })
            .put("missing", missing)
            .put("anyPermanentlyDenied", missing.any { !showRationale(it) })
    }

    private fun showRationale(p: String): Boolean {
        val a: Activity = bus.activity ?: return true
        return a.shouldShowRequestPermissionRationale(p)
    }

    /** Fires the REAL system permission card. No app UI in between. */
    fun requestSystemPermissions() {
        val missing = sessionPerms().filter { !granted(it) }
        val a = bus.activity
        if (missing.isEmpty() || a == null) {
            bus.emit("perm:result", state())
            return
        }
        a.requestPermissions(missing.toTypedArray(), REQUEST_CODE)
    }

    /** Outcome of the system card; forwarded from MainActivity. */
    fun dispatchResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (requestCode != REQUEST_CODE) return
        bus.emit("perm:result", state())
    }

    /** Deep-links into Android's own app settings page (real system screen). */
    fun openSystemAppSettings() {
        val a = bus.activity ?: return
        a.startActivity(
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", bus.appContext.packageName, null)
            )
        )
    }
}
EOF

cat > "$K/engine/HotspotManager.kt" <<'EOF'
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
EOF

cat > "$K/engine/JoinManager.kt" <<'EOF'
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
EOF

cat > "$K/engine/P2pMessenger.kt" <<'EOF'
package com.bLinker.nasvex.engine

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.WifiP2pConfig
import android.net.wifi.WifiP2pDnsSdServiceInfo
import android.net.wifi.WifiP2pInfo
import android.net.wifi.WifiP2pManager
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
 * It carries: invite -> accept/reject (+ band preference) -> hotspot
 * credentials -> ack. Then both sides tear the P2P link down so the radio is
 * free for the local-only hotspot. File data NEVER flows over Wi-Fi Direct.
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
    /** Sender: creds JSON handed over (Android 13+), generated before the hotspot starts. */
    @Volatile var credsForExchange: JSONObject? = null

    /** Receiver: raw invite for the bLinker invite card (app UI, never system-styled). */
    @Volatile var onInvite: ((JSONObject) -> Unit)? = null
    /** Receiver: credentials received (null => manual code path). */
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
            context.registerReceiver(this, IntentFilter().apply {
                addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
                addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            })
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

    /** Sender: remember which discovered devices answered as bLinker. */
    private fun listenForBlinkerServices() {
        val ch = channel ?: return
        pm.setDnsSdResponseListeners(ch, { serviceInfo, srcDevice ->
            if (serviceInfo.serviceType?.contains("blink") == true && srcDevice != null) {
                synchronized(blinkerPeers) { blinkerPeers.add(srcDevice.deviceAddress) }
            }
        }, null)
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
                    val creds = credsForExchange
                    if (creds != null) send(creds.put("type", "creds"))
                    else send(JSONObject().put("type", "manual").put("port", TcpLink.PORT))
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
                "creds" -> {
                    send(JSONObject().put("type", "ack"))
                    teardown()
                    onCredsReceived?.invoke(msg)
                }
                "manual" -> {
                    send(JSONObject().put("type", "ack"))
                    teardown()
                    onCredsReceived?.invoke(null)   // manual code path
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
            runCatching { pm.removeGroup(ch, null) }
        }
        if (registered) {
            runCatching { context.unregisterReceiver(this) }
            registered = false
        }
        bus.emit("p2p:closed", null)
    }
}
EOF

cat > "$K/engine/MdnsBeacon.kt" <<'EOF'
package com.bLinker.nasvex.engine

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import org.json.JSONObject

/**
 * Method (1) of the waterfall: both devices on the SAME router.
 * The receiver advertises "_blinker._tcp" and the sender browses for it -
 * zero prompts, zero hotspots, straight over the LAN (fastest path).
 */
@Suppress("DEPRECATION")
class MdnsBeacon(private val context: Context, private val bus: EngineBus) {

    companion object { const val TYPE = "_blinker._tcp." }

    private val nsd = context.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var registration: NsdManager.RegistrationListener? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    private val resolving = HashSet<String>()

    /** Receiver: advertise this device + its TCP port on the local network. */
    fun advertise(name: String, port: Int) {
        stop()
        val info = NsdServiceInfo()
        info.serviceName = name
        info.serviceType = TYPE
        info.port = port
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                bus.emit("mdns:registered", JSONObject().put("name", serviceInfo.serviceName))
            }
            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                bus.emit("mdns:error", JSONObject().put("stage", "register").put("code", errorCode))
            }
            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {}
            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
        }
        registration = listener
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    /** Sender: browse the local network for receivers. */
    fun browse() {
        stopDiscovery()
        val listener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                bus.emit("mdns:error", JSONObject().put("stage", "discover").put("code", errorCode))
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                val name = serviceInfo.serviceName ?: return
                synchronized(resolving) { if (!resolving.add(name)) return }
                nsd.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                        synchronized(resolving) { resolving.remove(name) }
                    }
                    override fun onServiceResolved(info: NsdServiceInfo) {
                        val host = info.host?.hostAddress ?: return
                        bus.emit("mdns:found", JSONObject()
                            .put("name", info.serviceName)
                            .put("host", host)
                            .put("port", info.port))
                    }
                })
            }
            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                serviceInfo.serviceName?.let { n -> synchronized(resolving) { resolving.remove(n) } }
            }
        }
        discovery = listener
        nsd.discoverServices(TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    fun stopDiscovery() {
        discovery?.let { l -> runCatching { nsd.stopServiceDiscovery(l) } }
        discovery = null
    }

    fun stop() {
        stopDiscovery()
        registration?.let { l -> runCatching { nsd.unregisterService(l) } }
        registration = null
    }
}
EOF

cat > "$K/engine/TcpLink.kt" <<'EOF'
package com.bLinker.nasvex.engine

import android.net.Network
import org.json.JSONObject
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Raw TCP link layer - the transport every file byte will flow over.
 *
 * Phase 3 layers the manifest-first protocol (file table header, streamed
 * bodies, SHA-256, resume markers) on exactly these sockets; nothing here is
 * throwaway.
 *
 * Server side enforces the single-client policy: the FIRST accepted socket is
 * THE partner, every later connection is closed immediately.
 */
object TcpLink {

    const val PORT = 58231

    private val pool: ExecutorService = Executors.newCachedThreadPool { r ->
        Thread(r, "bLinker-tcp").apply { isDaemon = true }
    }

    /**
     * Socket tuning. SO_RCVBUF/SO_SNDBUF are deliberately left alone: a fixed
     * value disables the kernel's auto-tuning and would cap throughput.
     */
    fun tune(socket: Socket) {
        socket.tcpNoDelay = true
        socket.keepAlive = true
    }

    class Server(private val bus: EngineBus) {
        @Volatile var client: Socket? = null
            private set
        private var server: ServerSocket? = null

        fun listen(onClient: (Socket) -> Unit, onFailed: (String) -> Unit) {
            pool.execute {
                try {
                    val s = ServerSocket()
                    s.reuseAddress = true
                    s.bind(InetSocketAddress(PORT))
                    server = s
                    bus.emit("tcp:listening", JSONObject().put("port", PORT))
                    while (!s.isClosed) {
                        val c = s.accept()
                        if (client != null) {
                            runCatching { c.close() }   // single-client policy
                            continue
                        }
                        client = c
                        tune(c)
                        onClient(c)
                    }
                } catch (t: Throwable) {
                    if (server?.isClosed != true) onFailed(t.message ?: "listen failed")
                }
            }
        }

        fun stop() {
            runCatching { server?.close() }
            runCatching { client?.close() }
            server = null
            client = null
        }
    }

    class Client(private val bus: EngineBus) {
        @Volatile var socket: Socket? = null
            private set

        fun connect(host: String, port: Int, network: Network?,
                    onConnected: (Socket) -> Unit, onFailed: (String) -> Unit) {
            pool.execute {
                try {
                    // CRITICAL: bind to the Wi-Fi network. Without this the OS
                    // routes 192.168.x.x over cellular and the connect hangs.
                    val s = Net.socketFor(network)
                    tune(s)
                    s.connect(InetSocketAddress(host, port), 12_000)
                    socket = s
                    onConnected(s)
                } catch (t: Throwable) {
                    onFailed(t.message ?: "connect failed")
                }
            }
        }

        fun stop() {
            runCatching { socket?.close() }
            socket = null
        }
    }
}
EOF

cat > "$K/engine/SessionService.kt" <<'EOF'
package com.bLinker.nasvex.engine

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps the session alive against Doze while the link is being established
 * and later while files flow (Phase 3). Low-importance channel.
 */
class SessionService : Service() {

    companion object {
        private const val CHANNEL = "blinker_session"
        private const val NOTIF_ID = 58231

        fun start(ctx: Context, text: String) {
            ctx.startForegroundService(Intent(ctx, SessionService::class.java).putExtra("text", text))
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, SessionService::class.java))
        }
    }

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "Transfer session", NotificationManager.IMPORTANCE_LOW)
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra("text") ?: "bLinker session active"
        val notification: Notification = Notification.Builder(this, CHANNEL)
            .setContentTitle("bLinker")
            .setContentText(text)
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIF_ID, notification)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        @Suppress("DEPRECATION")
        stopForeground(true)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
EOF

cat > "$K/engine/SessionManager.kt" <<'EOF'
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
EOF

cat > lib/engine/engine_bridge.dart <<'EOF'
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

  factory HotspotCredentials.from(Map<String, dynamic> j) => HotspotCredentials._(
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
  static final Stream<EngineEvent> events = _events
      .receiveBroadcastStream()
      .map<EngineEvent>((raw) {
    final map = jsonDecode(raw as String) as Map<String, dynamic>;
    return EngineEvent(
      map['type'] as String,
      map['data'] == null ? null : Map<String, dynamic>.from(map['data'] as Map),
    );
  });

  static Future<dynamic> _call(String method, [Map<String, dynamic>? args]) =>
      _methods.invokeMethod(method, args ?? const <String, dynamic>{});

  // -- permissions (system card: untouched, never replicated) ----------------
  static Future<Map<String, dynamic>> permissionState() async =>
      Map<String, dynamic>.from(jsonDecode(await _call('perms.state') as String) as Map);

  static Future<void> requestPermissions() => _call('perms.request');
  static Future<void> openAppSettings() => _call('perms.openSettings');

  // -- identity / diagnostics -------------------------------------------------
  static Future<String> deviceName() async => await _call('device.name') as String;
  static Future<void> setDeviceName(String name) =>
      _methods.invokeMethod('device.setName', name);
  static Future<Map<String, dynamic>> hardwareProbe() async =>
      Map<String, dynamic>.from(jsonDecode(await _call('diag.hardware') as String) as Map);

  // -- sessions ------------------------------------------------------------------
  /// mode: 'fast' (5GHz) | 'normal' (2.4GHz)
  static Future<void> startSenderHotspot({required String mode}) =>
      _call('session.startSenderHotspot', {'mode': mode});
  static Future<void> startSenderLan() => _call('session.startSenderLan');
  static Future<void> startReceiver() => _call('session.startReceiver');
  static Future<void> connectPeer(String peerId) =>
      _call('session.p2pConnect', {'peerId': peerId});
  static Future<void> respondInvite({required bool accept, bool preferNormal = false}) =>
      _call('session.respondInvite', {'accept': accept, 'preferNormal': preferNormal});
  static Future<void> lanConnect(String host, int port) =>
      _call('session.lanConnect', {'host': host, 'port': port});
  static Future<void> joinManual({required String ssid, required String pass}) =>
      _call('session.joinManual', {'ssid': ssid, 'pass': pass});
  static Future<void> joinPanel() => _call('session.joinPanel');
  static Future<void> switchMode(String mode) => _call('session.switchMode', {'mode': mode});
  static Future<void> stopSession() => _call('session.stop');
}
EOF

# ---- idempotent manifest patcher --------------------------------------
ensure() { grep -qF "$1" "$M" || sed -i "s|</manifest>|    $2\n</manifest>|" "$M"; }

ensure android.permission.INTERNET '<uses-permission android:name="android.permission.INTERNET"/>'
ensure android.permission.ACCESS_NETWORK_STATE '<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>'
ensure android.permission.ACCESS_WIFI_STATE '<uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>'
ensure android.permission.CHANGE_WIFI_STATE '<uses-permission android:name="android.permission.CHANGE_WIFI_STATE"/>'
ensure android.permission.CHANGE_NETWORK_STATE '<uses-permission android:name="android.permission.CHANGE_NETWORK_STATE"/>'
ensure android.permission.WAKE_LOCK '<uses-permission android:name="android.permission.WAKE_LOCK"/>'
ensure android.permission.ACCESS_FINE_LOCATION '<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="32"/>'
ensure android.permission.NEARBY_WIFI_DEVICES '<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" android:usesPermissionFlags="neverForLocation"/>'
ensure android.permission.POST_NOTIFICATIONS '<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>'
ensure android.permission.FOREGROUND_SERVICE '<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>'
ensure android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE '<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"/>'
ensure android.hardware.wifi.direct '<uses-feature android:name="android.hardware.wifi.direct" android:required="false"/>'

grep -q "SessionService" "$M" || sed -i 's|</application>|    <service android:name=".engine.SessionService" android:exported="false" android:foregroundServiceType="connectedDevice"/>\n</application>|' "$M"

echo ""
echo "Phase 2 written. Kotlin files now present:"
find "$K" -name '*.kt' | sort
echo ""
echo "If any OTHER .kt file from Phase 1 is listed above, delete it (rm <path>)."
echo "Next: git add -A && git commit -m 'phase 2: connectivity engine' && git push"
