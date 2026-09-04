import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// Biometric / device-credential gate for sensitive actions (viewing logs, and
/// later service control).
///
/// IMPORTANT: this is a LOCAL convenience barrier, not a security boundary. The
/// real boundary is the server's control scope (a separate token, held in the
/// Keystore). This just stops someone who picks up an unlocked phone from poking
/// at your servers, and unlocks access to the stored control token in-app. A
/// successful unlock is cached briefly so a session of reading logs isn't a
/// fingerprint-per-tap; the cache is cleared whenever the app goes to background.
class AuthGate {
  AuthGate._();
  static final AuthGate instance = AuthGate._();

  final LocalAuthentication _auth = LocalAuthentication();

  /// How long a successful unlock stays valid.
  static const Duration _ttl = Duration(minutes: 5);

  DateTime? _lastOk;

  bool get _cached =>
      _lastOk != null && DateTime.now().difference(_lastOk!) < _ttl;

  /// Clears the cached unlock — call when the app is backgrounded.
  void clear() => _lastOk = null;

  /// Prompts for biometric/device-credential auth (unless still cached).
  /// Returns an [AuthOutcome] describing success or why it failed.
  Future<AuthOutcome> require(String reason) async {
    if (_cached) return AuthOutcome.ok;
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) return AuthOutcome.unavailable;

      final ok = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: false, // allow PIN/pattern fallback
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
      if (ok) {
        _lastOk = DateTime.now();
        return AuthOutcome.ok;
      }
      return AuthOutcome.failed;
    } on PlatformException catch (e) {
      // NotAvailable / PasscodeNotSet / NotEnrolled → no lock to check against.
      if (e.code == 'NotAvailable' ||
          e.code == 'PasscodeNotSet' ||
          e.code == 'NotEnrolled') {
        return AuthOutcome.unavailable;
      }
      return AuthOutcome.failed;
    }
  }
}

enum AuthOutcome {
  ok,
  failed,
  /// No biometric AND no device lock configured — can't gate.
  unavailable,
}

extension AuthOutcomeX on AuthOutcome {
  String get message => switch (this) {
        AuthOutcome.ok => 'Authenticated',
        AuthOutcome.failed => 'Authentication failed or cancelled',
        AuthOutcome.unavailable =>
          'No device lock configured — set a PIN/biometric to view logs',
      };
}
