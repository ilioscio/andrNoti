import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  static const _keyServerUrl            = 'server_url';
  static const _keyToken                = 'token';
  static const _keyShowDebugPanel       = 'show_debug_panel';
  static const _keyRelayDownGraceSeconds = 'relay_down_grace_seconds';

  final String serverUrl; // e.g. wss://notify.ilios.dev/ws
  final String token;
  final bool showDebugPanel;
  final int relayDownGraceSeconds; // grace period before relay-down local notification

  const AppConfig({
    required this.serverUrl,
    required this.token,
    this.showDebugPanel = false,
    this.relayDownGraceSeconds = 120,
  });

  bool get isConfigured => serverUrl.isNotEmpty && token.isNotEmpty;

  /// Derive the HTTP base URL from the WebSocket URL for /history calls.
  String get httpBase {
    final u = serverUrl
        .replaceFirst(RegExp(r'^wss://'), 'https://')
        .replaceFirst(RegExp(r'^ws://'), 'http://')
        .replaceFirst(RegExp(r'/ws$'), '');
    return u;
  }

  static Future<AppConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppConfig(
      serverUrl:             prefs.getString(_keyServerUrl) ?? '',
      token:                 prefs.getString(_keyToken) ?? '',
      showDebugPanel:        prefs.getBool(_keyShowDebugPanel) ?? false,
      relayDownGraceSeconds: prefs.getInt(_keyRelayDownGraceSeconds) ?? 120,
    );
  }

  static Future<void> save({
    required String serverUrl,
    required String token,
    required bool showDebugPanel,
    required int relayDownGraceSeconds,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyServerUrl, serverUrl.trim());
    await prefs.setString(_keyToken, token.trim());
    await prefs.setBool(_keyShowDebugPanel, showDebugPanel);
    await prefs.setInt(_keyRelayDownGraceSeconds, relayDownGraceSeconds);
  }
}
