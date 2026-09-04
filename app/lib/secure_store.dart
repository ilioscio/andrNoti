import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Keystore-backed storage for the elevated control token.
///
/// The control token is deliberately kept OUT of SharedPreferences (which is
/// world-readable to the app process and trivially dumped on a rooted device)
/// and in the Android Keystore-backed secure storage instead. The biometric gate
/// controls when it is read; this controls where it lives.
class SecureStore {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _keyControlToken = 'aisthetron_control_token';

  static Future<String?> controlToken() async {
    try {
      return await _storage.read(key: _keyControlToken);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> hasControlToken() async =>
      (await controlToken())?.isNotEmpty ?? false;

  static Future<void> setControlToken(String value) async {
    final v = value.trim();
    if (v.isEmpty) {
      await _storage.delete(key: _keyControlToken);
    } else {
      await _storage.write(key: _keyControlToken, value: v);
    }
  }
}
