import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'config.dart';
import 'models.dart';

// Populated in the main isolate so onNotificationResponse can navigate to detail.
final Map<int, AppNotification> notificationStore = {};

// ── Local notification setup ──────────────────────────────────────────────────

const _androidChannel = AndroidNotificationChannel(
  'andrnoti_alerts',
  'andrNoti Alerts',
  description: 'Incoming push notifications',
  importance: Importance.high,
);

final _localNotifications = FlutterLocalNotificationsPlugin();

Future<void> initLocalNotifications({
  DidReceiveNotificationResponseCallback? onNotificationResponse,
}) async {
  const initSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  );
  await _localNotifications.initialize(
    initSettings,
    onDidReceiveNotificationResponse: onNotificationResponse,
  );
  await _localNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(_androidChannel);
}

// ── Debug helper ──────────────────────────────────────────────────────────────

void _dbg(String msg) {
  // ignore: avoid_print
  print('[andrNoti] $msg');
  FlutterForegroundTask.sendDataToMain({'type': 'debug', 'msg': msg});
}

// ── Foreground Task Handler ───────────────────────────────────────────────────

@pragma('vm:entry-point')
class NotificationTaskHandler extends TaskHandler {
  WebSocket? _ws;
  int _retryDelay = 2;
  bool _stopped = false;
  bool _connecting = false;

  late AppConfig _config;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _dbg('onStart called');
    _config = await AppConfig.load();
    _dbg('config: url="${_config.serverUrl}" configured=${_config.isConfigured}');
    if (_config.isConfigured) {
      await _connect();
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    if (!_stopped && _ws == null && !_connecting) {
      _dbg('onRepeatEvent: ws null, reconnecting');
      _connect();
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    _dbg('onDestroy');
    _stopped = true;
    await _ws?.close();
  }

  @override
  void onReceiveData(Object data) {
    if (data is Map && data['cmd'] == 'reconnect') {
      _dbg('onReceiveData: reconnect to ${data['serverUrl']}');
      _config = AppConfig(
        serverUrl: data['serverUrl'] as String,
        token: data['token'] as String,
      );
      _ws?.close();
      _ws = null;
      _connecting = false;
      _connect();
    }
  }

  Future<void> _connect() async {
    if (_stopped || _connecting) return;
    _connecting = true;
    final url = '${_config.serverUrl}?token=${_config.token}';
    _dbg('_connect: $url');
    try {
      _ws = await WebSocket.connect(url);
      _dbg('_connect: handshake OK, readyState=${_ws!.readyState}');
      _connecting = false;
      _retryDelay = 2;
      FlutterForegroundTask.updateService(
        notificationTitle: 'andrNoti',
        notificationText: 'Connected',
      );
      _ws!.listen(
        _onMessage,
        onError: (e) { _dbg('ws error: $e'); _scheduleReconnect(); },
        onDone: () { _dbg('ws closed'); _scheduleReconnect(); },
        cancelOnError: true,
      );
    } catch (e) {
      _dbg('_connect failed: $e');
      _ws = null;
      _connecting = false;
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_stopped) return;
    _ws = null;
    _connecting = false;
    _dbg('reconnect in ${_retryDelay}s');
    FlutterForegroundTask.updateService(
      notificationTitle: 'andrNoti',
      notificationText: 'Reconnecting in ${_retryDelay}s…',
    );
    final delay = _retryDelay;
    _retryDelay = min(_retryDelay * 2, 60);
    Future.delayed(Duration(seconds: delay), () {
      if (!_stopped) _connect();
    });
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    final Map<String, dynamic> msg;
    try {
      msg = json.decode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (msg['type']) {
      case 'notification':
        final n = AppNotification.fromJson(msg);
        _dbg('notification id=${n.id}: ${n.title}');
        _showAlert(n);
        FlutterForegroundTask.sendDataToMain(msg);
        FlutterForegroundTask.updateService(
          notificationTitle: 'andrNoti',
          notificationText: n.title.isNotEmpty ? n.title : n.text,
        );
      case 'history':
        final count = (msg['notifications'] as List?)?.length ?? 0;
        _dbg('history: $count items');
        FlutterForegroundTask.sendDataToMain(msg);
    }
  }

  void _showAlert(AppNotification n) {
    _localNotifications.show(
      n.id.hashCode & 0x7FFFFFFF,
      n.title.isNotEmpty ? n.title : 'Notification',
      n.text,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _androidChannel.id,
          _androidChannel.name,
          channelDescription: _androidChannel.description,
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      payload: n.id.toString(),
    );
  }
}

// ── Service control ───────────────────────────────────────────────────────────

void initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'andrnoti_service',
      channelName: 'andrNoti Service',
      channelDescription: 'Keeps the andrNoti connection alive',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(15000),
      autoRunOnBoot: true,
      autoRunOnMyPackageReplaced: true,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

Future<void> requestNotificationPermission() =>
    FlutterForegroundTask.requestNotificationPermission();

Future<ServiceRequestResult> startForegroundService() {
  return FlutterForegroundTask.startService(
    serviceId: 1001,
    notificationTitle: 'andrNoti',
    notificationText: 'Starting…',
    notificationIcon: null,
    callback: _startCallback,
  );
}

@pragma('vm:entry-point')
void _startCallback() {
  FlutterForegroundTask.setTaskHandler(NotificationTaskHandler());
}

Future<ServiceRequestResult> restartForegroundService({
  required String serverUrl,
  required String token,
}) async {
  if (await FlutterForegroundTask.isRunningService) {
    FlutterForegroundTask.sendDataToTask({
      'cmd': 'reconnect',
      'serverUrl': serverUrl,
      'token': token,
    });
    return FlutterForegroundTask.restartService();
  } else {
    return startForegroundService();
  }
}
