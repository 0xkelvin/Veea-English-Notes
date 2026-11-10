import 'dart:async';
import 'package:flutter/foundation.dart';
import '../core/config/app_config.dart';
import '../data/remote/auth_api.dart';
import '../data/remote/api_client.dart';
import 'auth_provider.dart';

String? vietnamPhone(String raw) {
  var value = raw.trim().replaceAll(RegExp(r'[\s().-]'), '');
  if (value.startsWith('+84')) {
    value = value.substring(3);
  } else if (value.startsWith('0')) {
    value = value.substring(1);
  }
  return RegExp(r'^[35789][0-9]{8}$').hasMatch(value) ? '+84$value' : null;
}

const codeExpiredMessage = 'This code expired. Request a new code.';
final _codePattern = RegExp(r'^[0-9]{4,10}$');

/// Resend cooldown and code expiry for one outstanding OTP challenge.
///
/// The ticker keeps running until the code has expired, not just until resend
/// becomes available, so the screen learns about expiry without user input.
mixin OtpCountdown on ChangeNotifier {
  DateTime Function() get clock;
  DateTime? _resendAt, _expiresAt;
  Timer? _timer;
  bool _disposed = false;
  bool _expiryAnnounced = false;

  int get retryIn => _resendAt == null
      ? 0
      : _resendAt!.difference(clock()).inSeconds.clamp(0, 3600);
  DateTime? get codeExpiresAt => _expiresAt;
  bool get expired => _expiresAt != null && !clock().isBefore(_expiresAt!);

  /// Seconds left before the current code expires, or null with no code.
  int? get expiresIn =>
      _expiresAt?.difference(clock()).inSeconds.clamp(0, 3600);

  /// Called once when the outstanding code expires.
  void onCodeExpired();

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }

  void startCountdown(OtpChallenge challenge) {
    _resendAt = clock().add(Duration(seconds: challenge.retryAfter));
    _expiresAt = clock().add(Duration(seconds: challenge.expiresIn));
    _expiryAnnounced = false;
    _tick();
  }

  void cooldown([Duration wait = const Duration(seconds: 60)]) {
    _resendAt = clock().add(wait);
    _tick();
  }

  void resetCountdown() {
    _timer?.cancel();
    _timer = null;
    _resendAt = null;
    _expiresAt = null;
    _expiryAnnounced = false;
  }

  void _tick() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed) {
        _timer?.cancel();
        return;
      }
      if (expired && !_expiryAnnounced) {
        _expiryAnnounced = true;
        onCodeExpired();
      }
      notifyListeners();
      if (retryIn == 0 && (_expiresAt == null || expired)) _timer?.cancel();
    });
  }
}

