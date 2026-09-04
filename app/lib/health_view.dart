import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'config.dart';
import 'metric_history_screen.dart';
import 'sample.dart';
import 'theme.dart';
import 'time_util.dart';

/// Health dashboard — the latest reading per metric collected from the watch,
/// with a "last updated" freshness line and tap-through to per-metric history.
class HealthView extends StatefulWidget {
  const HealthView({super.key, this.onHome});

  final VoidCallback? onHome;

  @override
  State<HealthView> createState() => _HealthViewState();
}

class _HealthViewState extends State<HealthView> {
  List<Sample> _latest = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
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
        _error = 'Not configured. Open Settings from the home screen.';
      });
      return;
    }
    try {
      final resp = await http.get(
        Uri.parse('${config.httpBase}/metrics/latest'),
        headers: {'Authorization': 'Bearer ${config.token}'},
      );
      if (resp.statusCode == 200) {
        final list = (json.decode(resp.body) as List)
            .map((e) => Sample.fromJson(e as Map<String, dynamic>))
            .toList();
        if (mounted) {
          setState(() {
            _latest = list;
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
          _error = 'Could not load health: $e';
        });
      }
    }
  }

  DateTime? get _dataAsOf => _latest.isEmpty
      ? null
      : _latest.map((s) => s.ts).reduce((a, b) => a.isAfter(b) ? a : b);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: widget.onHome == null
            ? null
            : IconButton(
                icon: const Icon(Icons.home_outlined),
                tooltip: 'Home',
                onPressed: widget.onHome,
              ),
        title: const Text('Health'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _lastUpdatedRow(),
          const SizedBox(height: 4),
          if (_latest.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 80),
              child: Center(child: Text('No health data yet.')),
            )
          else
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.25,
              children: [
                for (final s in _latest)
                  _MetricTile(
                    sample: s,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => MetricHistoryScreen(metric: s.metric),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _lastUpdatedRow() {
    final asOf = _dataAsOf;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          if (asOf != null) ...[
            StatusLed(color: freshnessColor(asOf), size: 8),
            const SizedBox(width: 8),
          ],
          Text(
            'UPDATED ${asOf == null ? '—' : relativeTime(asOf)}',
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            visualDensity: VisualDensity.compact,
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.sample, required this.onTap});

  final Sample sample;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final meta = metricMeta(sample.metric);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(meta.icon, color: scheme.primary, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      meta.label.toUpperCase(),
                      style: TextStyle(fontSize: 11, letterSpacing: 1, color: scheme.outline),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Flexible(
                    child: Text(
                      sample.displayValue,
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (sample.unit.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Text(sample.unit, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  StatusLed(color: freshnessColor(sample.ts), size: 8),
                  const SizedBox(width: 6),
                  Text(
                    relativeTime(sample.ts),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
