package com.bLinker.nasvex.engine

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.provider.Settings
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.net.Socket
import java.nio.channels.FileChannel
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors

/**
 * PHASE 3 glue between Flutter and [TransferCore].
 *  - parses the Dart file list (SAF content URIs from the system picker or
 *    plain paths) and opens each source as a FileChannel exactly once;
 *  - resolves the save location: direct writes into public storage (needed
 *    for pre-allocation + resume) when the user granted All-Files access
 *    (11+) / storage permission (8-10), the app's own external dir
 *    otherwise - the REAL directory is reported in every event;
 *  - owns the io thread and the pending accept/reject decision.
 *
 * STORAGE HONESTY: the All-Files-Access toggle lives on a real system
 * settings page, opened untouched (same rule as permission cards).
 */
class TransferManager(
    private val context: Context,
    private val bus: EngineBus,
    private val session: SessionManager,
) {
    companion object {
        const val DEFAULT_LOCATION = "Downloads/bLinker"
    }

    private val io = Executors.newSingleThreadExecutor { r ->
        Thread(r, "bLinker-transfer").apply { isDaemon = true }
    }

    @Volatile private var senderSide: TransferCore.SenderSide? = null
    @Volatile private var receiverSide: TransferCore.ReceiverSide? = null
    @Volatile private var pendingDecision: CompletableFuture<TransferCore.Decision>? = null

    private val wm =
        context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

    private val selfInfo: JSONObject
        get() = JSONObject()
            .put("name", Device.name(context))
            .put("sdk", Build.VERSION.SDK_INT)
            .put("five", wm.is5GHzBandSupported)

    // ------------------------------------------------------------ sender

    /**
     * [filesArg] = List<Map> with {name, size, rel?, uri? | path?}.
     * Called by Dart once the link is up (session:link_connected).
     */
    fun send(filesArg: Any?) {
        val sources = parseSources(filesArg)
        if (sources == null) {
            bus.emit("transfer:failed", JSONObject()
                .put("stage", "bad_files")
                .put("reason", "empty or invalid file list"))
            return
        }
        val socket: Socket? = session.linkSocket
        if (socket == null || !socket.isConnected || socket.isClosed) {
            bus.emit("transfer:failed", JSONObject()
                .put("stage", "no_link")
                .put("reason", "No established transfer link"))
            return
        }
        val side = TransferCore.SenderSide(socket, sources, ::emitDecorated, selfInfo)
        senderSide = side
        io.execute { side.run() }
    }

    private fun parseSources(arg: Any?): List<TransferCore.Source>? {
        val list = arg as? List<*> ?: return null
        if (list.isEmpty()) return null
        val out = ArrayList<TransferCore.Source>(list.size)
        for ((i, item) in list.withIndex()) {
            val m = item as? Map<*, *> ?: return null
            val name = m["name"] as? String
            if (name.isNullOrBlank()) return null
            val size = (m["size"] as? Number)?.toLong() ?: return null
            if (size < 0) return null
            val rel = TransferCore.sanitizeRel(m["rel"] as? String ?: "")
            val uri = m["uri"] as? String
            val path = m["path"] as? String
            if (uri.isNullOrBlank() && path.isNullOrBlank()) return null
            val open: () -> TransferCore.Handle = {
                if (uri != null) openUri(uri) else openPath(path!!)
            }
            out.add(TransferCore.Source("$i", TransferCore.sanitizeName(name), rel, size, open))
        }
        return out
    }

    private fun openPath(path: String): TransferCore.Handle {
        val raf = RandomAccessFile(path, "r")
        return TransferCore.Handle(raf.channel) { runCatching { raf.close() } }
    }

    /** SAF source: detach the fd so the FileInputStream is the single owner. */
    private fun openUri(uri: String): TransferCore.Handle {
        val pfd = context.contentResolver.openFileDescriptor(Uri.parse(uri), "r")
            ?: throw IOException("unreadable: $uri")
        pfd.detachFd()
        val fis = FileInputStream(pfd.fileDescriptor)
        return TransferCore.Handle(fis.channel) { runCatching { fis.close() } }
    }

    // ---------------------------------------------------------- receiver

    /** Auto-started when the receiver's link is established. */
    fun beginReceiving(socket: Socket) {
        val side = TransferCore.ReceiverSide(socket, ::emitDecorated, ::onManifest, selfInfo)
        receiverSide = side
        io.execute { side.run() }
    }

    private fun onManifest(manifest: JSONObject): CompletableFuture<TransferCore.Decision> {
        val fut = CompletableFuture<TransferCore.Decision>()
        pendingDecision = fut
        // Phase 4 renders the bLinker accept card from this event and
        // answers through accept()/reject() below.
        bus.emit("transfer:manifest", manifest)
        return fut
    }

    fun accept(location: String?) {
        val fut = pendingDecision ?: return
        pendingDecision = null
        fut.complete(TransferCore.Decision(true, resolveRoot(location), location ?: DEFAULT_LOCATION))
    }

    fun reject() {
        val fut = pendingDecision ?: return
        pendingDecision = null
        fut.complete(TransferCore.Decision(false, null))
    }

    fun cancel() {
        runCatching { senderSide?.cancel() }
        runCatching { receiverSide?.cancel() }
    }

    // ----------------------------------------------------------- storage

    /** Can we write straight into public storage on this device/grant? */
    fun publicAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager()
        else context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED

    fun resolveRoot(location: String?): File {
        val rel = location?.trim()?.trim('/')?.takeIf { it.isNotEmpty() } ?: DEFAULT_LOCATION
        @Suppress("DEPRECATION") // the only public root API that fits pre-11 grants
        val base = if (publicAccess()) Environment.getExternalStorageDirectory()
        else context.getExternalFilesDir(null) ?: context.filesDir
        return File(base, TransferCore.sanitizeRel(rel))
    }

    fun storageState(location: String?): JSONObject {
        val root = resolveRoot(location)
        return JSONObject()
            .put("publicAccess", publicAccess())
            .put("allFilesAccessAvailable", Build.VERSION.SDK_INT >= 30)
            .put("sandboxed", !publicAccess())
            .put("saveDir", root.absolutePath)
    }

    /** The system "All files access" page for this app - untouched. */
    fun openAllFilesAccess() {
        if (Build.VERSION.SDK_INT < 30) return
        val a = bus.activity ?: return
        runCatching {
            a.startActivity(
                Intent(
                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:${context.packageName}"),
                )
            )
        }
    }

    // -------------------------------------------------------------- emit

    /** Adds the MEASURED Wi-Fi band to completion events (HUD truth). */
    private fun emitDecorated(type: String, data: Any?) {
        if (type == "transfer:complete" && data is JSONObject) {
            Net.currentStats(context)?.let {
                data.put("band", it.band).put("linkMbps", it.linkMbps)
            }
        }
        bus.emit(type, data)
    }
}
