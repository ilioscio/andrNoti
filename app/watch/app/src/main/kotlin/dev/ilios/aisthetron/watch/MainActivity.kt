package dev.ilios.aisthetron.watch

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.widget.TextView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.health.services.client.HealthServices
import androidx.health.services.client.data.DataType
import androidx.health.services.client.data.PassiveListenerConfig

/// Requests sensor permissions (foreground + background) and registers passive
/// monitoring. Ongoing collection runs in PassiveDataService.
class MainActivity : Activity() {

    private lateinit var status: TextView

    private val foregroundPermissions = arrayOf(
        Manifest.permission.BODY_SENSORS,
        Manifest.permission.ACTIVITY_RECOGNITION,
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        status = TextView(this).apply {
            text = "Aisthetron\ncollector"
            textSize = 16f
            gravity = Gravity.CENTER
        }
        setContentView(status)

        val missing = foregroundPermissions.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            requestBackgroundThenRegister()
        } else {
            ActivityCompat.requestPermissions(this, missing.toTypedArray(), REQ_FOREGROUND)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            REQ_FOREGROUND -> {
                if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) {
                    requestBackgroundThenRegister()
                } else {
                    Log.w(TAG, "foreground sensor permission denied")
                    status.text = "Aisthetron\nsensor permission needed"
                }
            }
            REQ_BACKGROUND -> {
                val granted = grantResults.isNotEmpty() &&
                    grantResults.all { it == PackageManager.PERMISSION_GRANTED }
                Log.i(TAG, "background sensor permission granted=$granted")
                registerPassiveMonitoring()
            }
        }
    }

    /// Body sensors in the background need a separate "all the time" grant on
    /// API 33+. Request it, then register regardless of the outcome.
    private fun requestBackgroundThenRegister() {
        val bg = "android.permission.BODY_SENSORS_BACKGROUND"
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(this, bg) != PackageManager.PERMISSION_GRANTED
        ) {
            Log.i(TAG, "requesting BODY_SENSORS_BACKGROUND")
            ActivityCompat.requestPermissions(this, arrayOf(bg), REQ_BACKGROUND)
        } else {
            registerPassiveMonitoring()
        }
    }

    private fun registerPassiveMonitoring() {
        val client = HealthServices.getClient(this).passiveMonitoringClient
        val config = PassiveListenerConfig.builder()
            .setDataTypes(
                setOf(
                    DataType.HEART_RATE_BPM,
                    DataType.STEPS_DAILY,
                    DataType.CALORIES_DAILY,
                    DataType.DISTANCE_DAILY,
                )
            )
            .build()
        val future = client.setPassiveListenerServiceAsync(PassiveDataService::class.java, config)
        future.addListener(
            {
                Log.i(TAG, "passive monitoring registered")
                runOnUiThread { status.text = "Aisthetron\ncollecting…" }
            },
            mainExecutor,
        )
        Log.i(TAG, "registerPassiveMonitoring called")
        status.text = "Aisthetron\ncollecting…"
    }

    private companion object {
        const val TAG = "AisthetronWatch"
        const val REQ_FOREGROUND = 1
        const val REQ_BACKGROUND = 2
    }
}
