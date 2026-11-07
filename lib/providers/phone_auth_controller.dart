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

class PhoneAuthController extends ChangeNotifier {
  PhoneAuthController(
    this.auth, {
    this.forDeletion = false,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final AuthProvider auth;
  final bool forDeletion;
  final DateTime Function() _now;
  bool busy = false, checking = true, available = false;
  String? error;
  OtpChallenge? challenge;
  DateTime? _resendAt, _expiresAt;
  Timer? _timer;
  bool _disposed = false;
  int get retryIn => _resendAt == null
      ? 0
      : _resendAt!.difference(_now()).inSeconds.clamp(0, 3600);
  bool get expired => _expiresAt != null && !_now().isBefore(_expiresAt!);
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

  Future<void> initialize() async {
    checking = true;
    error = null;
    notifyListeners();
    try {
      available =
          AppConfig.isCloudEnabled &&
          (await auth.api.clientConfig())['phone_otp_available'] == true;
    } catch (_) {
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
      challenge = (await auth.api.requestOtp(
        phone,
        forDeletion: forDeletion,
      )).withPhone(phone);
      _resendAt = _now().add(Duration(seconds: challenge!.retryAfter));
      _expiresAt = _now().add(Duration(seconds: challenge!.expiresIn));
      if (_disposed) return false;
      _startTimer();
      return true;
    } on ApiException catch (e) {
      if (e.statusCode == 429) {
        _resendAt = _now().add(const Duration(seconds: 60));
        _startTimer();
      }
      error = e.statusCode == 429
          ? 'Too many requests. Please wait before trying again.'
          : e is OfflineException
          ? 'Could not connect. Please check your connection.'
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

  void _startTimer() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      notifyListeners();
      if (retryIn == 0) _timer?.cancel();
    });
  }

  void changePhone() {
    challenge = null;
    _resendAt = null;
    _expiresAt = null;
    error = null;
    _timer?.cancel();
    notifyListeners();
  }

  Future<bool> verify(String code) async {
    if (_disposed || busy || challenge == null) return false;
    if (expired) {
      error = 'This code expired. Please request a new code.';
      notifyListeners();
      return false;
    }
    if (!RegExp(r'^[0-9]{4,10}$').hasMatch(code.trim())) {
      error = 'Enter the verification code from your message.';
      notifyListeners();
      return false;
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      final success = forDeletion
          ? await auth.deletePhoneAccount(challenge!, code.trim())
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
