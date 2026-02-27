import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_foreground_task/models/service_request_result.dart';
import 'package:http/http.dart' as http;

import 'config.dart';
import 'models.dart';
import 'notification_manager.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  List<AppNotification> _newNotifications = [];
  List<AppNotification> _oldNotifications = [];
  bool _loading = true;
  String? _error;
  bool? _serviceRunning;
  bool _showDebugPanel = false;
  final List<String> _debugLog = [];

  static const _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this)
      ..addListener(() => setState(() {}));
    _loadHistory();
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    _checkService();
    requestNotificationPermission();
  }

  @override
  void dispose() {
    _tabController.dispose();
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    super.dispose();
  }

  // ── Service management ──────────────────────────────────────────────────────

  Future<void> _checkService() async {
    final running = await FlutterForegroundTask.isRunningService;
    if (mounted) setState(() => _serviceRunning = running);
    if (!running) {
      final config = await AppConfig.load();
      if (!config.isConfigured) {
        _log('service: not configured');
        return;
      }
      _log('service: starting…');
      final result = await startForegroundService();
      final ok = result is ServiceRequestSuccess;
      if (mounted) {
        setState(() => _serviceRunning = ok);
        _log('service start result: ${ok ? "OK" : "FAILED — ${result.runtimeType}"}');
      }
    }
  }

  // ── Task data ───────────────────────────────────────────────────────────────

  void _log(String line) {
    setState(() {
      _debugLog.add(line);
      if (_debugLog.length > 30) _debugLog.removeAt(0);
    });
  }

  void _onTaskData(Object data) {
    _log('onTaskData: ${data.runtimeType}');
    try {
      if (data is! Map) return;
      final msg = Map<String, dynamic>.from(data as Map);
      _log('msg type=${msg['type']}');
      switch (msg['type']) {
        case 'notification':
          final n = AppNotification.fromJson(msg);
          notificationStore[n.id] = n;
          setState(() => _newNotifications.insert(0, n));
        case 'history':
          final all = (msg['notifications'] as List? ?? [])
              .map((e) => AppNotification.fromJson(e as Map<String, dynamic>))
              .toList();
          setState(() {
            _newNotifications = all.where((n) => n.seenAt == null).toList();
            _oldNotifications = all.where((n) => n.seenAt != null).toList();
            _loading = false;
          });
        case 'debug':
          _log(msg['msg'] as String? ?? '');
      }
    } catch (e, st) {
      _log('onTaskData ERROR: $e');
      // ignore: avoid_print
      print('[andrNoti] onTaskData error: $e\n$st');
    }
  }

  // ── History ─────────────────────────────────────────────────────────────────

  Future<void> _loadHistory() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final config = await AppConfig.load();
    if (mounted) setState(() => _showDebugPanel = config.showDebugPanel);
    if (!config.isConfigured) {
      setState(() {
        _loading = false;
        _error = 'Not configured. Tap the settings icon.';
      });
      return;
    }
    try {
      final uri = Uri.parse('${config.httpBase}/history?limit=5000');
      final resp = await http.get(
        uri,
        headers: {'Authorization': 'Bearer ${config.token}'},
      );
      if (resp.statusCode == 200) {
        final all = (json.decode(resp.body) as List)
            .map((e) => AppNotification.fromJson(e as Map<String, dynamic>))
            .toList();
        if (mounted) {
          setState(() {
            _newNotifications = all.where((n) => n.seenAt == null).toList();
            _oldNotifications = all.where((n) => n.seenAt != null).toList();
            _loading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = 'Server returned ${resp.statusCode}';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load history: $e';
        });
      }
    }
  }

  // ── Mark seen ───────────────────────────────────────────────────────────────

  Future<void> _markAllSeen() async {
    final config = await AppConfig.load();
    if (!config.isConfigured) return;
    try {
      final resp = await http.post(
        Uri.parse('${config.httpBase}/mark-seen'),
        headers: {'Authorization': 'Bearer ${config.token}'},
      );
      if (resp.statusCode == 200 && mounted) {
        final now = DateTime.now();
        setState(() {
          _oldNotifications = [
            ..._newNotifications.map((n) => AppNotification(
                  id: n.id,
                  title: n.title,
                  text: n.text,
                  createdAt: n.createdAt,
                  seenAt: now,
                )),
            ..._oldNotifications,
          ];
          _newNotifications = [];
        });
      }
    } catch (_) {}
  }

  Future<void> _markOneSeen(AppNotification n) async {
    // Update local state immediately — Dismissible has already removed it visually.
    setState(() {
      _newNotifications.remove(n);
      _oldNotifications = [
        AppNotification(
          id: n.id,
          title: n.title,
          text: n.text,
          createdAt: n.createdAt,
          seenAt: DateTime.now(),
        ),
        ..._oldNotifications,
      ];
    });
    final config = await AppConfig.load();
    if (!config.isConfigured) return;
    try {
      await http.post(
        Uri.parse('${config.httpBase}/mark-seen'),
        headers: {
          'Authorization': 'Bearer ${config.token}',
          'Content-Type': 'application/json',
        },
        body: json.encode({'ids': [n.id]}),
      );
    } catch (_) {}
  }

  // ── Clear history ───────────────────────────────────────────────────────────

  Future<void> _confirmClearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all history?'),
        content: const Text(
            'This permanently deletes all notifications from the server and cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final config = await AppConfig.load();
    if (!config.isConfigured) return;
    try {
      final resp = await http.delete(
        Uri.parse('${config.httpBase}/notifications'),
        headers: {'Authorization': 'Bearer ${config.token}'},
      );
      if ((resp.statusCode == 200 || resp.statusCode == 204) && mounted) {
        setState(() {
          _newNotifications = [];
          _oldNotifications = [];
        });
      }
    } catch (_) {}
  }

  // ── Utilities ───────────────────────────────────────────────────────────────

  String _relativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final showFab = !_loading &&
        _error == null &&
        _tabController.index == 0 &&
        _newNotifications.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: false,
        title: Image.asset('assets/IconWhite.png', height: 32),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () =>
                Navigator.pushNamed(context, '/config').then((_) => _loadHistory()),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              text: _newNotifications.isNotEmpty
                  ? 'New (${_newNotifications.length})'
                  : 'New',
            ),
            const Tab(text: 'Old'),
          ],
        ),
      ),
      body: Column(
        children: [
          if (_showDebugPanel) _buildDebugPanel(),
          Expanded(child: _buildBody()),
        ],
      ),
      floatingActionButton: showFab
          ? FloatingActionButton(
              onPressed: _markAllSeen,
              tooltip: 'Mark all seen',
              child: const Icon(Icons.done_all),
            )
          : null,
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    return TabBarView(
      controller: _tabController,
      children: [
        _buildNewTab(),
        _buildOldTab(),
      ],
    );
  }

  // ── New tab ─────────────────────────────────────────────────────────────────

  Widget _buildNewTab() {
    if (_newNotifications.isEmpty) {
      return const Center(child: Text('All caught up.'));
    }
    return RefreshIndicator(
      onRefresh: _loadHistory,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _newNotifications.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final n = _newNotifications[i];
          return Dismissible(
            key: ValueKey(n.id),
            direction: DismissDirection.startToEnd,
            onDismissed: (_) => _markOneSeen(n),
            background: Container(
              color: Colors.green,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 20),
              child: const Icon(Icons.done_all, color: Colors.white),
            ),
            child: ListTile(
              title: Text(
                n.title.isNotEmpty ? n.title : n.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: n.title.isNotEmpty
                  ? Text(n.text, maxLines: 2, overflow: TextOverflow.ellipsis)
                  : null,
              trailing: Text(
                _relativeTime(n.createdAt),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              onTap: () => Navigator.pushNamed(context, '/detail', arguments: n),
            ),
          );
        },
      ),
    );
  }

  // ── Old tab ─────────────────────────────────────────────────────────────────

  Widget _buildOldTab() {
    // Group into year → month → day → notifications
    final tree = <int, Map<int, Map<int, List<AppNotification>>>>{};
    for (final n in _oldNotifications) {
      final dt = n.createdAt.toLocal();
      tree
          .putIfAbsent(dt.year, () => {})
          .putIfAbsent(dt.month, () => {})
          .putIfAbsent(dt.day, () => [])
          .add(n);
    }
    final years = tree.keys.toList()..sort((a, b) => b.compareTo(a));

    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.delete_outline),
            label: const Text('Clear all history'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
            onPressed: _oldNotifications.isEmpty ? null : _confirmClearHistory,
          ),
        ),
        if (_oldNotifications.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: Text('No archived notifications.')),
          )
        else
          for (final year in years) _buildYearTile(year, tree[year]!),
      ],
    );
  }

  Widget _buildYearTile(
      int year, Map<int, Map<int, List<AppNotification>>> months) {
    final monthKeys = months.keys.toList()..sort((a, b) => b.compareTo(a));
    final total = months.values
        .expand((days) => days.values)
        .expand((ns) => ns)
        .length;
    return ExpansionTile(
      title: Text('$year',
          style: const TextStyle(fontWeight: FontWeight.bold)),
      trailing: Text('$total',
          style: Theme.of(context).textTheme.bodySmall),
      children: [
        for (final month in monthKeys)
          _buildMonthTile(month, months[month]!),
      ],
    );
  }

  Widget _buildMonthTile(int month, Map<int, List<AppNotification>> days) {
    final dayKeys = days.keys.toList()..sort((a, b) => b.compareTo(a));
    final total = days.values.expand((ns) => ns).length;
    return ExpansionTile(
      tilePadding: const EdgeInsets.only(left: 32, right: 16),
      title: Text(_monthNames[month - 1]),
      trailing: Text('$total',
          style: Theme.of(context).textTheme.bodySmall),
      children: [
        for (final day in dayKeys) _buildDayTile(day, month, days[day]!),
      ],
    );
  }

  Widget _buildDayTile(
      int day, int month, List<AppNotification> notifications) {
    return ExpansionTile(
      tilePadding: const EdgeInsets.only(left: 56, right: 16),
      title: Text('$day ${_monthNames[month - 1].substring(0, 3)}'),
      trailing: Text('${notifications.length}',
          style: Theme.of(context).textTheme.bodySmall),
      children: [
        for (final n in notifications)
          ListTile(
            contentPadding: const EdgeInsets.only(left: 72, right: 16),
            title: Text(
              n.title.isNotEmpty ? n.title : n.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: n.title.isNotEmpty
                ? Text(n.text, maxLines: 1, overflow: TextOverflow.ellipsis)
                : null,
            trailing: Text(
              _relativeTime(n.createdAt),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            onTap: () => Navigator.pushNamed(context, '/detail', arguments: n),
          ),
      ],
    );
  }

  // ── Debug panel ─────────────────────────────────────────────────────────────

  Widget _buildDebugPanel() {
    final svcColor =
        _serviceRunning == true ? Colors.greenAccent : Colors.redAccent;
    final svcLabel = _serviceRunning == null
        ? 'service: checking…'
        : _serviceRunning!
            ? 'service: RUNNING'
            : 'service: STOPPED';
    return Container(
      width: double.infinity,
      color: Colors.black87,
      padding: const EdgeInsets.all(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(svcLabel,
                  style: TextStyle(
                      color: svcColor, fontFamily: 'monospace', fontSize: 11)),
              const Spacer(),
              TextButton(
                onPressed: _checkService,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white70,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('⟳ restart',
                    style:
                        TextStyle(fontFamily: 'monospace', fontSize: 11)),
              ),
            ],
          ),
          if (_debugLog.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 120),
              child: SingleChildScrollView(
                reverse: true,
                child: Text(
                  _debugLog.join('\n'),
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontFamily: 'monospace',
                    fontSize: 10,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
