#!/usr/bin/env bash
# bLinker PHASE 3 - the manifest-first transfer protocol + a launcher fix.
#
# Verified before packaging:
#   * Kotlin compiled clean against android-34 + the real Flutter 3.24.3
#     embedding jar + androidx.core/lifecycle.
#   * TransferCore passed 22/22 headless protocol tests over real sockets
#     (happy path, resume with prefix skip, corrupt-prefix resend, reject,
#     mid-transfer cancel with .bpart retention, multi-manifest per link).
#   * flutter analyze: 0 errors / 0 warnings.
#
# What this adds:
#  1. TransferCore.kt    - the wire protocol (frames, manifest, SHA-256,
#     resume, progress/ETA). Manifest-first: file table -> per-file
#     bodies -> hash verify -> resend-on-mismatch. Receiver keeps
#     "<name>.bpart" partials; resume offsets are hashed prefixes, so the
#     final hash always covers the WHOLE file.
#  2. TransferManager.kt - Flutter glue: SAF content URIs or plain paths as
#     sources (single-owner fd channels), save-location resolution
#     (public Downloads with All-Files access / storage grant, otherwise
#     the app's own external dir - the REAL dir is in every event),
#     accept/reject/cancel plumbing + measured-band decoration.
#  3. LAUNCHER FIX (important!): the repo had TWO MainActivity classes -
#     the manifest resolved ".MainActivity" against the gradle namespace
#     (com.blinker.nasvex), so the Phase-1 activity under src/main/kotlin
#     launched and the ENGINE NEVER STARTED at runtime. Phase-1 behaviors
#     (edge-to-edge, tile sync) are merged into the engine MainActivity,
#     BlinkerTileService moves next to it, the duplicate kotlin/ dir is
#     deleted, and the manifest now names both classes explicitly.
#  4. linkSocket fix: on the same-router (LAN) method the sender is the
#     TCP client, so the getter is now role-agnostic - previously it
#     returned null on that path.
#  5. Manifest: WRITE_EXTERNAL_STORAGE (8-10) + MANAGE_EXTERNAL_STORAGE
#     (11+) for direct public-storage writes; the All-Files settings page
#     is opened untouched when needed.
set -e
cd "$(dirname "$0")"
[ -f pubspec.yaml ] || { echo "Run this from the blinker repo root."; exit 1; }
echo "-- writing phase 3 files --"
cat > android/app/src/main/java/com/bLinker/nasvex/engine/TransferCore.kt <<'BLINKER_EOF'
package com.bLinker.nasvex.engine

import org.json.JSONArray
import org.json.JSONObject
import java.io.EOFException
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/**
 * PHASE 3 - the manifest-first transfer protocol (pure JVM, no Android).
 *
 * Wire format over the established TCP link (port 58231):
 *   control frame = 4-byte big-endian length + UTF-8 JSON object
 *   file body     = raw byte stream of exactly (size - offset) bytes,
 *                   no per-chunk framing (max throughput)
 *
 * Flow:
 *   sender   -> hello {name, sdk, five}
 *            -> manifest {id, count, totalBytes, files:[{key,name,rel,size}]}
 *   receiver -> accept {name, sdk, five, resumes:{key:offset}}   (after the
 *               bLinker accept card answers)          | reject
 *   per file: sender -> file {key,size,offset} + body + hash {key,sha256}
 *             receiver -> ok {key} | resend {key} (one retry, then fail)
 *   receiver -> done {id}
 *
 * RESUME: the receiver keeps "<name>.bpart" partials. On a new manifest the
 * existing prefix length is offered as the resume offset; the prefix is
 * hashed first, so SHA-256 always covers the WHOLE file. A corrupt prefix
 * fails the final hash and triggers a clean resend from zero.
 *
 * THROUGHPUT NOTE (honest engineering): FileChannel.transferTo needs a
 * SocketChannel target - our sockets are plain ones (bound to the Wi-Fi
 * [Network] through its socket factory), which have no channel. Both sides
 * therefore stream through one 256 KiB buffer and hash inline while
 * copying: a single read pass, no second hash thread, and the Wi-Fi link
 * (not the CPU) stays the bottleneck. SO_RCVBUF/SO_SNDBUF stay untouched
 * so the kernel keeps auto-tuning.
 */
