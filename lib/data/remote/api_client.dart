import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/config/app_config.dart';
import 'token_store.dart';

/// Raised when the server rejects a request.
///
/// [isAuthFailure] distinguishes "your session is over, sign in again" from a
/// transient problem the caller should simply retry later.
class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode, this.code});

  final String message;
  final int? statusCode;
  final String? code;

  bool get isAuthFailure => statusCode == 401;

  /// Whether retrying the same request later could plausibly succeed.
  bool get isTransient =>
      statusCode == null || statusCode! >= 500 || statusCode == 429;

  @override
  String toString() => 'ApiException($statusCode, $message)';
}

/// Thrown when the device cannot reach the server at all.
class OfflineException extends ApiException {
  const OfflineException() : super('No connection to the server');

  @override
  bool get isTransient => true;
}

/// Authenticated JSON transport.
///
/// Owns one concern beyond plain HTTP: when a call fails with 401 it refreshes
/// the access token once and replays the request. Refreshes are funnelled
/// through a single future so a burst of parallel calls cannot each start
/// their own refresh and invalidate one another's tokens.
class ApiClient {
  /// [baseUrl] defaults to the compiled-in server and is overridden by tests.
  ApiClient({
    required TokenStore tokenStore,
    http.Client? httpClient,
    String? baseUrl,
  }) : _tokens = tokenStore,
       _http = httpClient ?? http.Client(),
       _baseUrl = baseUrl ?? AppConfig.apiRoot;

  final TokenStore _tokens;
  final http.Client _http;
  final String _baseUrl;

  /// In-flight refresh, shared by every caller that needs one.
  Future<bool>? _refreshing;

  /// Called when the session is definitively over, so the app can sign out.
  VoidCallback? onSessionExpired;

  Future<Map<String, Object?>> get(
    String path, {
    Map<String, String>? query,
    bool authenticated = true,
  }) {
    return _send(
      (headers) => _http.get(_uri(path, query), headers: headers),
      authenticated: authenticated,
    );
  }

  Future<Map<String, Object?>> post(
    String path, {
    Object? body,
    bool authenticated = true,
  }) {
    return _send(
      (headers) => _http.post(
        _uri(path),
        headers: headers,
        body: body == null ? null : jsonEncode(body),
      ),
      authenticated: authenticated,
    );
  }

  Future<Map<String, Object?>> put(
    String path, {
    Object? body,
    bool authenticated = true,
  }) {
    return _send(
      (headers) => _http.put(
        _uri(path),
        headers: headers,
        body: body == null ? null : jsonEncode(body),
      ),
      authenticated: authenticated,
    );
  }

  /// DELETE with a body — used by account deletion, which carries the
  /// password confirmation.
  Future<Map<String, Object?>> delete(
    String path, {
    Object? body,
    bool authenticated = true,
  }) {
    return _send(
      (headers) => _http.delete(
        _uri(path),
        headers: headers,
        body: body == null ? null : jsonEncode(body),
      ),
      authenticated: authenticated,
    );
  }

  Future<Map<String, Object?>> _send(
    Future<http.Response> Function(Map<String, String> headers) request, {
    required bool authenticated,
  }) async {
    var response = await _perform(request, authenticated: authenticated);

    if (response.statusCode == 401 && authenticated) {
      if (await _refreshAccessToken()) {
        response = await _perform(request, authenticated: true);
      } else {
        onSessionExpired?.call();
      }
    }

    return _decode(response);
  }

  Future<http.Response> _perform(
    Future<http.Response> Function(Map<String, String> headers) request, {
    required bool authenticated,
  }) async {
    final headers = <String, String>{
      'content-type': 'application/json',
      'accept': 'application/json',
    };

    if (authenticated) {
      final token = await _tokens.readAccessToken();
      if (token != null) headers['authorization'] = 'Bearer $token';
    }

    try {
      return await request(headers).timeout(AppConfig.requestTimeout);
    } on Exception catch (error) {
      // Socket errors, DNS failures and timeouts all mean the same thing to
      // the caller: try again when there is a connection.
      debugPrint('Network request failed: $error');
      throw const OfflineException();
    }
  }

  /// Exchanges the refresh token for a new access token.
  ///
  /// Returns false when the session cannot be recovered.
  Future<bool> _refreshAccessToken() {
    // Join the refresh already running, if any.
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<bool> _doRefresh() async {
    final refreshToken = await _tokens.readRefreshToken();
    if (refreshToken == null) return false;

    try {
      final response = await _http
          .post(
            _uri('/auth/refresh'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({'refresh_token': refreshToken}),
          )
          .timeout(AppConfig.requestTimeout);

      if (response.statusCode != 200) {
        // The refresh token itself is rejected — the session is over.
        if (response.statusCode == 401) await _tokens.clear();
        return false;
      }

      final data = _decode(response);
      final accessToken = data['access_token'] as String?;
      final newRefresh = data['refresh_token'] as String?;
      if (accessToken == null) return false;

      if (newRefresh != null) {
        await _tokens.save(accessToken: accessToken, refreshToken: newRefresh);
      } else {
        await _tokens.saveAccessToken(accessToken);
      }
      return true;
    } on Exception catch (error) {
      // Offline: keep the session, the next attempt may succeed.
      debugPrint('Token refresh failed: $error');
      return false;
    }
  }

  /// Unwraps the server's `{ "data": ... }` envelope, or raises the error it
  /// describes.
  Map<String, Object?> _decode(http.Response response) {
    final Object? decoded = response.body.isEmpty
        ? null
        : jsonDecode(utf8.decode(response.bodyBytes));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (decoded is Map<String, Object?>) {
        final data = decoded['data'];
        if (data is Map<String, Object?>) return data;
        return decoded;
      }
      return const {};
    }

    String message = 'Request failed (${response.statusCode})';
    String? code;
    if (decoded is Map<String, Object?>) {
      final error = decoded['error'];
      if (error is Map<String, Object?>) {
        message = error['message'] as String? ?? message;
        code = error['code'] as String?;
      }
    }

    throw ApiException(message, statusCode: response.statusCode, code: code);
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('$_baseUrl$path');
    return query == null ? uri : uri.replace(queryParameters: query);
  }

  void dispose() => _http.close();
}
