import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'config.dart';
import 'date_nav.dart';
import 'sample.dart';
import 'theme.dart';

/// Per-metric detail: a day selector (arrows + calendar), a scrubbable +
/// pinch-zoomable line graph of that day's readings, and the full list below.
class MetricHistoryScreen extends StatefulWidget {
  const MetricHistoryScreen({super.key, required this.metric});

  final String metric;

  @override
  State<MetricHistoryScreen> createState() => _MetricHistoryScreenState();
}

class _MetricHistoryScreenState extends State<MetricHistoryScreen> {
  late DateTime _day; // local, date-only
  List<Sample> _samples = []; // ascending by ts
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _day = dateOnly(DateTime.now());
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final config = await AppConfig.load();
    if (!config.isConfigured) {
      setState(() {
        _loading = false;
        _error = 'Not configured.';
      });
      return;
    }
    final uri = Uri.parse('${config.httpBase}/metrics').replace(queryParameters: {
      'metric': widget.metric,
      'from': _rfc3339(_day.toUtc()),
      'to': _rfc3339(_day.add(const Duration(days: 1)).toUtc()),
      'limit': '100000',
    });
    try {
      final resp = await http.get(uri, headers: {'Authorization': 'Bearer ${config.token}'});
      if (resp.statusCode == 200) {
        final list = (json.decode(resp.body) as List)
            .map((e) => Sample.fromJson(e as Map<String, dynamic>))
            .toList()
          ..sort((a, b) => a.ts.compareTo(b.ts));
        if (mounted) {
          setState(() {
            _samples = list;
            _loading = false;
          });
        }
      } else if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Server returned ${resp.statusCode}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final meta = metricMeta(widget.metric);
    return Scaffold(
      appBar: AppBar(
        title: Text(meta.label),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: Column(
        children: [
          DateNavBar(
            day: _day,
            onChanged: (d) {
              setState(() => _day = d);
              _load();
            },
          ),
          const Divider(height: 1),
          SizedBox(height: 240, child: _chartArea()),
          _summary(),
          const Divider(height: 1),
          Expanded(child: _list(meta)),
        ],
      ),
    );
  }

  Widget _chartArea() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    if (_samples.isEmpty) {
      return const Center(child: Text('No readings this day.'));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
      child: _MetricChart(
        key: ValueKey(_day),
        day: _day,
        samples: _samples,
        unit: _samples.first.unit,
      ),
    );
  }

  Widget _summary() {
    if (_samples.isEmpty) return const SizedBox.shrink();
    final vals = _samples.map((s) => s.value).toList();
    final min = vals.reduce((a, b) => a < b ? a : b);
    final max = vals.reduce((a, b) => a > b ? a : b);
    final avg = vals.reduce((a, b) => a + b) / vals.length;
    final unit = _samples.first.unit;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _stat('MIN', _fmt(min), unit),
          _stat('AVG', _fmt(avg), unit),
          _stat('MAX', _fmt(max), unit),
          _stat('N', '${_samples.length}', ''),
        ],
      ),
    );
  }

  Widget _stat(String label, String value, String unit) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: scheme.outline, letterSpacing: 1)),
        const SizedBox(height: 2),
        Text('$value${unit.isEmpty ? '' : ' $unit'}',
            style: const TextStyle(fontWeight: FontWeight.w500)),
      ],
    );
  }

  Widget _list(MetricMeta meta) {
    if (_samples.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final descending = _samples.reversed.toList();
    return ListView.separated(
      itemCount: descending.length,
      separatorBuilder: (_, __) =>
          Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.3)),
      itemBuilder: (_, i) {
        final s = descending[i];
        return ListTile(
          dense: true,
          leading: Icon(meta.icon, color: scheme.primary, size: 18),
          title: Text('${s.displayValue}${s.unit.isEmpty ? '' : ' ${s.unit}'}'),
          trailing: Text(_hms(s.ts.toLocal()), style: Theme.of(context).textTheme.bodySmall),
        );
      },
    );
  }

  static String _rfc3339(DateTime utc) => '${utc.toIso8601String().split('.').first}Z';
  static String _fmt(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
  static String _hms(DateTime d) =>
      '${_p(d.hour)}:${_p(d.minute)}:${_p(d.second)}';
  static String _p(int n) => n.toString().padLeft(2, '0');
}