class PhoneAuthController extends ChangeNotifier with OtpCountdown {
  PhoneAuthController(
    this.auth, {
    this.forDeletion = false,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final AuthProvider auth;
  final bool forDeletion;
  final DateTime Function() _now;
  @override
  DateTime Function() get clock => _now;
  bool busy = false, checking = true, available = false;
  String? error;
  OtpChallenge? challenge;

  @override
  void onCodeExpired() {
    if (challenge != null) error = codeExpiredMessage;
  }

  Future<void> initialize() async {
    checking = true;
    error = null;
    notifyListeners();
    if (!AppConfig.isCloudEnabled) {
      available = false;
      checking = false;
      notifyListeners();
      return;
    }
    try {
      available =
          (await auth.api.clientConfig())['phone_otp_available'] == true;
    } catch (_) {
      available = false;
      error = 'Could not connect. Your words are saved on this device.';
    }
    checking = false;
    notifyListeners();
  }

  Future<bool> send(String raw) async {
    final phone = vietnamPhone(raw);
    if (_disposed || busy || retryIn > 0 || !available) return false;
    if (phone == null) {
      error = 'Enter a Vietnamese mobile number, such as 0901234567.';
      notifyListeners();
      return false;
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      final next = (await auth.api.requestOtp(
        phone,
        forDeletion: forDeletion,
      )).withPhone(phone);
      if (_disposed) return false;
      challenge = next;
      startCountdown(next);
      return true;
    } on ApiException catch (e) {
      if (e.statusCode == 429) cooldown();
      error = e.statusCode == 429
          ? 'Too many requests. Please wait before trying again.'
          : e is OfflineException
          ? 'Could not connect. Please check your connection.'
          : e.statusCode == 503
          ? 'Could not send a code right now. Please try again later.'
          : e.message;
      return false;
    } catch (_) {
      error = 'Could not send a code. Please try again later.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void changePhone() {
    challenge = null;
    error = null;
    resetCountdown();
    notifyListeners();
  }

  Future<bool> verify(String code) async {
    if (_disposed || busy || challenge == null) return false;
    if (expired) {
      error = codeExpiredMessage;
      notifyListeners();
      return false;
    }
    if (!_codePattern.hasMatch(code.trim())) {
      error = 'Enter the verification code from your message.';
      notifyListeners();
      return false;
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      final success = forDeletion
          ? await auth.deletePhoneAccount(
              challenge!,
              code.trim(),
              codeExpiresAt: codeExpiresAt,
            )
          : await auth.verifyPhone(challenge!, code.trim());
      if (!success) {
        error =
            auth.lastError ?? 'Could not verify this code. Please try again.';
      }
      return success;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}

enum PhoneChangeStep { confirmCurrent, enterNew, verifyNew, done }

/// Changing the number takes three proofs-in-order: a code to the current
/// phone, a new number, and a code to that new number. The account, its
/// notebook and its sync position stay the same throughout.
class PhoneChangeController extends ChangeNotifier with OtpCountdown {
  PhoneChangeController(this.auth, {DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final AuthProvider auth;
  final DateTime Function() _now;
  @override
  DateTime Function() get clock => _now;

  static const totalSteps = 3;
  PhoneChangeStep step = PhoneChangeStep.confirmCurrent;
  bool busy = false;

  /// The flow cannot continue on this device (e.g. a replacement session for
  /// another account); the user must sign in again.
  bool blocked = false;
  String? error;
  OtpChallenge? challenge;
  PhoneChangeProof? proof;
  DateTime? _proofExpiresAt;
  String? newPhone;

  int get stepNumber =>
      step == PhoneChangeStep.done ? totalSteps : step.index + 1;
  bool get proofExpired =>
      _proofExpiresAt != null && !_now().isBefore(_proofExpiresAt!);

  @override
  void onCodeExpired() {
    if (challenge != null) error = codeExpiredMessage;
  }

  Future<bool> sendCurrentCode() => _guard(() async {
    final next = await auth.api.requestCurrentPhoneCode();
    if (_disposed) return false;
    challenge = next;
    startCountdown(next);
    return true;
  });

  Future<bool> verifyCurrent(String code) async {
    if (!_checkCode(code)) return false;
    return _guard(() async {
      final next = await auth.api.verifyCurrentPhone(challenge!, code.trim());
      if (_disposed) return false;
      proof = next;
      _proofExpiresAt = _now().add(Duration(seconds: next.expiresIn));
      challenge = null;
      resetCountdown();
      step = PhoneChangeStep.enterNew;
      return true;
    });
  }

  Future<bool> sendNewCode(String raw) async {
    final phone = vietnamPhone(raw);
    if (busy || retryIn > 0) return false;
    if (phone == null) {
      error = 'Enter a Vietnamese mobile number, such as 0901234567.';
      notifyListeners();
      return false;
    }
    final current = auth.profile?.phone ?? auth.identifier;
    if (current != null && vietnamPhone(current) == phone) {
      error = 'That is already your number. Enter a different number.';
      notifyListeners();
      return false;
    }
    if (proof == null || proofExpired) {
      _restart('Your confirmation expired. Confirm your current number again.');
      return false;
    }
    return _guard(() async {
      final next = await auth.api.requestNewPhoneCode(proof!, phone);
      if (_disposed) return false;
      newPhone = phone;
      challenge = next;
      startCountdown(next);
      step = PhoneChangeStep.verifyNew;
      return true;
    });
  }

  Future<bool> resendNewCode() =>
      newPhone == null ? Future.value(false) : sendNewCode(newPhone!);

  Future<bool> confirm(String code) async {
    if (!_checkCode(code)) return false;
    if (proofExpired) {
      _restart('Your confirmation expired. Confirm your current number again.');
      return false;
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      final ok = await auth.completePhoneChange(challenge!, code.trim());
      if (ok) {
        step = PhoneChangeStep.done;
        challenge = null;
        resetCountdown();
        return true;
      }
      error = auth.lastError;
      switch (auth.lastFailureStatus) {
        case 404:
          _restart(error);
        case 409:
          // The proof survives a taken number; pick another one.
          challenge = null;
          resetCountdown();
          step = PhoneChangeStep.enterNew;
        case -1 || 401:
          blocked = true;
      }
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Back to the new-number entry, keeping the current-number proof.
  void editNewNumber() {
    challenge = null;
    error = null;
    resetCountdown();
    step = PhoneChangeStep.enterNew;
    notifyListeners();
  }

  bool _checkCode(String code) {
    if (busy || challenge == null) return false;
    if (expired) {
      error = codeExpiredMessage;
    } else if (!_codePattern.hasMatch(code.trim())) {
      error = 'Enter the verification code from your message.';
    } else {
      return true;
    }
    notifyListeners();
    return false;
  }

  void _restart(String? message) {
    proof = null;
    _proofExpiresAt = null;
    challenge = null;
    newPhone = null;
    resetCountdown();
    step = PhoneChangeStep.confirmCurrent;
    error = message;
    notifyListeners();
  }

  Future<bool> _guard(Future<bool> Function() action) async {
    if (_disposed || busy || blocked) return false;
    busy = true;
    error = null;
    notifyListeners();
    try {
      return await action();
    } on ApiException catch (e) {
      if (e.statusCode == 429) cooldown();
      if (e.statusCode == 404) {
        _restart(AuthProvider.phoneChangeError(e));
      } else {
        error = AuthProvider.phoneChangeError(e);
        if (e.statusCode == 401) blocked = true;
      }
      return false;
    } catch (_) {
      error = 'Something went wrong. Your number has not changed.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
