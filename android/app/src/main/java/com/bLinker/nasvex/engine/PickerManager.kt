package com.bLinker.nasvex.engine

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import org.json.JSONArray
import org.json.JSONObject

/**
 * PHASE 4 - the system document picker (SAF), launched untouched.
 *
 * The picker itself is Android's own UI (same rule as permission cards and
 * the Wi-Fi panels: never customised, never imitated). What this class adds
 * around it:
 *  - multi-select (EXTRA_ALLOW_MULTIPLE), openable files only;
 *  - name + size lookup through OpenableColumns;
 *  - PERSISTABLE URI grants: the transfer link can take minutes to build
 *    (invite -> hotspot -> join), and a plain SAF grant dies with the
 *    activity. Each picked URI is therefore persisted and released again
 *    after the session ends / the next pick replaces it.
 *
 * Events (both directions are bLinker-native, no system look-alikes):
 *   picker:result   {files:[{uri,name,size}]}
 *   picker:cancelled
 */
class PickerManager(private val context: Context, private val bus: EngineBus) {

    companion object { const val PICK_REQ = 58234 }

    private val granted = ArrayList<Uri>()

    /** Dart: dock "Send" / "Send more". Result arrives as an event. */
    fun open() {
        val a = bus.activity
        if (a == null) {
            bus.emit("picker:cancelled", JSONObject().put("reason", "no_activity"))
            return
        }
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            .putExtra(Intent.EXTRA_LOCAL_ONLY, true)
            .addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        runCatching { a.startActivityForResult(i, PICK_REQ) }
            .onFailure {
                bus.emit("picker:cancelled", JSONObject().put("reason", "no_picker"))
            }
    }

    /** Outcome of the system picker; routed from MainActivity via EngineBus. */
    fun onPanelResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PICK_REQ) return
        if (resultCode != Activity.RESULT_OK || data == null) {
            bus.emit("picker:cancelled", null)
            return
        }
        val uris = ArrayList<Uri>()
        data.data?.let { uris.add(it) }
        data.clipData?.let { cd ->
            for (i in 0 until cd.itemCount) uris.add(cd.getItemAt(i).uri)
        }
        if (uris.isEmpty()) {
            bus.emit("picker:cancelled", null)
            return
        }
        releaseAll()   // a fresh pick replaces the staged set
        val files = JSONArray()
        for (uri in uris) {
            val meta = queryMeta(uri) ?: continue
            if (persist(uri)) files.put(JSONObject()
                .put("uri", uri.toString())
                .put("name", meta.first)
                .put("size", meta.second))
        }
        if (files.length() == 0) {
            releaseAll()
            bus.emit("picker:cancelled", JSONObject().put("reason", "unreadable"))
            return
        }
        bus.emit("picker:result", JSONObject().put("files", files))
    }

    /** DISPLAY_NAME + SIZE through the content resolver (single query). */
    private fun queryMeta(uri: Uri): Pair<String, Long>? = runCatching {
        context.contentResolver.query(
            uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null, null, null
        )?.use { c ->
            if (!c.moveToFirst()) return@use null
            val idxName = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            val idxSize = c.getColumnIndex(OpenableColumns.SIZE)
            if (idxName < 0) return@use null
            val name = c.getString(idxName) ?: uri.lastPathSegment ?: "file"
            val size = if (idxSize >= 0 && !c.isNull(idxSize)) c.getLong(idxSize) else -1L
            if (size < 0) null else Pair(name, size)
        }
    }.getOrNull()

    private fun persist(uri: Uri): Boolean {
        val ok = runCatching {
            context.contentResolver.takePersistableUriPermission(
                uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }.isSuccess
        if (ok) granted.add(uri)
        return ok
    }

    /** Every staged grant goes when the session ends or a new pick lands. */
    fun releaseAll() {
        for (u in granted) {
            runCatching {
                context.contentResolver.releasePersistableUriPermission(
                    u, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        }
        granted.clear()
    }
}
