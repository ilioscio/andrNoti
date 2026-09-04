import 'package:flutter/material.dart';

/// A single health-telemetry reading from a wearable.
class Sample {
  final String source;
  final String metric;
  final double value;
  final String unit;
  final DateTime ts;

  const Sample({
    required this.source,
    required this.metric,
    required this.value,
    required this.unit,
    required this.ts,
  });

  factory Sample.fromJson(Map<String, dynamic> json) => Sample(
        source: (json['source'] as String?) ?? '',
        metric: json['metric'] as String,
        value: (json['value'] as num).toDouble(),
        unit: (json['unit'] as String?) ?? '',
        ts: DateTime.parse(json['ts'] as String),
      );

  /// Whole numbers render without a decimal; otherwise one decimal place.
  String get displayValue =>
      value == value.roundToDouble() ? value.toInt().toString() : value.toStringAsFixed(1);
}

/// Display metadata (friendly label + icon) for a metric key.
class MetricMeta {
  final String label;
  final IconData icon;
  const MetricMeta(this.label, this.icon);
}

MetricMeta metricMeta(String metric) {
  switch (metric) {
    case 'heart_rate':
      return const MetricMeta('Heart Rate', Icons.favorite);
    case 'steps':
      return const MetricMeta('Steps', Icons.directions_walk);
    case 'calories':
      return const MetricMeta('Calories', Icons.local_fire_department);
    case 'distance':
      return const MetricMeta('Distance', Icons.straighten);
    case 'floors':
      return const MetricMeta('Floors', Icons.stairs);
    default:
      final label = metric
          .split('_')
          .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
          .join(' ');
      return MetricMeta(label, Icons.show_chart);
  }
}