/// The scrubbable + pinch-zoomable line graph.
///
/// Single-finger drag → fl_chart's built-in scrub tooltip (value at that time).
/// Two-finger pinch → zoom the horizontal (time) window; two-finger drag → pan.
/// A "reset" chip returns to the full day. A [Listener] taps the raw pointer
/// stream so single-finger touches still reach the chart's own recognizers.
class _MetricChart extends StatefulWidget {
  const _MetricChart({super.key, required this.day, required this.samples, required this.unit});

  final DateTime day;
  final List<Sample> samples;
  final String unit;

  @override
  State<_MetricChart> createState() => _MetricChartState();
}

class _MetricChartState extends State<_MetricChart> {
  late double _dayStartMs;
  late double _dayEndMs;
  late double _minX;
  late double _maxX;

  final _pointers = <int, Offset>{};
  double? _lastFocalX;
  double? _lastSpanX;

  static const _minWindowMs = 60 * 1000.0; // don't zoom finer than 1 minute
  static const _plotLeft = 40.0; // approx left-axis reserved width

  @override
  void initState() {
    super.initState();
    _reset();
  }

  void _reset() {
    _dayStartMs = widget.day.millisecondsSinceEpoch.toDouble();
    _dayEndMs = widget.day.add(const Duration(days: 1)).millisecondsSinceEpoch.toDouble();
    _minX = _dayStartMs;
    _maxX = _dayEndMs;
  }

  bool get _zoomed => (_maxX - _minX) < (_dayEndMs - _dayStartMs) - 1;

