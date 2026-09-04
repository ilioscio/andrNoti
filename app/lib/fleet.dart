import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Client for the relay's fleet command queue (log retrieval, and later control).
///
/// Every call here is elevated: it carries the CONTROL token, not the broadcast
/// token. The control token is read from the Keystore only after the biometric
/// gate passes, then handed to this client for the duration of the action.
class FleetClient {
  FleetClient({
    required this.httpBase,
    required this.controlToken,
  });

  final String httpBase;
  final String controlToken;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $controlToken',
        'Content-Type': 'application/json',
      };

  /// Enqueues a command and returns its id. Throws [FleetException] on refusal.
  Future<int> enqueue({
    required String host,
    required String action, // 'journal' | 'unit-status'
    required String unit,
    int lines = 200,
  }) async {
    final resp = await http.post(
      Uri.parse('$httpBase/fleet/command'),
      headers: _headers,
      body: json.encode({
        'host': host,
        'action': action,
        'unit': unit,
        'lines': lines,
        'requester': 'aisthetron-app',
      }),
    );
    switch (resp.statusCode) {
      case 200:
        return (json.decode(resp.body) as Map<String, dynamic>)['id'] as int;
      case 401:
        throw FleetException('Control token rejected by the relay.');
      case 503:
        throw FleetException('Control scope is not enabled on the relay.');
      default:
        throw FleetException('Relay error ${resp.statusCode}: ${resp.body.trim()}');
    }
  }

  /// Polls until the command finishes (done/error) or the timeout elapses.
  Future<FleetResult> awaitResult(
    int id, {
    Duration timeout = const Duration(seconds: 30),
    Duration interval = const Duration(milliseconds: 700),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final resp = await http.get(
        Uri.parse('$httpBase/fleet/command?id=$id'),
        headers: {'Authorization': 'Bearer $controlToken'},
      );
      if (resp.statusCode != 200) {
        throw FleetException('Relay error ${resp.statusCode} polling result.');
      }
      final r = FleetResult.fromJson(json.decode(resp.body) as Map<String, dynamic>);
      if (r.isTerminal) return r;
      if (DateTime.now().isAfter(deadline)) {
        throw FleetException('Timed out waiting for the host to respond.');
      }
      await Future.delayed(interval);
    }
  }

  /// Convenience: enqueue + await in one call.
  Future<FleetResult> run({
    required String host,
    required String action,
    required String unit,
    int lines = 200,
  }) async {
    final id = await enqueue(host: host, action: action, unit: unit, lines: lines);
    return awaitResult(id);
  }
}

class FleetResult {
  final int id;
  final String host;
  final String action;
  final String unit;
  final String status; // pending | claimed | done | error
  final String result;
  final int resultCode;

  const FleetResult({
    required this.id,
    required this.host,
    required this.action,
    required this.unit,
    required this.status,
    required this.result,
    required this.resultCode,
  });

  bool get isTerminal => status == 'done' || status == 'error';
  bool get isError => status == 'error';

  factory FleetResult.fromJson(Map<String, dynamic> j) => FleetResult(
        id: (j['id'] as num).toInt(),
        host: (j['host'] as String?) ?? '',
        action: (j['action'] as String?) ?? '',
        unit: (j['unit'] as String?) ?? '',
        status: (j['status'] as String?) ?? 'pending',
        result: (j['result'] as String?) ?? '',
        resultCode: (j['result_code'] as num?)?.toInt() ?? 0,
      );
}

class FleetException implements Exception {
  FleetException(this.message);
  final String message;
  @override
  String toString() => message;
}
