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
