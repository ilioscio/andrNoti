import 'package:flutter/material.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'auth_gate.dart';
import 'config.dart';
import 'theme.dart';
import 'root_screen.dart';
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

  runApp(const AisthetronApp());
}

class AisthetronApp extends StatefulWidget {
  const AisthetronApp({super.key});

  @override
  State<AisthetronApp> createState() => _AisthetronAppState();
}

class _AisthetronAppState extends State<AisthetronApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Drop the cached biometric unlock the moment the app leaves the foreground,
    // so returning to it re-prompts before any sensitive action.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      AuthGate.instance.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        // Fall back to a techy teal seed where Material You isn't available.
        final light = lightDynamic ??
            ColorScheme.fromSeed(seedColor: const Color(0xFF00BFA5));
        final dark = darkDynamic ??
            ColorScheme.fromSeed(
              seedColor: const Color(0xFF00BFA5),
              brightness: Brightness.dark,
            );
        return MaterialApp(
          title: 'Aisthetron',
          navigatorKey: navigatorKey,
          theme: buildAisthetronTheme(light),
          darkTheme: buildAisthetronTheme(dark),
          themeMode: ThemeMode.system,
          // WithForegroundTask must live inside MaterialApp so it has access
          // to Navigator and Theme — wrapping MaterialApp caused a second frame.
          home: const WithForegroundTask(child: RootScreen()),
          routes: {
            '/detail': (_) => const DetailScreen(),
            '/config': (_) => const ConfigScreen(),
          },
        );
      },
    );
  }
}
