/// The reported state of one systemd unit on a host.
class UnitStatus {
  final String unit;
  final String active; // active | inactive | failed | activating …
  final String sub; // running | dead | exited | failed …
  final bool failed;
  final DateTime? updatedAt;

  const UnitStatus({
    required this.unit,
    required this.active,
    required this.sub,
    required this.failed,
    this.updatedAt,
  });

  /// A short "active/sub" descriptor, e.g. "active/running".
  String get stateLabel => '$active/$sub';

  factory UnitStatus.fromJson(Map<String, dynamic> json) {
    return UnitStatus(
      unit: json['unit'] as String,
      active: (json['active'] as String?) ?? '',
      sub: (json['sub'] as String?) ?? '',
      failed: (json['failed'] as bool?) ?? false,
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String)
          : null,
    );
  }
}

/// A machine known to the relay — either a heartbeat source (live infrastructure)
/// or an event source (something that has only ever sent notifications).
class Machine {
  final String source;
  final String kind; // 'heartbeat' | 'event'
  final int? interval;
  final DateTime lastSeen;
  final String status; // 'live' | 'stale' | 'down' | 'unknown'
  final bool alerted;
  final bool monitor; // false = intermittent device (no down/up alerts)
  final Map<String, dynamic>? health;
  final List<UnitStatus> units;
  final int notificationCount;
  final DateTime? lastNotificationAt;

  const Machine({
    required this.source,
    required this.kind,
    required this.lastSeen,
    required this.status,
    this.interval,
    this.alerted = false,
    this.monitor = true,
    this.health,
    this.units = const [],
    this.notificationCount = 0,
    this.lastNotificationAt,
  });

  bool get isHeartbeat => kind == 'heartbeat';

  bool get hasFailedUnit => units.any((u) => u.failed);

  factory Machine.fromJson(Map<String, dynamic> json) {
    final rawUnits = (json['units'] as List?) ?? const [];
    return Machine(
      source: json['source'] as String,
      kind: (json['kind'] as String?) ?? 'event',
      interval: (json['interval'] as num?)?.toInt(),
      lastSeen: DateTime.parse(json['last_seen'] as String),
      status: (json['status'] as String?) ?? 'unknown',
      alerted: (json['alerted'] as bool?) ?? false,
      monitor: (json['monitor'] as bool?) ?? true,
      health: (json['health'] as Map?)?.cast<String, dynamic>(),
      units: rawUnits
          .map((e) => UnitStatus.fromJson(e as Map<String, dynamic>))
          .toList(),
      notificationCount: (json['notification_count'] as num?)?.toInt() ?? 0,
      lastNotificationAt: json['last_notification_at'] != null
          ? DateTime.parse(json['last_notification_at'] as String)
          : null,
    );
  }
}
