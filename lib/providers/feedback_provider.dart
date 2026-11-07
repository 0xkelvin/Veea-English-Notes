import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../core/config/app_config.dart';
import '../data/feedback_repository.dart';

String? trustedZaloCommunity(Object? raw) {
  final uri = raw is String ? Uri.tryParse(raw) : null;
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'zalo.me' ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      !RegExp(r'^/g/[A-Za-z0-9_-]+/?$').hasMatch(uri.path) ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return uri.toString();
}

class FeedbackProvider extends ChangeNotifier {
  FeedbackProvider(this.repository);
  final FeedbackRepository repository;
  String _owner = 'guest';
  String get owner => _owner;
  List<FeedbackReport> reports = [];
  bool busy = false;
  String? error;
  String? communityUrl = trustedZaloCommunity(AppConfig.zaloCommunityUrl);
  bool _disposed = false;
  Future<void>? _delivery;
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> activate(String? accountId) async {
    final owner = accountId ?? 'guest';
    _owner = owner;
    reports = [];
    error = null;
    notifyListeners();
    final saved = await repository.list(owner);
    if (owner == _owner) {
      reports = saved;
      notifyListeners();
    }
  }

  Future<bool> submit({
    required String kind,
    required String message,
    String? contact,
    bool diagnostics = false,
    Uint8List? screenshot,
  }) async {
    if (busy) return false;
    if (!['bug', 'feature', 'other'].contains(kind) ||
        message.trim().runes.length < 5 ||
        message.trim().runes.length > 4000 ||
        (contact?.runes.length ?? 0) > 254) {
      error = 'Please describe your idea or problem in 5–4000 characters.';
      notifyListeners();
      return false;
    }
    if (screenshot != null &&
        (screenshot.length > 524288 ||
            !(screenshot.length >= 3 &&
                    screenshot[0] == 255 &&
                    screenshot[1] == 216 &&
                    screenshot[2] == 255) &&
                !(screenshot.length >= 8 &&
                    listEquals(screenshot.take(8).toList(), [
                      137,
                      80,
                      78,
                      71,
                      13,
                      10,
                      26,
                      10,
                    ])))) {
      error = 'Choose a JPG or PNG smaller than 512 KB.';
      notifyListeners();
      return false;
    }
    final owner = _owner;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await repository.enqueue({
        'id': const Uuid().v4(),
        'owner_id': owner,
        'kind': kind,
        'message': message.trim(),
        'contact': contact?.trim().isEmpty == true ? null : contact?.trim(),
        'diagnostics': jsonEncode(
          diagnostics
              ? {
                  'app_version': AppConfig.appVersion,
                  'platform': defaultTargetPlatform.name,
                  'screen': 'feedback',
                }
              : <String, String>{},
        ),
        'screenshot_base64': screenshot == null
            ? null
            : base64Encode(screenshot),
        'status': 'queued',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      await _reload(owner);
      // Saving is successful even offline; the receipt status alone means sent.
      return true;
    } catch (_) {
      error = 'Could not save your feedback. Please try again.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _reload(String owner) async {
    final saved = await repository.list(owner);
    if (owner == _owner) {
      reports = saved;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    if (_delivery != null) return _delivery;
    if (!AppConfig.isCloudEnabled) {
      await _reload(_owner);
      return;
    }
    final owner = _owner;
    return _delivery = _refresh(owner).whenComplete(() => _delivery = null);
  }

  Future<void> _refresh(String owner) async {
    error = null;
    try {
      final config = await repository.config();
      communityUrl =
          trustedZaloCommunity(config['zalo_community_url']) ??
          trustedZaloCommunity(AppConfig.zaloCommunityUrl);
      await repository.deliver(owner);
    } catch (_) {
      if (owner == _owner) {
        error = 'Could not connect. Unsent feedback stays on this device.';
      }
    }
    await _reload(owner);
  }

  Future<void> discard(String id) async {
    await repository.discard(_owner, id);
    await _reload(_owner);
  }
}
