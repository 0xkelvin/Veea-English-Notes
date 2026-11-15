import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// A problem document from the Go API (TRD 01 §5.1, TRD 06 §6.6). Only the
/// stable `code` and the `account_status` extension are kept; titles and any
/// other text are never shown or logged.
class AdminApiException implements Exception {
  const AdminApiException(this.status, this.code, {this.accountStatus});
  final int status;
  final String code;
  final String? accountStatus;
  @override
  String toString() => 'AdminApiException($status, $code)';
}

/// The session can no longer be used: refresh failed or was refused. The
/// console must return to sign-in. Tokens are already cleared.
class SessionEnded implements Exception {
  const SessionEnded();
}

/// The server could not be reached, or the response was lost.
class Offline implements Exception {
  const Offline();
}

class _Tokens {
  const _Tokens(this.access, this.refresh, this.sessionId, this.userId);
  final String access, refresh, sessionId, userId;
}

/// A started email sign-in code.
class CodeChallenge {
  const CodeChallenge(this.email, this.token);
  final String email, token;
}

final _access = RegExp(r'^vat_[A-Za-z0-9_-]{43}$');
final _refresh = RegExp(r'^vrt_[A-Za-z0-9_-]{43}$');

/// HTTP transport for the console (TRD 07 §4).
///
/// Credentials live in memory only: never in local storage, cookies or logs.
/// Reloading the tab ends the console session on this device. A 401 triggers
/// one single-flight refresh and one retry; if that fails the tokens are
/// dropped and [SessionEnded] is thrown. A lost refresh response is treated as
/// an ended session, because retrying the consumed refresh token would be
/// detected by the server as reuse.
class AdminTransport {
  AdminTransport({
    required this.baseUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _http = client ?? http.Client();

  final String baseUrl;
  final Duration timeout;
  final http.Client _http;
  _Tokens? _tokens;
  Future<bool>? _refreshing;

  static const device = {'name': 'Veea Admin Console', 'platform': 'web'};

  bool get signedIn => _tokens != null;
  String? get userId => _tokens?.userId;
  String? get sessionId => _tokens?.sessionId;

  Future<void> passwordLogin(String email, String password) async {
    _adopt(
      await _send(
        'POST',
        '/v1/auth/password/login',
        body: {'email': email, 'password': password, 'device': device},
      ),
    );
  }

  Future<CodeChallenge> startCode(String email) async {
    final body = await _send(
      'POST',
      '/v1/auth/otp/start',
      body: {'email': email},
    );
    final token = body['challenge_token'];
    if (token is! String) throw const AdminApiException(502, 'bad_response');
    return CodeChallenge(email, token);
  }

  Future<void> verifyCode(CodeChallenge challenge, String code) async {
    _adopt(
      await _send(
        'POST',
        '/v1/auth/otp/verify',
        body: {
          'challenge_token': challenge.token,
          'code': code,
          'device': device,
        },
      ),
    );
  }

  /// Ends the session locally first, then tells the server (best effort).
  Future<void> logout() async {
    final old = _tokens;
    _tokens = null;
    if (old == null) return;
    try {
      await _send('POST', '/v1/auth/logout', bearer: old.access);
    } on Object {
      // Local sign-out has already happened.
    }
  }

  /// Drops credentials without a network call (the server already ended them).
  void forget() => _tokens = null;

  /// An authenticated JSON request. Throws [SessionEnded], [Offline] or
  /// [AdminApiException].
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final used = _tokens;
    if (used == null) throw const SessionEnded();
    try {
      return await _send(
        method,
        path,
        query: query,
        body: body,
        bearer: used.access,
      );
    } on AdminApiException catch (e) {
      if (e.status != 401) rethrow;
    }
    if (!await _refreshOnce(used)) {
      _tokens = null;
      throw const SessionEnded();
    }
    try {
      return await _send(
        method,
        path,
        query: query,
        body: body,
        bearer: _tokens!.access,
      );
    } on AdminApiException catch (e) {
      if (e.status == 401) {
        _tokens = null;
        throw const SessionEnded();
      }
      rethrow;
    }
  }

  Future<bool> _refreshOnce(_Tokens used) {
    final current = _tokens;
    if (current == null) return Future.value(false);
    if (current.access != used.access) {
      return Future.value(true); // already rotated
    }
    return _refreshing ??= _rotate(
      current,
    ).whenComplete(() => _refreshing = null);
  }

  Future<bool> _rotate(_Tokens current) async {
    try {
      _adopt(
        await _send(
          'POST',
          '/v1/auth/token/refresh',
          body: {'refresh_token': current.refresh},
        ),
      );
      return true;
    } on AdminApiException catch (e) {
      if (e.code == 'rate_limited') {
        rethrow; // nothing rotated; the caller may retry later
      }
      return false;
    } on Offline {
      return false; // the outcome is unknown: never resend a possibly consumed token
    }
  }

  void _adopt(Map<String, Object?> body) {
    final user = body['user'];
    final access = body['access_token'],
        refresh = body['refresh_token'],
        session = body['session_id'];
    if (user is! Map ||
        user['id'] is! String ||
        access is! String ||
        refresh is! String ||
        session is! String ||
        !_access.hasMatch(access) ||
        !_refresh.hasMatch(refresh)) {
      throw const AdminApiException(502, 'bad_response');
    }
    _tokens = _Tokens(access, refresh, session, user['id'] as String);
  }

  Future<Map<String, Object?>> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    String? bearer,
  }) async {
    var uri = Uri.parse('$baseUrl$path');
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: query);
    }
    final req = http.Request(method, uri)
      ..headers['accept'] = 'application/json';
    if (bearer != null) req.headers['authorization'] = 'Bearer $bearer';
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.bodyBytes = utf8.encode(jsonEncode(body));
    }
    http.Response res;
    try {
      res = await http.Response.fromStream(
        await _http.send(req),
      ).timeout(timeout);
    } on Exception {
      throw const Offline();
    }
    Object? decoded;
    if (res.bodyBytes.isNotEmpty) {
      try {
        decoded = jsonDecode(utf8.decode(res.bodyBytes));
      } on FormatException {
        decoded = null;
      }
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (res.statusCode == 204 || decoded == null) return const {};
      if (decoded is! Map) throw const AdminApiException(502, 'bad_response');
      return decoded.cast<String, Object?>();
    }
    String code = 'request_failed';
    String? accountStatus;
    if (decoded is Map) {
      if (decoded['code'] is String) code = decoded['code'] as String;
      if (decoded['account_status'] is String) {
        accountStatus = decoded['account_status'] as String;
      }
    }
    throw AdminApiException(res.statusCode, code, accountStatus: accountStatus);
  }

  void close() => _http.close();
}
