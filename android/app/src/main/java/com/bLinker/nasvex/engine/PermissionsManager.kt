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
