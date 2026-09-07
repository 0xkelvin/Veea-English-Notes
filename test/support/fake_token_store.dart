import 'package:veea_english_app/data/remote/token_store.dart';

/// In-memory [TokenStore] for tests.
///
/// The real one talks to the platform keychain, which is not available under
/// `flutter test`.
class FakeTokenStore implements TokenStore {
  String? accessToken;
  String? refreshToken;
  String? identifier;
  String? lastAccount;

  /// How many times the session was cleared, so tests can assert that a failed
  /// operation did *not* sign the user out.
  int clearCount = 0;

  @override
  Future<String?> readAccessToken() async => accessToken;

  @override
  Future<String?> readRefreshToken() async => refreshToken;

  @override
  Future<String?> readIdentifier() async => identifier;

  @override
  Future<bool> get hasSession async => refreshToken != null;

  @override
  Future<void> save({
    required String accessToken,
    required String refreshToken,
    String? identifier,
  }) async {
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
    if (identifier != null) this.identifier = identifier;
  }

  @override
  Future<void> saveAccessToken(String accessToken) async {
    this.accessToken = accessToken;
  }

  @override
  Future<void> saveIdentifier(String identifier) async {
    this.identifier = identifier;
  }

  @override
  Future<String?> readLastAccount() async => lastAccount;

  @override
  Future<void> saveLastAccount(String account) async {
    lastAccount = account;
  }

  @override
  Future<void> clearLastAccount() async {
    lastAccount = null;
  }

  @override
  Future<void> clear() async {
    accessToken = null;
    refreshToken = null;
    identifier = null;
    clearCount++;
  }
}
