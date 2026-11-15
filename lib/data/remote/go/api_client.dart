import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../../core/config/app_config.dart';
import '../api_client.dart';
import 'session_store.dart';

class SessionChanged extends ApiException {
  const SessionChanged()
    : super('The session changed. Please try again.', code: 'session_changed');
}

class FreshSignInRequired extends ApiException {
  const FreshSignInRequired()
    : super(
        'Your session could not be recovered safely. Sign in again.',
        statusCode: 401,
        code: 'fresh_signin_required',
      );
}

/// Go transport. No envelope, body-token refresh, no grace, and generation
/// checks on every authenticated response and credential write.
class GoApiClient extends ApiClient {
  factory GoApiClient({
    required GoTokenStore tokens,
    http.Client? httpClient,
    String? baseUrl,
    Duration timeout = const Duration(seconds: 20),
  }) => GoApiClient._(
    tokens,
    httpClient ?? http.Client(),
    baseUrl ?? AppConfig.apiBaseUrl,
    timeout,
  );
  GoApiClient._(this.store, this._http, this._base, this._timeout)
    : super(tokenStore: store, httpClient: _http, baseUrl: _base);
  final GoTokenStore store;
  final http.Client _http;
  final String _base;
  final Duration _timeout;

  Uri _uri(String path, Map<String, String>? query) {
    final base = Uri.tryParse(_base);
    if (base == null ||
        !['http', 'https'].contains(base.scheme) ||
        base.host.isEmpty) {
      throw const OfflineException();
    }
    final uri = Uri.parse('$_base$path');
    return query == null || query.isEmpty
        ? uri
        : uri.replace(queryParameters: query);
  }

  Future<void> _same(GoSession expected) async {
    if ((await store.readSession())?.generation != expected.generation) {
      throw const SessionChanged();
    }
  }

  Future<Never> _expire(GoSession expected) async {
    if (await store.clearIf(expected.generation)) onSessionExpired?.call();
    throw const FreshSignInRequired();
  }

  Future<GoSession> _authorized() async {
    final current = await store.readSession();
    if (current == null) throw const FreshSignInRequired();
    final active = store.refreshFlights[current.generation];
    if (active != null) return active;
    if (current.refreshState != 'ready') return _expire(current);
    return current;
  }

  Future<GoSession> _refresh(GoSession used) async {
    final current = await store.readSession();
    if (current?.generation != used.generation) throw const SessionChanged();
    final flight = store.refreshFlights[used.generation];
    if (flight != null) return flight;
    // A delayed 401 for the old access token must use the already persisted
    // pair, not rotate it a second time.
    if (current!.access != used.access && current.refreshState == 'ready') {
      return current;
    }
    final next = _rotate(current);
    store.refreshFlights[used.generation] = next;
    try {
      return await next;
    } finally {
      store.refreshFlights.remove(used.generation);
    }
  }

  Future<GoSession> _rotate(GoSession expected) async {
    if (!await store.beginRefresh(expected)) return _expire(expected);
    http.Response response;
    try {
      response = await _http
          .post(
            _uri('/v1/auth/token/refresh', null),
            headers: const {
              'content-type': 'application/json',
              'accept': 'application/json',
            },
            body: jsonEncode({'refresh_token': expected.refresh}),
          )
          .timeout(_timeout);
    } on Exception {
      await store.refuseRefresh(expected, unknown: true);
      return _expire(expected);
    }
    await _same(expected);
    if (response.statusCode == 429 ||
        response.statusCode == 400 ||
        response.statusCode == 415) {
      // Explicit pre-rotation refusals. No automatic retry in this run.
      await store.refuseRefresh(expected, unknown: false);
      throw problem(response);
    }
    if (response.statusCode != 200) {
      await store.refuseRefresh(expected, unknown: response.statusCode != 401);
      return _expire(expected);
    }
    try {
      final body = decode(response);
      validateTokens(body);
      final saved = await store.finishRefresh(expected, body);
      if (saved == null) {
        await _same(expected);
        throw const ApiException(
          'The refreshed session could not be verified.',
        );
      }
      return saved;
    } on SessionChanged {
      rethrow;
    } on ApiException {
      await store.refuseRefresh(expected, unknown: true);
      return _expire(expected);
    } on Exception {
      await store.refuseRefresh(expected, unknown: true);
      return _expire(expected);
    }
  }