object TransferCore {

    const val BODY_BUF = 256 shl 10      // 256 KiB stream buffer
    const val FRAME_MAX = 8 shl 20       // sanity cap for control frames
    private const val PROGRESS_MS = 300L
    private const val ACCEPT_TIMEOUT_MS = 180_000L
    private const val OP_TIMEOUT_MS = 120_000L

    fun interface Emitter {
        fun emit(type: String, data: Any?)
    }

    /** An open source channel plus the one true owner to close. */
    class Handle(val channel: FileChannel, val close: () -> Unit)

    /** One outgoing file. [open] is called once per file. */
    class Source(
        val key: String,
        val name: String,
        val rel: String,
        val size: Long,
        val open: () -> Handle,
    )

    /** The UI layer's answer to a manifest (root = resolved save dir). */
    class Decision(val accept: Boolean, val root: File?, val location: String? = null)

    // ------------------------------------------------------------- frames

    fun sendFrame(out: OutputStream, frame: JSONObject) {
        val body = frame.toString().toByteArray(Charsets.UTF_8)
        if (body.size > FRAME_MAX) throw IOException("frame too large")
        out.write(byteArrayOf(
            (body.size shr 24).toByte(), (body.size shr 16).toByte(),
            (body.size shr 8).toByte(), body.size.toByte()))
        out.write(body)
        out.flush()
    }

    fun recvFrame(ins: InputStream): JSONObject {
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
        if (len <= 0 || len > FRAME_MAX) throw IOException("bad frame length $len")
        return JSONObject(String(readFully(len), Charsets.UTF_8))
    }

    // ----------------------------------------------------------- progress

    internal class Progress(
        val id: String,
        val totalBytes: Long,
        val fileCount: Int,
        private val emit: Emitter,
    ) {
        val startNs = System.nanoTime()
        var bytesSoFar = 0L
            private set
        var filesDone = 0
            private set
        private var lastNs = startNs
        private var lastBytes = 0L
        private var bps = 0.0

        fun body(n: Int, name: String, index: Int) {
            bytesSoFar += n
            val now = System.nanoTime()
            if (now - lastNs >= TimeUnit.MILLISECONDS.toNanos(PROGRESS_MS)) {
                emitProgress(name, index, now)
            }
        }

        fun fileDone() { filesDone++ }

        fun elapsedMs(): Long = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startNs)

        fun avgBps(): Long = if (elapsedMs() > 0) bytesSoFar * 1000 / elapsedMs() else 0

