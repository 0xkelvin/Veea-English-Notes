import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class LocaleProvider extends ChangeNotifier {
  static const _key = 'app_locale';
  final _storage = const FlutterSecureStorage();

  bool _isVietnamese = false;
  bool get isVietnamese => _isVietnamese;

  Future<void> init() async {
    final val = await _storage.read(key: _key);
    _isVietnamese = val == 'vi';
    notifyListeners();
  }

  Future<void> setLocale(bool vietnamese) async {
    _isVietnamese = vietnamese;
    await _storage.write(key: _key, value: vietnamese ? 'vi' : 'en');
    notifyListeners();
  }
}
