import 'package:flutter/foundation.dart';

import '../auth_api.dart';
import '../api_client.dart';
import 'api_client.dart';
import 'session_store.dart';

class EmailChallenge {
  const EmailChallenge({
    required this.email,
    required this.token,
    required this.expiresAt,
    required this.resendAfter,
    required this.signup,
  });
  final String email, token;
  final DateTime expiresAt, resendAfter;
  final bool signup;
}

class GoSignIn extends AuthSession {
  GoSignIn(this.response)
    : super(
        accessToken: response['access_token']! as String,
        refreshToken: response['refresh_token']! as String,
        accountId: (response['user']! as Map)['id']! as String,
        identifier: (response['user']! as Map)['email']! as String,
        method: 'email',
      );
  final Map<String, Object?> response;
  static GoSignIn parse(Map<String, Object?> body) {
    GoApiClient.validateTokens(body);
    return GoSignIn(body);
  }
}

class DeleteStatus {
  DeleteStatus(this.body);
  final Map<String, Object?> body;
  String get id => body['operation_id']! as String;
  String get state => body['state']! as String;
  bool get accepted =>
      body['action'] == 'delete' &&
      body['accepted_at'] is String &&
      DateTime.tryParse(body['accepted_at']! as String) != null &&
      (state == 'pending' || state == 'completed');
}

class GoAuthApi extends AuthApi {
  GoAuthApi({
    required GoApiClient client,
    required GoTokenStore tokens,
    Map<String, String>? device,
  }) : go = client,
       store = tokens,
       _device =
           device ?? {'name': 'Veea ${_platform()}', 'platform': _platform()},
       super(client: client, tokens: tokens);
  final GoApiClient go;
  final GoTokenStore store;
  final Map<String, String> _device;
  static String _platform() => kIsWeb
      ? 'web'
      : switch (defaultTargetPlatform) {
          TargetPlatform.iOS => 'ios',
          TargetPlatform.android => 'android',
          _ => 'other',
        };
  Future<EmailChallenge> startEmail(
    String email, {
    bool signup = false,
    String? password,
  }) async {
    final body = await go.post(
      signup
          ? '/v1/auth/signup/${password == null ? 'otp' : 'password'}/start'
          : '/v1/auth/otp/start',
      body: {
        'email': email,
        if (signup && password != null) 'password': password,
      },
      authenticated: false,
    );
    return EmailChallenge(
      email: email,
      token: body['challenge_token']! as String,
      expiresAt: DateTime.parse(body['expires_at']! as String),
      resendAfter: DateTime.parse(body['resend_after']! as String),
      signup: signup,
    );
  }

  Future<GoSignIn> verifyEmail(EmailChallenge challenge, String code) async =>
      GoSignIn.parse(
        await go.post(
          challenge.signup ? '/v1/auth/signup/verify' : '/v1/auth/otp/verify',
          authenticated: false,
          body: {
            'challenge_token': challenge.token,
            'code': code,
            'device': _device,
          },
        ),
      );
  @override
  Future<GoSignIn> passwordSession({
    required String identifier,
    required String password,
    bool register = false,
  }) async {
    if (register) {
      throw const ApiException('Verify a signup code before signing in.');
    }
    return GoSignIn.parse(
      await go.post(
        '/v1/auth/password/login',
        authenticated: false,
        body: {'email': identifier, 'password': password, 'device': _device},
      ),
    );
  }

  @override
  Future<AccountProfile> profile() async =>
      AccountProfile.fromJson(await go.get('/v1/me'));
  Future<Map<String, Object?>> sessions() => go.get('/v1/me/sessions');
  Future<void> revokeSession(String id) async {
    await go.delete('/v1/me/sessions/$id');
  }

  Future<void> logoutAll() async {
    await go.delete('/v1/me/sessions');
  }

  @override
  Future<void> logout() async {
    final old = await store.readSession();
    if (old == null) return;
    // Invalidate first. Never let a late refresh repopulate credentials, and
    // never rotate merely to log out. Offline/expired logout is best effort.
    await store.clearIf(old.generation);
    try {
      await go.post(
        '/v1/auth/logout',
        authenticated: false,
        extraHeaders: {'authorization': 'Bearer ${old.access}'},
      );
    } on ApiException {
      /* local sign-out still succeeds */
    }
  }

  Future<GoDeletionReceipt> startDelete(String email, String userId) async {
    final body = await go.post(
      '/v1/account-rights/delete/start',
      body: {'email': email},
      authenticated: false,
    );
    return GoDeletionReceipt({
      'user_id': userId,
      'operation_id': body['operation_id'],
      'operation_token': body['operation_token'],
      'challenge_token': body['challenge_token'],
      'proof_expires_at': body['expires_at'],
      'resend_after': body['resend_after'],
      'submitted': false,
      'locally_cleared': false,
      'state': 'awaiting_proof',
    });
  }

  Future<DeleteStatus> completeDelete(
    GoDeletionReceipt receipt,
    String code,
  ) async => _status(
    receipt,
    await go.post(
      '/v1/account-rights/delete/${receipt.operationId}/complete',
      authenticated: false,
      extraHeaders: {'authorization': 'Rights ${receipt.capability}'},
      body: {
        'challenge_token': receipt.challenge,
        'code': code,
        'confirm': 'delete_account',
      },
    ),
  );
  Future<DeleteStatus> deletionStatus(GoDeletionReceipt receipt) async =>
      _status(
        receipt,
        await go.get(
          '/v1/account-rights/deletions/${receipt.operationId}',
          authenticated: false,
          extraHeaders: {'authorization': 'Rights ${receipt.capability}'},
        ),
      );
  DeleteStatus _status(GoDeletionReceipt receipt, Map<String, Object?> body) {
    if (body['operation_id'] != receipt.operationId ||
        body['action'] != 'delete' ||
        body['state'] is! String) {
      throw const ApiException('The deletion receipt could not be verified.');
    }
    return DeleteStatus(body);
  }

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await go.put(
      '/v1/me/password',
      body: {'current_password': currentPassword, 'new_password': newPassword},
    );
  }
}