        private fun emitProgress(name: String, index: Int, now: Long) {
            val dtMs = TimeUnit.NANOSECONDS.toMillis(now - lastNs)
            if (dtMs > 0) {
                val instant = (bytesSoFar - lastBytes) * 1000.0 / dtMs
                bps = if (bps == 0.0) instant else 0.6 * bps + 0.4 * instant
            }
            lastNs = now
            lastBytes = bytesSoFar
            val eta = if (bps > 1.0) ((totalBytes - bytesSoFar) / bps).toLong() else -1L
            emit.emit("transfer:progress", JSONObject()
                .put("id", id)
                .put("bytes", bytesSoFar)
                .put("totalBytes", totalBytes)
                .put("filesDone", filesDone)
                .put("fileCount", fileCount)
                .put("index", index)
                .put("name", name)
                .put("bps", bps.toLong())
                .put("etaSec", eta))
        }
    }

    // -------------------------------------------------------------- utils

    private fun newDigest(): MessageDigest = MessageDigest.getInstance("SHA-256")

    private fun hex(d: MessageDigest): String =
        d.digest().joinToString("") { "%02x".format(it) }

    /** Hash [0, upTo) of the channel into [digest] (resume prefixes). */
    private fun hashPrefix(ch: FileChannel, upTo: Long, digest: MessageDigest) {
        val buf = ByteArray(BODY_BUF)
        val bb = ByteBuffer.wrap(buf)
        var pos = 0L
        while (pos < upTo) {
            bb.clear()
            bb.limit(minOf(buf.size.toLong(), upTo - pos).toInt())
            val n = ch.read(bb, pos)
            if (n <= 0) throw IOException("short read while hashing")
            digest.update(buf, 0, n)
            pos += n
        }
    }

    fun sanitizeName(raw: String): String {
        var n = raw.substringAfterLast('/').substringAfterLast('\\').trim()
        n = n.replace(Regex("[\\x00-\\x1f/\\\\]"), "")
        if (n.isEmpty() || n == "." || n == "..") n = "file"
        if (n.length > 200) n = n.take(200)
        return n
    }

    fun sanitizeRel(raw: String): String = raw.split('/', '\\')
        .map { it.trim() }
        .filter { it.isNotEmpty() && it != "." && it != ".." }
        .joinToString("/")

    // =========================================================== SENDER ===

    /**
     * Streams one manifest. Run on the transfer thread. After "done" the
     * socket stays open - Dart may send another manifest over the same link.
     */
    class SenderSide(
        private val socket: Socket,
        private val sources: List<Source>,
        private val emit: Emitter,
        private val selfInfo: JSONObject,
    ) {
        @Volatile private var cancelled = false

        /** Local cancel: closing the link ends the peer's reads cleanly. */
        fun cancel() {
            cancelled = true
            runCatching { socket.close() }
        }

        fun run() {
            val id = UUID.randomUUID().toString()
            val total = sources.sumOf { it.size }
            val progress = Progress(id, total, sources.size, emit)
            val out = socket.getOutputStream()
            val ins = socket.getInputStream()
            try {
                sendFrame(out, selfInfo.put("type", "hello"))
                val files = JSONArray()
                for (s in sources) {
                    files.put(JSONObject()
                        .put("key", s.key).put("name", s.name)
                        .put("rel", s.rel).put("size", s.size))
                }
                sendFrame(out, JSONObject()
                    .put("type", "manifest").put("id", id)
                    .put("count", sources.size)
                    .put("totalBytes", total)
                    .put("files", files))
                socket.soTimeout = ACCEPT_TIMEOUT_MS.toInt()
                val resp = recvFrame(ins)
                when (resp.optString("type")) {
                    "reject" -> emit.emit("transfer:rejected", JSONObject().put("id", id))
                    "accept" -> {
                        emit.emit("transfer:accepted", JSONObject()
                            .put("id", id)
                            .put("peer", resp.optString("name")))
                        runAccepted(id, resp, progress, out, ins)
                    }
                    else -> throw IOException("unexpected frame ${resp.optString("type")}")
                }
            } catch (e: Exception) {
                when {
                    cancelled -> cancelled(id, progress, "local")
                    e is SocketTimeoutException ->
                        failed(id, "no_accept", "No answer to the manifest")
                    else -> failed(id, "link", e.message ?: "connection lost")
                }
            }
        }

        private fun runAccepted(
            id: String,
            accept: JSONObject,
            progress: Progress,
            out: OutputStream,
            ins: InputStream,
        ) {
            val total = sources.sumOf { it.size }
            val resumes = accept.optJSONObject("resumes")
            val files = JSONArray()
            for ((index, s) in sources.withIndex()) {
                if (cancelled) { cancelled(id, progress, "local"); return }
                val handle = s.open()
                try {
                    val ch = handle.channel
                    if (ch.size() != s.size) throw IOException("size_mismatch: ${s.name}")
                    var offset = resumes?.optLong(s.key) ?: 0L
                    if (offset < 0 || offset > s.size) offset = 0L
                    var attempt = 0
                    while (true) {
                        sendFrame(out, JSONObject()
                            .put("type", "file").put("key", s.key)
                            .put("size", s.size).put("offset", offset))
                        val digest = newDigest()
                        if (offset > 0) hashPrefix(ch, offset, digest)  // whole-file hash
                        val t0 = System.nanoTime()
                        val sentOffset = offset
                        val buf = ByteArray(BODY_BUF)
                        val bb = ByteBuffer.wrap(buf)
                        var pos = offset
                        var remaining = s.size - offset
                        while (remaining > 0) {
                            bb.clear()
                            bb.limit(minOf(buf.size.toLong(), remaining).toInt())
                            val n = ch.read(bb, pos)
                            if (n <= 0) throw IOException("short read on ${s.name}")
                            out.write(buf, 0, n)
                            digest.update(buf, 0, n)
                            pos += n
                            remaining -= n
                            progress.body(n, s.name, index)
                        }
                        out.flush()
                        val ms = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - t0).coerceAtLeast(1)
                        sendFrame(out, JSONObject()
                            .put("type", "hash").put("key", s.key).put("sha256", hex(digest)))
                        socket.soTimeout = OP_TIMEOUT_MS.toInt()
                        val r = recvFrame(ins)
                        when (r.optString("type")) {
                            "ok" -> {
                                progress.fileDone()
                                emit.emit("transfer:file_done", JSONObject()
                                    .put("id", id).put("key", s.key).put("index", index)
                                    .put("name", s.name).put("bytes", s.size)
                                    .put("ms", ms)
                                    .put("bps", (s.size - sentOffset) * 1000 / ms))
                                files.put(JSONObject().put("name", s.name).put("size", s.size))
                                break
                            }
                            "resend" -> {
                                if (++attempt >= 2) throw IOException("integrity: ${s.name}")
                                offset = 0
                            }
                            "cancel" -> { cancelled(id, progress, "peer"); return }
                            else -> throw IOException("unexpected result frame")
                        }
                    }
                } finally {
                    runCatching { handle.close() }
                }
            }
            socket.soTimeout = OP_TIMEOUT_MS.toInt()
            val done = recvFrame(ins)
            if (done.optString("type") != "done") throw IOException("expected done")
            emit.emit("transfer:complete", JSONObject()
                .put("id", id).put("direction", "send")
                .put("peer", accept.optString("name"))
                .put("peerAndroid", accept.optInt("sdk"))
                .put("peer5", accept.optBoolean("five"))
                .put("files", files)
                .put("totalBytes", total)
                .put("bodyBytes", progress.bytesSoFar)
                .put("durationMs", progress.elapsedMs())
                .put("avgBps", progress.avgBps()))
        }

        private fun cancelled(id: String, p: Progress, reason: String) {
            emit.emit("transfer:cancelled", JSONObject()
                .put("id", id).put("direction", "send").put("reason", reason)
                .put("bytes", p.bytesSoFar).put("totalBytes", p.totalBytes)
                .put("filesDone", p.filesDone))
        }

        private fun failed(id: String, stage: String, reason: String) {
            emit.emit("transfer:failed", JSONObject()
                .put("id", id).put("direction", "send")
                .put("stage", stage).put("reason", reason))
        }
    }

    // ========================================================= RECEIVER ===

    /**
     * Reads manifests until the link closes. [onManifest] must return a
     * future that completes with the UI's decision; it is also where the
     * manifest event is emitted to Dart (see TransferManager).
     */
    class ReceiverSide(
        private val socket: Socket,
        private val emit: Emitter,
        private val onManifest: (JSONObject) -> CompletableFuture<Decision>,
        private val selfInfo: JSONObject,
    ) {
        private class Target(
            val key: String,
            val name: String,
            val rel: String,
            val size: Long,
            val dir: File,
            val part: File,
        )

        @Volatile private var cancelled = false
        private var liveId: String? = null

        fun cancel() {
            cancelled = true
            runCatching { socket.close() }
        }

        fun run() {
            val out = socket.getOutputStream()
            val ins = socket.getInputStream()
            var sender = JSONObject()
            try {
                while (true) {
                    socket.soTimeout = 0   // idle wait for the next manifest
                    val frame = recvFrame(ins)
                    when (frame.optString("type")) {
                        "hello" -> sender = frame
                        "manifest" -> handleManifest(frame, sender, out, ins)
                        "cancel" -> { cancelled("peer", liveId, null, emptyList()); return }
                        "error" -> {
                            emit.emit("transfer:failed", JSONObject()
                                .put("id", liveId ?: JSONObject.NULL)
                                .put("direction", "receive")
                                .put("stage", "peer")
                                .put("reason", frame.optString("reason")))
                            return
                        }
                        else -> {}   // unknown frame types are ignored
                    }
                }
            } catch (e: Exception) {
                when {
                    cancelled -> cancelled("local", liveId, null, emptyList())
                    else -> Unit   // idle link dropped (session ended): clean exit
                }
            }
        }

        private fun handleManifest(
            m: JSONObject,
            sender: JSONObject,
            out: OutputStream,
            ins: InputStream,
        ) {
            val id = m.optString("id")
            val arr = m.optJSONArray("files") ?: throw IOException("manifest without files")
            data class Entry(val key: String, val name: String, val rel: String, val size: Long)
            val entries = ArrayList<Entry>(arr.length())
            var total = 0L
            val manifestFiles = JSONArray()
            for (i in 0 until arr.length()) {
                val f = arr.getJSONObject(i)
                val key = f.optString("key")
                val size = f.optLong("size")
                if (key.isBlank() || size < 0) throw IOException("bad manifest entry")
                val name = sanitizeName(f.optString("name").ifBlank { "file" })
                val rel = sanitizeRel(f.optString("rel"))
                entries.add(Entry(key, name, rel, size))
                total += size
                manifestFiles.put(JSONObject()
                    .put("key", key).put("name", name)
                    .put("rel", rel).put("size", size))
            }
            val decision = try {
                onManifest(JSONObject()
                    .put("id", id)
                    .put("sender", sender)
                    .put("count", entries.size)
                    .put("totalBytes", total)
                    .put("files", manifestFiles))
                    .get(ACCEPT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            } catch (e: Exception) {
                Decision(false, null)
            }
            if (!decision.accept || decision.root == null) {
                sendFrame(out, JSONObject().put("type", "reject"))
                emit.emit("transfer:rejected", JSONObject().put("id", id))
                return
            }
            val root = decision.root
            val targets = ArrayList<Target>(entries.size)
            val resumes = JSONObject()
            for (e in entries) {
                val dir = if (e.rel.isEmpty()) root else File(root, e.rel)
                val part = File(dir, "${e.name}.bpart")
                if (part.exists() && part.length() in 1..e.size) {
                    resumes.put(e.key, part.length())
                }
                targets.add(Target(e.key, e.name, e.rel, e.size, dir, part))
            }
            sendFrame(out, JSONObject()
                .put("type", "accept")
                .put("name", selfInfo.optString("name"))
                .put("sdk", selfInfo.optInt("sdk"))
                .put("five", selfInfo.optBoolean("five"))
                .put("resumes", resumes))
            emit.emit("transfer:accepted", JSONObject()
                .put("id", id).put("peer", sender.optString("name")))
            val progress = Progress(id, total, targets.size, emit)
            liveId = id
            val done = JSONArray()
            try {
                var index = 0
                while (index < targets.size) {
                    val t = targets[index]
                    var ok = false
                    var attempt = 0
                    while (!ok) {
                        socket.soTimeout = OP_TIMEOUT_MS.toInt()
                        val ff = recvFrame(ins)
                        when (ff.optString("type")) {
                            "file" -> {
                                if (ff.optString("key") != t.key) {
                                    throw IOException("out of order: ${ff.optString("key")}")
                                }
                                ok = receiveBody(t, ff, progress, index, out, ins, done)
                            }
                            "cancel" -> { cancelled("peer", id, progress, targets); return }
                            else -> throw IOException("unexpected frame ${ff.optString("type")}")
                        }
                        if (!ok && ++attempt >= 2) throw IOException("integrity: ${t.name}")
                    }
                    index++
                }
                sendFrame(out, JSONObject().put("type", "done").put("id", id))
            } catch (e: Exception) {
                // Mid-transfer abort: report with the live state in hand.
                // (Never rely on fields here - unwinding clears them before
                // the outer catch could read them.)
                cancelled(if (cancelled) "local" else "link", id, progress, targets)
                return
            }
            emit.emit("transfer:complete", JSONObject()
                .put("id", id).put("direction", "receive")
                .put("peer", sender.optString("name"))
                .put("peerAndroid", sender.optInt("sdk"))
                .put("peer5", sender.optBoolean("five"))
                .put("files", done)
                .put("totalBytes", total)
                .put("bodyBytes", progress.bytesSoFar)
                .put("durationMs", progress.elapsedMs())
                .put("avgBps", progress.avgBps())
                .put("dir", root.absolutePath)
                .put("location", decision.location ?: JSONObject.NULL))
        }

        /**
         * Receives one body + hash frame. True = verified and finalized
         * (ok frame sent); false = mismatch (resend frame sent, caller may
         * retry once).
         */
        private fun receiveBody(
            t: Target,
            ff: JSONObject,
            progress: Progress,
            index: Int,
            out: OutputStream,
            ins: InputStream,
            done: JSONArray,
        ): Boolean {
            val size = ff.optLong("size")
            val offset = ff.optLong("offset")
            if (size != t.size) throw IOException("size mismatch for ${t.name}")
            t.dir.mkdirs()
            val raf = RandomAccessFile(t.part, "rw")
            try {
                val digest = newDigest()
                val existing = raf.length()
                when {
                    offset == 0L -> {}
                    offset in 1..existing -> hashPrefix(raf.channel, offset, digest)
                    else -> throw IOException("resume offset beyond file for ${t.name}")
                }
                raf.setLength(size)   // pre-allocate; also drops stale tails
                val t0 = System.nanoTime()
                val ch = raf.channel
                val buf = ByteArray(BODY_BUF)
                var pos = offset
                var remaining = size - offset
                while (remaining > 0) {
                    val r = ins.read(buf, 0, minOf(buf.size, remaining.toInt()))
                    if (r < 0) throw EOFException("link closed")
                    ch.write(ByteBuffer.wrap(buf, 0, r), pos)
                    digest.update(buf, 0, r)
                    pos += r
                    remaining -= r
                    progress.body(r, t.name, index)
                }
                val ms = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - t0).coerceAtLeast(1)
                val hf = recvFrame(ins)
                if (hf.optString("type") != "hash") throw IOException("expected hash frame")
                if (!hf.optString("sha256").equals(hex(digest), ignoreCase = true)) {
                    sendFrame(out, JSONObject().put("type", "resend").put("key", t.key))
                    return false
                }
                sendFrame(out, JSONObject().put("type", "ok").put("key", t.key))
                progress.fileDone()
                val finalFile = dedupName(t.dir, t.name)
                if (!t.part.renameTo(finalFile)) throw IOException("cannot finalize ${t.name}")
                done.put(JSONObject().put("name", finalFile.name).put("size", size))
                emit.emit("transfer:file_done", JSONObject()
                    .put("id", progress.id).put("key", t.key).put("index", index)
                    .put("name", finalFile.name).put("bytes", size)
                    .put("ms", ms)
                    .put("bps", (size - offset) * 1000 / ms))
                return true
            } finally {
                runCatching { raf.close() }
            }
        }

        /** "photo.jpg" -> "photo (1).jpg" when the name is already taken. */
        private fun dedupName(dir: File, name: String): File {
            var f = File(dir, name)
            if (!f.exists()) return f
            val dot = name.lastIndexOf('.')
            val base = if (dot > 0) name.substring(0, dot) else name
            val ext = if (dot > 0) name.substring(dot) else ""
            for (n in 1..999) {
                f = File(dir, "$base ($n)$ext")
                if (!f.exists()) return f
            }
            return File(dir, name)   // give up; overwrite
        }

        private fun cancelled(
            reason: String,
            id: String?,
            p: Progress?,
            targets: List<Target>,
        ) {
            val partials = JSONArray()
            for (t in targets) {
                if (t.part.exists()) {
                    partials.put(JSONObject()
                        .put("name", t.name)
                        .put("done", t.part.length())
                        .put("size", t.size))
                }
            }
            emit.emit("transfer:cancelled", JSONObject()
                .put("id", id ?: JSONObject.NULL)
                .put("direction", "receive")
                .put("reason", reason)
                .put("bytes", p?.bytesSoFar ?: 0)
                .put("totalBytes", p?.totalBytes ?: 0)
                .put("filesDone", p?.filesDone ?: 0)
                .put("files", partials))
        }
    }
}
BLINKER_EOF
cat > android/app/src/main/java/com/bLinker/nasvex/engine/TransferManager.kt <<'BLINKER_EOF'
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

    /** Phase 3 transfer protocol over the established link. */
    val transfer: TransferManager by lazy { TransferManager(context, bus, this) }

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
        transfer.cancel()
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
        }
    }
}
BLINKER_EOF
cat > android/app/src/main/java/com/bLinker/nasvex/MainActivity.kt <<'BLINKER_EOF'
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
BLINKER_EOF
cat > android/app/src/main/java/com/bLinker/nasvex/BlinkerTileService.kt <<'BLINKER_EOF'
package com.bLinker.nasvex

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * bLinker quick-settings tile (moved from the old kotlin/ source dir next to
 * the merged [MainActivity]; behaviour unchanged - Phase 5 gives it the real
 * "app open = active" session state).
 */
