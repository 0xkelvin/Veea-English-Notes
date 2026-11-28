import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../token_store.dart';
import '../api_client.dart';

/// One secure-storage value contains identity, BOTH tokens and rotation state.
/// Go credentials never fall back to legacy JWTs or an email-derived owner.
class GoSession {
  GoSession(Map<String, Object?> data) : data = Map.unmodifiable(data);
  final Map<String, Object?> data;
  String get generation => data['generation']! as String;
  String get userId => data['user_id']! as String;
  String get sessionId => data['session_id']! as String;
  String get email => data['email']! as String;
  String get access => data['access_token']! as String;
  String get refresh => data['refresh_token']! as String;
  String get refreshState => data['refresh_state'] as String? ?? 'unknown';
}

class GoDeletionReceipt {
  GoDeletionReceipt(Map<String, Object?> data) : data = Map.unmodifiable(data);
  final Map<String, Object?> data;
  String get userId => data['user_id']! as String;
  String get operationId => data['operation_id']! as String;
  String get capability => data['operation_token']! as String;
  String get challenge => data['challenge_token']! as String;
  bool get submitted => data['submitted'] == true;
  bool get locallyCleared => data['locally_cleared'] == true;
  String get state => data['state'] as String? ?? 'awaiting_proof';
  DateTime get proofExpiresAt =>
      DateTime.parse(data['proof_expires_at']! as String);
  GoDeletionReceipt withValues(Map<String, Object?> values) =>
      GoDeletionReceipt({...data, ...values});
}

class GoTokenStore extends TokenStore {
  GoTokenStore({FlutterSecureStorage storage = const FlutterSecureStorage()})
    : _secure = storage;
  static const sessionKey = 'auth.go.session.v1';
  static const receiptKey = 'auth.go.deletion.v1';
  final FlutterSecureStorage _secure;
  Future<void> _lane = Future.value();
  // Shared by transports using THIS store. A restarted process cannot join a
  // prior refresh: its durable in_flight marker requires a fresh sign-in.
  final Map<String, Future<GoSession>> refreshFlights = {};

  Future<T> _locked<T>(Future<T> Function() action) {
    final done = Completer<void>();
    final previous = _lane;
    _lane = done.future;
    return previous.then((_) => action()).whenComplete(done.complete);
  }

  Future<GoSession?> _read() async {
    final raw = await _secure.read(key: sessionKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final data = decoded.cast<String, Object?>();
      for (final field in [
        'generation',
        'user_id',
        'session_id',
        'email',
        'access_token',
        'refresh_token',
      ]) {
        if (data[field] is! String || (data[field]! as String).isEmpty) {
          return null;
        }
      }
      if (!RegExp(
        r'^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$',
      ).hasMatch(data['user_id']! as String)) {
        return null;
      }
      return GoSession(data);
    } on FormatException {
      return null;
    }
  }

  Future<GoSession?> readSession() => _locked(_read);
  Future<void> _write(GoSession session) =>
      _secure.write(key: sessionKey, value: jsonEncode(session.data));

  Future<GoSession> establish(Map<String, Object?> tokens) => _locked(() async {
    final user = (tokens['user']! as Map).cast<String, Object?>();
    final session = GoSession({
      'generation': const Uuid().v4(),
      'user_id': user['id'],
      'email': user['email'],
      'session_id': tokens['session_id'],
      'access_token': tokens['access_token'],
      'refresh_token': tokens['refresh_token'],
      'access_expires_at': tokens['access_expires_at'],
      'refresh_expires_at': tokens['refresh_expires_at'],
      'refresh_state': 'ready',
    });
    await _write(session);
    return session;
  });

  Future<bool> beginRefresh(GoSession expected) => _locked(() async {
    final current = await _read();
    if (current?.generation != expected.generation ||
        current?.access != expected.access ||
        current?.refreshState != 'ready') {
      return false;
    }
    await _write(GoSession({...current!.data, 'refresh_state': 'in_flight'}));
    return true;
  });
  Future<GoSession?> finishRefresh(
    GoSession expected,
    Map<String, Object?> tokens,
  ) => _locked(() async {
    final current = await _read();
    if (current?.generation != expected.generation ||
        current?.refreshState != 'in_flight') {
      return null;
    }
    final user = tokens['user'] as Map;
    if (tokens['session_id'] != expected.sessionId ||
        user['id'] != expected.userId) {
      return null;
    }
    final next = GoSession({
      ...current!.data,
      'access_token': tokens['access_token'],
      'refresh_token': tokens['refresh_token'],
      'access_expires_at': tokens['access_expires_at'],
      'refresh_expires_at': tokens['refresh_expires_at'],
      'refresh_state': 'ready',
    });
    await _write(next); // atomic pair, before any waiter can send it
    return next;
  });
  Future<void> refuseRefresh(GoSession expected, {required bool unknown}) =>
      _locked(() async {
        final current = await _read();
        if (current?.generation == expected.generation &&
            current?.refreshState == 'in_flight') {
          await _write(
            GoSession({
              ...current!.data,
              'refresh_state': unknown ? 'unknown' : 'ready',
            }),
          );
        }
      });
  Future<bool> clearIf(String generation) => _locked(() async {
    if ((await _read())?.generation != generation) return false;
    await _secure.delete(key: sessionKey);
    return true;
  });
  @override
  Future<void> clear() => _locked(() => _secure.delete(key: sessionKey));
  @override
  Future<String?> readAccessToken() async {
    final s = await readSession();
    return s?.refreshState == 'ready' ? s?.access : null;
  }

  @override
  Future<String?> readRefreshToken() async {
    final s = await readSession();
    return s?.refreshState == 'ready' ? s?.refresh : null;
  }

  @override
  Future<String?> readIdentifier() async => (await readSession())?.email;
  @override
  Future<String?> readAccountId() async => (await readSession())?.userId;
  @override
  Future<String?> readAuthMethod() async => 'email';
  @override
  Future<bool> get hasSession async =>
      (await readSession())?.refreshState == 'ready';

  // Legacy save helpers cannot manufacture a Go identity or split its pair.
  @override
  Future<void> save({
    required String accessToken,
    required String refreshToken,
    String? identifier,
    String? accountId,
    String? authMethod,
  }) async {
    throw const ApiException(
      'Could not save this session safely. Sign in again.',
    );
  }

  @override
  Future<void> saveAccessToken(String accessToken) async {
    throw const ApiException(
      'Could not save this session safely. Sign in again.',
    );
  }

  Future<GoDeletionReceipt?> readReceipt() async {
    final raw = await _secure.read(key: receiptKey);
    return raw == null
        ? null
        : GoDeletionReceipt((jsonDecode(raw) as Map).cast<String, Object?>());
  }

  Future<void> saveReceipt(GoDeletionReceipt receipt) => _locked(
    () => _secure.write(key: receiptKey, value: jsonEncode(receipt.data)),
  );
  Future<void> clearReceipt() => _secure.delete(key: receiptKey);
}