  Future<http.Response> raw(
    String method,
    String path, {
    Uint8List? body,
    Map<String, String>? query,
    Map<String, String>? extraHeaders,
    bool authenticated = true,
    String? expectedUserId,
  }) async {
    GoSession? session = authenticated ? await _authorized() : null;
    if (expectedUserId != null && session?.userId != expectedUserId) {
      throw const SessionChanged();
    }
    Future<http.Response> perform() async {
      final req = http.Request(method, _uri(path, query));
      req.headers.addAll({
        'accept': 'application/json',
        'content-type': 'application/json',
        ...?extraHeaders,
      });
      if (session != null) {
        req.headers['authorization'] = 'Bearer ${session.access}';
      }
      if (body != null) req.bodyBytes = body;
      try {
        return await (() async => http.Response.fromStream(
          await _http.send(req),
        ))().timeout(_timeout);
      } on Exception {
        throw const OfflineException();
      }
    }

    var response = await perform();
    if (session != null) {
      await _same(session);
      if (response.statusCode == 401) {
        session = await _refresh(session);
        response = await perform();
        await _same(session);
        if (response.statusCode == 401) return _expire(session);
      }
    }
    return response;
  }

  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$',
  );
  static void validateTokens(Map<String, Object?> body) {
    final user = body['user'];
    if (user is! Map ||
        !_uuid.hasMatch(user['id']?.toString() ?? '') ||
        user['email'] is! String ||
        !_uuid.hasMatch(body['session_id']?.toString() ?? '') ||
        !RegExp(
          r'^vat_[A-Za-z0-9_-]{43}$',
        ).hasMatch(body['access_token']?.toString() ?? '') ||
        !RegExp(
          r'^vrt_[A-Za-z0-9_-]{43}$',
        ).hasMatch(body['refresh_token']?.toString() ?? '') ||
        DateTime.tryParse(body['access_expires_at']?.toString() ?? '') ==
            null ||
        DateTime.tryParse(body['refresh_expires_at']?.toString() ?? '') ==
            null) {
      throw const ApiException(
        'Invalid authentication response. Sign in again.',
      );
    }
  }

  static const _messages = {
    'unauthorized': 'Your session ended. Sign in again.',
    'invalid_credentials': 'The email or password is incorrect.',
    'account_unavailable': 'This account is unavailable.',
    'invalid_code': 'The code is invalid or expired.',
    'code_attempts_exceeded': 'Too many code attempts. Request a new code.',
    'rate_limited': 'Too many attempts. Please wait and try again.',
    'invalid_email': 'Enter a valid email address.',
    'password_policy_violation': 'Use a stronger password (12–128 characters).',
    'signup_unavailable': 'This signup cannot complete. Try signing in.',
    'lifecycle_conflict':
        'The account changed. Request a new verification code.',
    'not_found': 'This operation is unavailable or its receipt expired.',
    'plan_required': 'Premium is required for this download or update.',
    'capacity_changed':
        'Capacity changed. Review and confirm the import again.',
    'sync_reset_required':
        'The server was restored. Review the pending installation.',
    'sync_unavailable': 'Cloud sync is not available yet.',
  };
  static ApiException problem(http.Response r) {
    String? code;
    try {
      final body = jsonDecode(utf8.decode(r.bodyBytes));
      if (body is Map) code = body['code'] as String?;
    } catch (_) {
      /* never echo a response */
    }
    return ApiException(
      _messages[code] ?? 'The request could not complete. Please try again.',
      statusCode: r.statusCode,
      code: _messages.containsKey(code) ? code : 'request_failed',
    );
  }

  static Map<String, Object?> decode(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw problem(response);
    }
    if (response.bodyBytes.isEmpty) return {};
    try {
      return (jsonDecode(utf8.decode(response.bodyBytes)) as Map)
          .cast<String, Object?>();
    } catch (_) {
      throw const ApiException('The server response could not be read.');
    }
  }

  Future<Map<String, Object?>> _json(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    Map<String, String>? extraHeaders,
    bool authenticated = true,
  }) async => decode(
    await raw(
      method,
      path,
      body: body == null ? null : utf8.encode(jsonEncode(body)),
      query: query,
      extraHeaders: extraHeaders,
      authenticated: authenticated,
    ),
  );
  @override
  Future<Map<String, Object?>> get(
    String path, {
    Map<String, String>? query,
    Map<String, String>? extraHeaders,
    bool authenticated = true,
  }) => _json(
    'GET',
    path,
    query: query,
    extraHeaders: extraHeaders,
    authenticated: authenticated,
  );
  @override
  Future<Map<String, Object?>> post(
    String path, {
    Object? body,
    Map<String, String>? extraHeaders,
    bool authenticated = true,
  }) => _json(
    'POST',
    path,
    body: body,
    extraHeaders: extraHeaders,
    authenticated: authenticated,
  );
  @override
  Future<Map<String, Object?>> put(
    String path, {
    Object? body,
    Map<String, String>? extraHeaders,
    bool authenticated = true,
  }) => _json(
    'PUT',
    path,
    body: body,
    extraHeaders: extraHeaders,
    authenticated: authenticated,
  );
  @override
  Future<Map<String, Object?>> delete(
    String path, {
    Object? body,
    Map<String, String>? extraHeaders,
    bool authenticated = true,
  }) => _json(
    'DELETE',
    path,
    body: body,
    extraHeaders: extraHeaders,
    authenticated: authenticated,
  );
}

/// The sync engine keeps its exact body BLOB; this adapter supplies the same
/// single-flight/fenced authentication as GET /v1/me without re-encoding it.
class GoLearningHttpClient extends http.BaseClient {
  GoLearningHttpClient(this.api);
  final GoApiClient api;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    try {
      final response = await api.raw(
        request.method,
        request.url.path,
        query: request.url.queryParameters,
        body: await request.finalize().toBytes(),
      );
      return http.StreamedResponse(
        Stream.value(response.bodyBytes),
        response.statusCode,
        headers: response.headers,
      );
    } on FreshSignInRequired {
      return http.StreamedResponse(
        Stream.value(utf8.encode('{"code":"unauthorized"}')),
        401,
      );
    } on SessionChanged {
      return http.StreamedResponse(
        Stream.value(utf8.encode('{"code":"sync_unavailable"}')),
        503,
      );
    }
  }
}
