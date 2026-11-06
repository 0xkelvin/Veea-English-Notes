import 'package:flutter/foundation.dart';

import '../data/vocabulary_repository.dart';
import '../models/gate_config.dart';
import '../models/vocabulary_word.dart';
import '../services/app_gate_service.dart';

/// Presentation state for App Gate ("Word Toll") settings, guardrails, and
/// challenge completion.
class AppGateProvider extends ChangeNotifier {
  AppGateProvider({
    required VocabularyRepository repository,
    AppGateService? service,
    DateTime Function()? now,
  }) : _repository = repository,
       _service = service ?? AppGateService(),
       _now = now ?? DateTime.now;

  final VocabularyRepository _repository;
  final AppGateService _service;
  final DateTime Function() _now;

  GateConfig _config = const GateConfig();
  List<GateLog> _logs = const [];
  List<String> _installedApps = const [];
  bool _initialized = false;
  String? _lastError;
  bool _isDisposed = false;

  AppGateService get service => _service;
  GateConfig get config => _config;
  List<GateLog> get logs => _logs;

  /// Apps detected as actually installed on the user's device.
  List<String> get installedApps => _installedApps;

  bool get isInitialized => _initialized;
  String? get lastError => _lastError;

  /// Guardrail 2.1: Requires at least 3 non-deleted words in local SQLite
  /// before the user can enable App Gate in Settings.
  bool canEnable(int totalWords) => totalWords >= GateConfig.minRequiredWords;

  Future<void> init() async {
    try {
      _config = await _repository.getGateConfig();
      _logs = await _repository.recentGateLogs();
      _installedApps = await _service.getInstalledApps();
      _initialized = true;
      if (_config.enabled) {
        await _service.setGateEnabled(
          enabled: true,
          passMinutes: _config.passDurationMinutes,
          gatedApps: _config.gatedApps,
        );
      }
    } catch (error, stack) {
      debugPrint('AppGateProvider init failed: $error\n$stack');
    }
    notifyListeners();
  }

  /// Toggles App Gate on or off, enforcing the 3-word minimum guardrail.
  Future<bool> setEnabled(bool enabled, {required int totalWords}) async {
    if (enabled && !canEnable(totalWords)) {
      _lastError =
          'Add at least ${GateConfig.minRequiredWords} words to your notebook before enabling App Gate.';
      notifyListeners();
      return false;
    }

    if (enabled) {
      final permitted = await _service.requestPermissions();
      if (!permitted) {
        _lastError = 'System permissions are required to intercept gated apps.';
        notifyListeners();
        return false;
      }
    }

    _lastError = null;
    if (_installedApps.isEmpty) {
      _installedApps = await _service.getInstalledApps();
    }
    final defaultApps = _config.gatedApps.isEmpty && enabled
        ? (_installedApps.isNotEmpty
              ? _installedApps.take(4).toList(growable: false)
              : const ['Instagram', 'X', 'YouTube', 'TikTok'])
        : _config.gatedApps;
    final updated = _config.copyWith(enabled: enabled, gatedApps: defaultApps);
    await _save(updated);
    await _service.setGateEnabled(
      enabled: updated.enabled,
      passMinutes: updated.passDurationMinutes,
      gatedApps: updated.gatedApps,
    );
    return true;
  }

  Future<void> setPassDurationMinutes(int minutes) async {
    final updated = _config.copyWith(passDurationMinutes: minutes);
    await _save(updated);
    if (updated.enabled) {
      await _service.setGateEnabled(
        enabled: true,
        passMinutes: updated.passDurationMinutes,
        gatedApps: updated.gatedApps,
      );
    }
  }

  Future<void> setRequireDailyCapture(bool value) async {
    final updated = _config.copyWith(requireDailyCapture: value);
    await _save(updated);
  }

  Future<void> toggleGatedApp(String appName) async {
    final current = List<String>.from(_config.gatedApps);
    if (current.contains(appName)) {
      current.remove(appName);
    } else {
      current.add(appName);
    }
    await setGatedApps(current);
  }

  Future<void> setGatedApps(List<String> apps) async {
    final cleaned = apps
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final updated = _config.copyWith(gatedApps: cleaned);
    await _save(updated);
    if (updated.enabled) {
      await _service.setGateEnabled(
        enabled: true,
        passMinutes: updated.passDurationMinutes,
        gatedApps: updated.gatedApps,
      );
    }
  }

  /// Invokes the native OS app picker and merges any returned apps into config.
  Future<List<String>?> pickAppsFromSystem() async {
    final picked = await _service.pickAppsToGate();
    if (picked != null && picked.isNotEmpty) {
      final merged = {..._config.gatedApps, ...picked}.toList(growable: false);
      await setGatedApps(merged);
    }
    return picked;
  }

  /// Returns the list of apps actually installed on the device (plus any
  /// custom apps already configured by the user). Falls back to the built-in
  /// catalog only in test/desktop environments where native scanning returns
  /// empty.
  Future<List<String>> loadAvailableApps() async {
    final installed = await _service.getInstalledApps();
    if (installed.isNotEmpty) {
      _installedApps = installed;
      notifyListeners();
      return <String>{...installed, ..._config.gatedApps}.toList(
        growable: false,
      );
    }
    return <String>{
      ...GateConfig.selectableAppsCatalog,
      ..._config.gatedApps,
    }.toList(growable: false);
  }

  /// Launches the unlocked [targetApp] directly on the user's phone.
  Future<bool> launchTargetApp(String targetApp) {
    return _service.launchApp(targetApp);
  }

  /// Selects the next word for an App Gate challenge following the 4-tier
  /// Smart Review Queue priority order.
  Future<VocabularyWord?> selectGateWord() {
    return _repository.selectGateWord(now: _now());
  }

  /// Records a completed gate challenge, updates SRS fields in SQLite, and
  /// grants the native OS unlock pass for [targetApp].
  Future<VocabularyWord?> completeGateChallenge({
    required String wordId,
    required String targetApp,
    required int attempts,
  }) async {
    final updatedWord = await _repository.recordGateCompletion(
      wordId: wordId,
      targetApp: targetApp,
      attempts: attempts,
      now: _now(),
    );
    _logs = await _repository.recentGateLogs();
    await _service.grantPass(
      targetApp: targetApp,
      durationMinutes: _config.passDurationMinutes,
    );
    notifyListeners();
    return updatedWord;
  }

  void consumeError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }

  Future<void> _save(GateConfig next) async {
    _config = next;
    await _repository.saveGateConfig(next);
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_isDisposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _service.dispose();
    super.dispose();
  }
}