  void _onDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    _lastFocalX = _lastSpanX = null;
  }

  void _onUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    _lastFocalX = _lastSpanX = null;
  }

  void _onMove(PointerMoveEvent e, double width) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length < 2) return; // single finger → let the chart scrub

    final pts = _pointers.values.toList();
    final focalX = (pts[0].dx + pts[1].dx) / 2;
    final spanX = (pts[0].dx - pts[1].dx).abs().clamp(1.0, double.infinity);
    if (_lastFocalX == null || _lastSpanX == null) {
      _lastFocalX = focalX;
      _lastSpanX = spanX;
      return;
    }

    final plotW = (width - _plotLeft).clamp(1.0, double.infinity);
    double screenToData(double sx) => _minX + ((sx - _plotLeft) / plotW) * (_maxX - _minX);

    final focalData = screenToData(focalX);
    final scale = _lastSpanX! / spanX; // spread fingers → span↑ → scale<1 → zoom in
    final fullWidth = _dayEndMs - _dayStartMs;
    final newWidth = ((_maxX - _minX) * scale).clamp(_minWindowMs, fullWidth);

    final rel = ((focalX - _plotLeft) / plotW).clamp(0.0, 1.0);
    final panData = ((focalX - _lastFocalX!) / plotW) * newWidth;
    var newMin = focalData - rel * newWidth - panData;
    var newMax = newMin + newWidth;

    if (newMin < _dayStartMs) {
      newMin = _dayStartMs;
      newMax = newMin + newWidth;
    }
    if (newMax > _dayEndMs) {
      newMax = _dayEndMs;
      newMin = newMax - newWidth;
    }

    setState(() {
      _minX = newMin;
      _maxX = newMax;
    });
    _lastFocalX = focalX;
    _lastSpanX = spanX;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Listener(
              onPointerDown: _onDown,
              onPointerMove: (e) => _onMove(e, width),
              onPointerUp: _onUp,
              onPointerCancel: _onUp,
              child: LineChart(_chartData(context)),
            ),
            if (_zoomed)
              Positioned(
                top: 2,
                right: 2,
                child: ActionChip(
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  label: const Text('reset', style: TextStyle(fontSize: 11)),
                  onPressed: () => setState(_reset),
                ),
              ),
          ],
        );
      },
    );
  }

  LineChartData _chartData(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Show full-resolution detail inside the visible window (downsampled to keep
    // the trace smooth), so zooming in reveals fine structure.
    final margin = (_maxX - _minX) * 0.02;
    final visible = [
      for (final s in widget.samples)
        if (() {
          final x = s.ts.toLocal().millisecondsSinceEpoch.toDouble();
          return x >= _minX - margin && x <= _maxX + margin;
        }())
          s,
    ];
    final points = _downsample(visible, 800);
    final spots = [
      for (final s in points)
        FlSpot(s.ts.toLocal().millisecondsSinceEpoch.toDouble(), s.value),
    ];

    final vals = widget.samples.map((s) => s.value).toList();
    final minV = vals.reduce((a, b) => a < b ? a : b);
    final maxV = vals.reduce((a, b) => a > b ? a : b);
    final pad = ((maxV - minV) * 0.12).clamp(1.0, double.infinity);
    final labelInterval = ((_maxX - _minX) / 4).clamp(60000.0, double.infinity);

    return LineChartData(
      minX: _minX,
      maxX: _maxX,
      minY: minV - pad,
      maxY: maxV + pad,
      clipData: const FlClipData.all(),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: false,
          color: scheme.primary,
          barWidth: 2,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(show: true, color: scheme.primary.withValues(alpha: 0.12)),
        ),
      ],
      gridData: FlGridData(
        show: true,
        drawVerticalLine: true,
        verticalInterval: labelInterval,
        getDrawingHorizontalLine: (_) =>
            FlLine(color: scheme.outlineVariant.withValues(alpha: 0.3), strokeWidth: 0.5),
        getDrawingVerticalLine: (_) =>
            FlLine(color: scheme.outlineVariant.withValues(alpha: 0.3), strokeWidth: 0.5),
      ),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 40,
            getTitlesWidget: (v, meta) =>
                Text(_short(v), style: TextStyle(fontSize: 10, color: scheme.outline)),
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 26,
            interval: labelInterval,
            getTitlesWidget: (v, meta) {
              // Skip labels near the edges so they don't clip on the chart bounds.
              final edge = (_maxX - _minX) * 0.06;
              if (v <= _minX + edge || v >= _maxX - edge) {
                return const SizedBox.shrink();
              }
              final t = DateTime.fromMillisecondsSinceEpoch(v.toInt());
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('${_p(t.hour)}:${_p(t.minute)}',
                    style: TextStyle(fontSize: 10, color: scheme.outline)),
              );
            },
          ),
        ),
      ),
      lineTouchData: LineTouchData(
        handleBuiltInTouches: true,
        touchTooltipData: LineTouchTooltipData(
          fitInsideHorizontally: true,
          fitInsideVertically: true,
          getTooltipColor: (_) => scheme.inverseSurface,
          getTooltipItems: (touched) => touched.map((s) {
            final t = DateTime.fromMillisecondsSinceEpoch(s.x.toInt());
            final val =
                s.y == s.y.roundToDouble() ? s.y.toInt().toString() : s.y.toStringAsFixed(1);
            return LineTooltipItem(
              '${_p(t.hour)}:${_p(t.minute)}:${_p(t.second)}\n$val${widget.unit.isEmpty ? '' : ' ${widget.unit}'}',
              TextStyle(color: scheme.onInverseSurface, fontFamily: kMonoFont, fontSize: 12),
            );
          }).toList(),
        ),
      ),
    );
  }

  static String _p(int n) => n.toString().padLeft(2, '0');

  static String _short(double v) {
    if (v.abs() >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
    return v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(0);
  }

  static List<Sample> _downsample(List<Sample> s, int maxPoints) {
    if (s.length <= maxPoints) return s;
    final step = (s.length / maxPoints).ceil();
    final out = <Sample>[for (int i = 0; i < s.length; i += step) s[i]];
    if (s.isNotEmpty && out.last != s.last) out.add(s.last);
    return out;
  }
}
