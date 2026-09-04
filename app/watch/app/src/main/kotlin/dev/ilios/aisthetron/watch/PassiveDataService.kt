package dev.ilios.aisthetron.watch

import android.os.SystemClock
import android.util.Log
import androidx.health.services.client.PassiveListenerService
import androidx.health.services.client.data.DataPointContainer
import androidx.health.services.client.data.DataType
import java.time.Instant

/// Receives batched passive health data points from Health Services and forwards
/// them to the paired phone over the Wear Data Layer.
class PassiveDataService : PassiveListenerService() {

    override fun onNewDataPointsReceived(dataPoints: DataPointContainer) {
        // Health Services reports times relative to boot; convert to wall-clock.
        val bootInstant =
            Instant.ofEpochMilli(System.currentTimeMillis() - SystemClock.elapsedRealtime())

        val samples = mutableListOf<MetricSample>()

        dataPoints.getData(DataType.HEART_RATE_BPM).forEach { dp ->
            samples += MetricSample("heart_rate", dp.value, "bpm", dp.getTimeInstant(bootInstant))
        }
        dataPoints.getData(DataType.STEPS_DAILY).forEach { dp ->
            samples += MetricSample("steps", dp.value.toDouble(), "count", dp.getEndInstant(bootInstant))
        }
        dataPoints.getData(DataType.CALORIES_DAILY).forEach { dp ->
            samples += MetricSample("calories", dp.value, "kcal", dp.getEndInstant(bootInstant))
        }
        dataPoints.getData(DataType.DISTANCE_DAILY).forEach { dp ->
            samples += MetricSample("distance", dp.value, "m", dp.getEndInstant(bootInstant))
        }

        Log.i(TAG, "onNewDataPointsReceived: ${samples.size} samples ${samples.map { it.metric }}")

        if (samples.isNotEmpty()) {
            MetricSender.send(applicationContext, samples)
        }
    }

    private companion object {
        const val TAG = "AisthetronWatch"
    }
}
