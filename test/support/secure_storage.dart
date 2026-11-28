import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure-storage boundary for host tests. A disk-backed instance lets a new
/// provider/store/SQLite handle recover state without retaining Dart objects.
/// Contents are synthetic and the temporary directory is removed by the test.
class TestSecureStorage extends FlutterSecureStorage {
  TestSecureStorage({this.file});
  final File? file;
  String? failingDeleteKey;
  final Map<String, String> _values = {};
  final List<Map<String, String>> writes = [];
  Map<String, String> get values => file != null && file!.existsSync()
      ? (jsonDecode(file!.readAsStringSync()) as Map).cast<String, String>()
      : Map.of(_values);
  Future<void> _save(Map<String, String> data) async {
    _values
      ..clear()
      ..addAll(data);
    if (file != null) {
      final next = File('${file!.path}.next');
      next.writeAsStringSync(jsonEncode(data), flush: true);
      next.renameSync(file!.path);
    }
    writes.add(Map.of(data));
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final data = values;
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
    await _save(data);
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == failingDeleteKey) throw StateError('Synthetic delete failure');
    final data = values;
    data.remove(key);
    await _save(data);
  }
}
