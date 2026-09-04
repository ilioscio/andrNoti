package dev.ilios.aisthetron.watch

import android.content.Context
import android.util.Log
import com.google.android.gms.wearable.Wearable
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.format.DateTimeFormatter

/// One health reading destined for the relay's /metrics endpoint.
data class MetricSample(
    val metric: String,
    val value: Double,
    val unit: String,
    val ts: Instant,
)

/// Serializes samples and sends them to every connected node (the phone) over
/// the Wear Data Layer MessageClient. Fire-and-forget: if no node is reachable
/// the batch is dropped (a store-and-forward upgrade can come later).
object MetricSender {
    private const val TAG = "AisthetronWatch"
    private const val PATH = "/aisthetron/metrics"
    private const val SOURCE = "galaxy-watch4"

    fun send(context: Context, samples: List<MetricSample>) {
        val arr = JSONArray()
        for (s in samples) {
            arr.put(
                JSONObject()
                    .put("metric", s.metric)
                    .put("value", s.value)
                    .put("unit", s.unit)
                    .put("ts", DateTimeFormatter.ISO_INSTANT.format(s.ts))
            )
        }
        val payload = JSONObject()
            .put("source", SOURCE)
            .put("samples", arr)
            .toString()
            .toByteArray()

        val messageClient = Wearable.getMessageClient(context)
        Wearable.getNodeClient(context).connectedNodes
            .addOnSuccessListener { nodes ->
                Log.i(TAG, "connectedNodes: ${nodes.size} ${nodes.map { it.displayName }}")
                if (nodes.isEmpty()) {
                    Log.w(TAG, "no connected nodes — dropping ${samples.size} samples")
                }
                for (node in nodes) {
                    messageClient.sendMessage(node.id, PATH, payload)
                        .addOnSuccessListener { Log.i(TAG, "sent ${samples.size} samples to ${node.displayName}") }
                        .addOnFailureListener { Log.w(TAG, "send failed to ${node.displayName}: ${it.message}") }
                }
            }
            .addOnFailureListener { Log.w(TAG, "connectedNodes failed: ${it.message}") }
    }
}
