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
