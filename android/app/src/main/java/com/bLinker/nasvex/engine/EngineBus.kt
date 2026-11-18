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
    }

    fun dispatchPanelResult(requestCode: Int, resultCode: Int, data: Intent?) {
        sessionManager.join.onPanelResult(requestCode, resultCode, data)
        pickerManager.onPanelResult(requestCode, resultCode, data)
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
