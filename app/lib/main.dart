import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'config.dart';
import 'home_screen.dart';
import 'detail_screen.dart';
import 'config_screen.dart';
import 'notification_manager.dart';

// Global key so onNotificationResponse can navigate from outside the widget tree.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// Receives taps on alert notifications (must be top-level, @pragma for tree-shaking).
@pragma('vm:entry-point')
void onNotificationResponse(NotificationResponse response) {
  final id = int.tryParse(response.payload ?? '');
  if (id == null) return;
  final n = notificationStore[id];
  if (n != null) {
    navigatorKey.currentState?.pushNamed('/detail', arguments: n);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Opens the ReceivePort and registers its SendPort so that sendDataToMain
  // in the task isolate can find it via IsolateNameServer.
  FlutterForegroundTask.initCommunicationPort();

  initForegroundTask();
  await initLocalNotifications(onNotificationResponse: onNotificationResponse);

  final config = await AppConfig.load();
  if (config.isConfigured) {
    await startForegroundService();
  }

  runApp(const AndrNotiApp());
}

class AndrNotiApp extends StatelessWidget {
  const AndrNotiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'andrNoti',
      navigatorKey: navigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      // WithForegroundTask must live inside MaterialApp so it has access
      // to Navigator and Theme — wrapping MaterialApp caused a second frame.
      home: const WithForegroundTask(child: HomeScreen()),
      routes: {
        '/detail': (_) => const DetailScreen(),
        '/config': (_) => const ConfigScreen(),
      },
    );
  }
}
