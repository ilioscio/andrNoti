import 'package:flutter/material.dart';

import 'fleet.dart';
import 'theme.dart';

/// The gated log/status viewer for a single unit on a host. The biometric gate
/// and control-token read happen BEFORE this screen is pushed; it receives a
/// ready [FleetClient] and drives the request/poll round-trip.
class LogsScreen extends StatefulWidget {
  const LogsScreen({
    super.key,
    required this.client,
    required this.host,
    required this.unit,
  });

  final FleetClient client;
  final String host;
  final String unit;

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  String _action = 'journal'; // 'journal' | 'unit-status'
  int _lines = 200;
  bool _loading = false;
  String? _error;
  FleetResult? _result;
  DateTime? _fetchedAt;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.client.run(
        host: widget.host,
        action: _action,
        unit: widget.unit,
        lines: _lines,
      );
      if (!mounted) return;
      setState(() {
        _result = r;
        _fetchedAt = DateTime.now();
        _loading = false;
        if (r.isError) _error = r.result;
      });
    } on FleetException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.unit, style: const TextStyle(fontSize: 15)),
            Text(
              widget.host,
              style: TextStyle(fontSize: 11, color: scheme.outline, letterSpacing: 1),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _run,
          ),
        ],
      ),
      body: Column(
        children: [
          _controls(scheme),
          const Divider(height: 1),
          Expanded(child: _output(scheme)),
        ],
      ),
    );
  }

  Widget _controls(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'journal', label: Text('LOG'), icon: Icon(Icons.article_outlined, size: 16)),
              ButtonSegment(value: 'unit-status', label: Text('STATUS'), icon: Icon(Icons.info_outline, size: 16)),
            ],
            selected: {_action},
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onSelectionChanged: _loading
                ? null
                : (s) {
                    setState(() => _action = s.first);
                    _run();
                  },
          ),
          const Spacer(),
          if (_action == 'journal')
            DropdownButton<int>(
              value: _lines,
              underline: const SizedBox.shrink(),
              isDense: true,
              items: const [
                DropdownMenuItem(value: 100, child: Text('100')),
                DropdownMenuItem(value: 200, child: Text('200')),
                DropdownMenuItem(value: 500, child: Text('500')),
                DropdownMenuItem(value: 1000, child: Text('1000')),
              ],
              onChanged: _loading
                  ? null
                  : (v) {
                      if (v == null) return;
                      setState(() => _lines = v);
                      _run();
                    },
            ),
        ],
      ),
    );
  }

  Widget _output(ColorScheme scheme) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('querying ${widget.host}…',
                style: TextStyle(color: scheme.outline, letterSpacing: 1)),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: StatusColors.down, size: 40),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: StatusColors.down)),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: _run,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final r = _result;
    final text = (r?.result.trimRight().isEmpty ?? true) ? '— no output —' : r!.result.trimRight();
    return Column(
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
            child: Scrollbar(
              child: SingleChildScrollView(
                primary: true,
                padding: const EdgeInsets.all(12),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SelectableText(
                    text,
                    style: const TextStyle(fontFamily: kMonoFont, fontSize: 12, height: 1.4),
                  ),
                ),
              ),
            ),
          ),
        ),
        _statusBar(scheme, r),
      ],
    );
  }

  Widget _statusBar(ColorScheme scheme, FleetResult? r) {
    final code = r?.resultCode ?? 0;
    final codeColor = code == 0 ? StatusColors.live : StatusColors.stale;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          StatusLed(color: codeColor, size: 8),
          const SizedBox(width: 8),
          Text('exit $code', style: TextStyle(fontSize: 11, color: scheme.outline, letterSpacing: 1)),
          const Spacer(),
          if (_fetchedAt != null)
            Text(
              'fetched ${_hms(_fetchedAt!)}',
              style: TextStyle(fontSize: 11, color: scheme.outline, letterSpacing: 1),
            ),
        ],
      ),
    );
  }

  static String _hms(DateTime d) =>
      '${_p(d.hour)}:${_p(d.minute)}:${_p(d.second)}';
  static String _p(int n) => n.toString().padLeft(2, '0');
}
