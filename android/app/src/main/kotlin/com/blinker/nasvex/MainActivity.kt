package com.blinker.nasvex

import android.content.ComponentName
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.service.quicksettings.TileService
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        @Volatile
        var isRunning: Boolean = false
            private set
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "blinker/engine"
        ).setMethodCallHandler { call, result ->
            if (call.method == "probe") {
                val wifi = applicationContext
                    .getSystemService(WifiManager::class.java)
                val supports5 = try {
                    wifi?.is5GHzBandSupported == true
                } catch (_: Exception) {
                    false
                }
                val p2p = packageManager
                    .hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)
                result.success(
                    mapOf(
                        "supports5GHz" to supports5,
                        "p2p" to p2p,
                        "android" to Build.VERSION.SDK_INT
                    )
                )
            } else {
                result.notImplemented()
            }
        }
    }

    private fun requestTileSync() {
        try {
            TileService.requestListeningState(
                this,
                ComponentName(this, BlinkerTileService::class.java)
            )
        } catch (_: Exception) {
        }
    }
}
