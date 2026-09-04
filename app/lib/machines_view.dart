import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'auth_gate.dart';
import 'config.dart';
import 'fleet.dart';
import 'logs_screen.dart';
import 'machine.dart';
import 'secure_store.dart';
import 'theme.dart';
import 'time_util.dart';

/// Machines — the infra "control view": glowing status LEDs, a node tally, and
/// terminal-style rows for every heartbeat/event source the relay has seen.
class MachinesView extends StatefulWidget {
  const MachinesView({super.key, this.onHome});

  final VoidCallback? onHome;

  @override
  State<MachinesView> createState() => _MachinesViewState();
}

class _MachinesViewState extends State<MachinesView> {
  List<Machine> _machines = [];
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
        Uri.parse('${config.httpBase}/machines'),
        headers: {'Authorization': 'Bearer ${config.token}'},
      );
      if (resp.statusCode == 200) {
        final list = (json.decode(resp.body) as List)
            .map((e) => Machine.fromJson(e as Map<String, dynamic>))
            .toList();
        if (mounted) {
          setState(() {
            _machines = list;
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
          _error = 'Could not load machines: $e';
        });
      }
    }
  }

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
        title: const Text('Machines'),
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
    return Column(
      children: [
        _tallyBar(),
        const Divider(height: 1),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: _machines.isEmpty
                ? ListView(children: const [
                    SizedBox(height: 220),
                    Center(child: Text('No machines seen yet.')),
                  ])
                : ListView.separated(
                    itemCount: _machines.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) => _MachineRow(
                      machine: _machines[i],
                      onTap: () => showModalBottomSheet(
                        context: context,
                        showDragHandle: true,
                        builder: (_) => _MachineDetail(machine: _machines[i]),
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _tallyBar() {
    final scheme = Theme.of(context).colorScheme;
    int count(String s) => _machines.where((m) => m.status == s).length;
    final live = count('live');
    final stale = count('stale');
    final down = count('down');
    final other = _machines.length - live - stale - down;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          Text('NODES', style: TextStyle(fontSize: 11, letterSpacing: 2, color: scheme.outline)),
          const SizedBox(width: 8),
          Text('${_machines.length}', style: const TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          _tallyChip(live, StatusColors.live),
          _tallyChip(stale, StatusColors.stale),
          _tallyChip(down, StatusColors.down),
          _tallyChip(other, StatusColors.unknown),
        ],
      ),
    );
  }

  Widget _tallyChip(int n, Color color) {
    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusLed(color: color, size: 9),
          const SizedBox(width: 5),
          Text('$n', style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

class _MachineRow extends StatelessWidget {
  const _MachineRow({required this.machine, required this.onTap});

  final Machine machine;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = machine;
    final statusColor = StatusColors.forStatus(m.status);
    final metaStyle = TextStyle(fontSize: 12, color: scheme.outline);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StatusLed(color: statusColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(m.source, style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                Text(
                  _statusLabel(m),
                  style: TextStyle(color: statusColor, fontWeight: FontWeight.w600, fontSize: 12, letterSpacing: 1),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 22),
              child: Text(_metaLine(m), style: metaStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (m.health != null && m.health!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 22, top: 2),
                child: Text(
                  m.health!.entries.take(3).map((e) => '${e.key} ${e.value}').join('   '),
                  style: metaStyle.copyWith(color: scheme.primary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (m.hasFailedUnit)
              Padding(
                padding: const EdgeInsets.only(left: 22, top: 3),
                child: Row(
                  children: [
                    const StatusLed(color: StatusColors.down, size: 7),
                    const SizedBox(width: 6),
                    Text(
                      () {
                        final n = m.units.where((u) => u.failed).length;
                        return '$n service${n == 1 ? '' : 's'} failed';
                      }(),
                      style: metaStyle.copyWith(color: StatusColors.down, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _statusLabel(Machine m) =>
      m.status == 'unknown' ? '—' : m.status.toUpperCase();

  static String _metaLine(Machine m) {
    if (m.isHeartbeat) {
      final silent = m.monitor ? '' : ' · silent';
      return 'heartbeat · ${m.interval}s$silent · ${relativeTime(m.lastSeen)}';
    }
    final n = m.notificationCount;
    return 'event · $n msg${n == 1 ? '' : 's'} · ${relativeTime(m.lastSeen)}';
  }
}

/// A readout panel for a single machine.
class _MachineDetail extends StatelessWidget {
  const _MachineDetail({required this.machine});

  final Machine machine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = machine;
    final statusColor = StatusColors.forStatus(m.status);
    final health = m.health;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusLed(color: statusColor, size: 14),
              const SizedBox(width: 10),
              Expanded(
                child: Text(m.source.toUpperCase(),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(letterSpacing: 1)),
              ),
              Text(_MachineRow._statusLabel(m),
                  style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 1)),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),
          _row(context, 'KIND', m.isHeartbeat ? 'heartbeat' : 'event source'),
          if (m.isHeartbeat) _row(context, 'INTERVAL', '${m.interval}s${m.monitor ? '' : '  (silent)'}'),
          _row(context, 'LAST SEEN', '${relativeTime(m.lastSeen)}   ${_hms(m.lastSeen.toLocal())}'),
          if (m.notificationCount > 0)
            _row(context, 'MESSAGES',
                '${m.notificationCount}${m.lastNotificationAt != null ? '  ·  last ${relativeTime(m.lastNotificationAt!)}' : ''}'),
          if (m.units.isNotEmpty) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Text('─ SERVICES ─',
                    style: TextStyle(color: scheme.outline, letterSpacing: 2, fontSize: 12)),
                const SizedBox(width: 8),
                Icon(Icons.lock_outline, size: 12, color: scheme.outline),
              ],
            ),
            const SizedBox(height: 8),
            for (final u in m.units) _UnitRow(host: m.source, unit: u),
          ],
          if (health != null && health.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('─ HEALTH ─', style: TextStyle(color: scheme.outline, letterSpacing: 2, fontSize: 12)),
            const SizedBox(height: 8),
            for (final e in health.entries) _row(context, e.key, '${e.value}', valueColor: scheme.primary),
          ] else if (!m.isHeartbeat) ...[
            const SizedBox(height: 12),
            Text('No live health — event source only.',
                style: TextStyle(color: scheme.outline)),
          ],
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value, {Color? valueColor}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: TextStyle(color: scheme.outline, fontSize: 12, letterSpacing: 1)),
          ),
          Expanded(child: Text(value, style: TextStyle(color: valueColor))),
        ],
      ),
    );
  }

  static String _hms(DateTime d) =>
      '${_p(d.hour)}:${_p(d.minute)}:${_p(d.second)}';
  static String _p(int n) => n.toString().padLeft(2, '0');
}

/// A tappable service row. Tapping opens the log viewer, gated behind biometric
/// auth and the presence of a control token.
class _UnitRow extends StatelessWidget {
  const _UnitRow({required this.host, required this.unit});

  final String host;
  final UnitStatus unit;

  static Color _color(UnitStatus u) {
    if (u.failed) return StatusColors.down;
    return switch (u.active) {
      'active' => StatusColors.live,
      'activating' || 'deactivating' || 'reloading' => StatusColors.stale,
      'inactive' => StatusColors.unknown,
      _ => StatusColors.unknown,
    };
  }

  Future<void> _openLogs(BuildContext context) async {
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    // Gate 1: a control token must be configured.
    if (!await SecureStore.hasControlToken()) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Set a control token in Settings to view logs.'),
      ));
      return;
    }
    // Gate 2: biometric / device credential.
    final outcome = await AuthGate.instance.require('Authenticate to view $host logs');
    if (outcome != AuthOutcome.ok) {
      messenger.showSnackBar(SnackBar(content: Text(outcome.message)));
      return;
    }

    final token = await SecureStore.controlToken();
    final config = await AppConfig.load();
    if (token == null || token.isEmpty) return;

    final client = FleetClient(httpBase: config.httpBase, controlToken: token);
    nav.pop(); // close the detail sheet
    nav.push(MaterialPageRoute(
      builder: (_) => LogsScreen(client: client, host: host, unit: unit.unit),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => _openLogs(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            StatusLed(color: _color(unit), size: 9),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                unit.unit,
                style: const TextStyle(fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              unit.stateLabel,
              style: TextStyle(fontSize: 11, color: _color(unit), letterSpacing: 0.5),
            ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, size: 18, color: scheme.outline),
          ],
        ),
      ),
    );
  }
}