class BlinkerTileService : TileService() {

    override fun onStartListening() = sync()
    override fun onTileAdded() = sync()

    private fun sync() {
        val tile = qsTile ?: return
        tile.state =
            if (MainActivity.isRunning) Tile.STATE_ACTIVE
            else Tile.STATE_INACTIVE
        tile.updateTile()
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    override fun onClick() {
        val intent = Intent(this, MainActivity::class.java)
            .apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(
                PendingIntent.getActivity(
                    this,
                    4210,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT
                        or PendingIntent.FLAG_IMMUTABLE
                )
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
        sync()
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
    <!-- Phase 3 receiver storage: direct public-storage writes (needed for
         pre-allocation + resume). 11+: All-Files access grant (system
         settings page, opened untouched); 8-10: legacy write grant.
         Without either, the app's own external dir is used and reported. -->
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"
        android:maxSdkVersion="29"
        android:required="false" />
    <uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"
        android:required="false"
        tools:ignore="ScopedStorage" />
    <uses-feature
        android:name="android.hardware.wifi.direct"
        android:required="false" />

    <application
        android:label="bLinker"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher"
        android:requestLegacyExternalStorage="true"
        android:enableOnBackInvokedCallback="true"
        tools:targetApi="34">

        <activity
            android:name="com.bLinker.nasvex.MainActivity"
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

        <service
            android:name="com.bLinker.nasvex.BlinkerTileService"
            android:exported="true"
            android:label="bLinker"
            android:icon="@drawable/ic_tile_flame"
            android:permission="android.permission.BIND_QUICK_SETTINGS_TILE">
            <intent-filter>
                <action android:name="android.service.quicksettings.action.QS_TILE" />
            </intent-filter>
        </service>

        <meta-data
            android:name="flutterEmbedding"
            android:value="2" />
        <service android:name=".engine.SessionService" android:exported="false" android:foregroundServiceType="connectedDevice"/>
</application>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"/>
</manifest>
BLINKER_EOF
cat > lib/engine/engine_bridge.dart <<'BLINKER_EOF'
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
          await _call('storage.state', {'location': location}) as String) as Map);

  /// Opens the system "All files access" page (real system screen, 11+).
  static Future<void> openAllFilesAccess() => _call('storage.openAllFiles');
}
BLINKER_EOF

echo "-- removing the duplicate kotlin/ source dir --"
rm -rf android/app/src/main/kotlin

echo "-- sanity checks --"
grep -q "object TransferCore" android/app/src/main/java/com/bLinker/nasvex/engine/TransferCore.kt && echo "OK transfer: protocol core"
grep -q "beginReceiving" android/app/src/main/java/com/bLinker/nasvex/engine/SessionManager.kt && echo "OK session: receiver auto-start"
grep -q "transfer.send" android/app/src/main/java/com/bLinker/nasvex/engine/EngineBus.kt && echo "OK bridge methods registered"
grep -q "com.bLinker.nasvex.MainActivity" android/app/src/main/AndroidManifest.xml && echo "OK manifest: explicit launcher"
grep -q "BlinkerTileService" android/app/src/main/AndroidManifest.xml && echo "OK manifest: tile restored"
[ ! -d android/app/src/main/kotlin ] && echo "OK duplicate dir gone"
grep -q "sendTransfer" lib/engine/engine_bridge.dart && echo "OK dart bridge"

cat <<'BLINKER_EOF'

Done. Push it:

  git add -A
  git commit -m "phase 3: manifest-first transfer protocol + launcher fix"
  git push

CI: https://github.com/nasirtajudin/blinker/actions
BLINKER_EOF
