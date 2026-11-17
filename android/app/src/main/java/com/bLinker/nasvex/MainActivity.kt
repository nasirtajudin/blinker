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
