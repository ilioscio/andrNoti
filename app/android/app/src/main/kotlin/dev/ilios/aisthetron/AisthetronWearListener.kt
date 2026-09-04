package dev.ilios.aisthetron

import android.util.Log
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService
import java.net.HttpURLConnection
import java.net.URL

/// Receives health-sample batches pushed from the watch collector over the Wear
/// Data Layer and relays them to the Aisthetron server's /metrics endpoint.
///
/// The message payload is already in the /metrics request shape
/// ({"source":..., "samples":[...]}), so it is forwarded verbatim with the
/// bearer token. Runs headless — no Flutter engine required — reading the server
/// URL + token the app stored via shared_preferences.
class AisthetronWearListener : WearableListenerService() {

    override fun onMessageReceived(event: MessageEvent) {
        Log.i(TAG, "onMessageReceived path=${event.path} bytes=${event.data.size}")
        if (event.path != METRICS_PATH) return

        val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
        val serverUrl = prefs.getString("flutter.server_url", null)
        val token = prefs.getString("flutter.token", null)
        Log.i(TAG, "config: url=${serverUrl != null} token=${token != null}")
        if (serverUrl == null || token == null) return
        val endpoint = httpBase(serverUrl) + "/metrics"
        val body = event.data

        Thread { postMetrics(endpoint, token, body) }.start()
    }

    private fun postMetrics(endpoint: String, token: String, body: ByteArray) {
        var conn: HttpURLConnection? = null
        try {
            conn = (URL(endpoint).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                setRequestProperty("Authorization", "Bearer $token")
                setRequestProperty("Content-Type", "application/json")
                doOutput = true
                connectTimeout = 10_000
                readTimeout = 10_000
            }
            conn.outputStream.use { it.write(body) }
            val code = conn.responseCode
            Log.i(TAG, "POST $endpoint -> $code (${body.size} bytes)")
        } catch (e: Exception) {
            Log.w(TAG, "POST $endpoint failed: $e")
        } finally {
            conn?.disconnect()
        }
    }

    /// Derive the HTTPS base from the stored WebSocket URL (mirrors AppConfig.httpBase).
    private fun httpBase(serverUrl: String): String {
        return serverUrl.trim()
            .replaceFirst(Regex("^wss://"), "https://")
            .replaceFirst(Regex("^ws://"), "http://")
            .replaceFirst(Regex("/ws$"), "")
    }

    private companion object {
        const val TAG = "AisthetronPhone"
        const val METRICS_PATH = "/aisthetron/metrics"
    }
}
