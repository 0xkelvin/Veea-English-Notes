import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/vocabulary_repository.dart';
import '../models/gate_config.dart';
import '../models/gate_word_queue.dart';
import '../models/native_gate_status.dart';
import '../models/protection_duration.dart';
import '../models/vocabulary_word.dart';
import '../services/app_gate_service.dart';

/// Presentation state for App Gate ("Earn Screen Time" / "Word Toll") settings,
/// phone app scanning, multi-word progress, and unlock passes.
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
  bool _scanningApps = false;
  bool _initialized = false;
  String? _lastError;
  bool _isDisposed = false;
  NativeGateStatus _nativeStatus = const NativeGateStatus();
  bool _nativeBusy = false;
  String? _nativeError;
  List<VocabularyWord> _notebook = const [];
  Map<String, int> _wordTurns = {};
  final Set<String> _submittingApps = {};
  final Map<String, GatePendingAnswer> _pendingAnswers = {};
  DateTime get now => _now();

  List<VocabularyWord> get notebookWords => List.unmodifiable(_notebook);
  List<VocabularyWord> get practiceWords {
    final ids = _config.practiceWordIds;
    if (ids == null) return List.unmodifiable(_notebook);
    final selected = ids.toSet();
    return _notebook
        .where((word) => selected.contains(word.id))
        .toList(growable: false);
  }

  int get practiceWordCount => practiceWords.length;
  int get requiredWords => _config.wordsPerUnlock.clamp(
    1,
    practiceWordCount == 0 ? 1 : practiceWordCount,
  );
  String? _poolNotice;
  String? get poolNotice => _poolNotice;
  // Keep learning progress per app while native callbacks remain per opening.
  static String _stateKey(String app) {
    final key = app.trim().toLowerCase();
    return key.startsWith('shortcut:name:')
        ? key.replaceFirst(RegExp(r':request:[0-9]{1,10}-[0-9]{1,10}$'), '')
        : key;
  }

  GatePendingAnswer? pendingAnswerForApp(String app) =>
      _pendingAnswers[_stateKey(app)];
  Set<String> solvedWordIdsForApp(String app) => Set.unmodifiable({
    ...?_progressByApp[_stateKey(app)],
    if (pendingAnswerForApp(app) case final pending?) pending.wordId,
  });
  VocabularyWord? cachedGateWord(
    String targetApp, {
    bool preview = false,
    Set<String> excludeIds = const {},
  }) {
    final pending = preview ? null : pendingAnswerForApp(targetApp);
    if (pending != null && progressForApp(targetApp) >= requiredWords) {
      for (final word in practiceWords) {
        if (word.id == pending.wordId) return word;
      }
    }
    return GateWordQueue.selectInRotation(
      practiceWords,
      now: _now(),
      turns: _wordTurns,
      excludeIds: {
        ...excludeIds,
        if (!preview) ...solvedWordIdsForApp(targetApp),
      },
    );
  }

  Future<void> prepareChallenge() async {
    _notebook = await _repository.exportAll();
    _wordTurns = await _repository.gateWordTurns();
    await _repository.pruneGateRoundProgress(
      practiceWords.map((word) => word.id).toSet(),
    );
    if (practiceWordCount > 0 && _config.wordsPerUnlock > practiceWordCount) {
      await _save(_config.copyWith(wordsPerUnlock: practiceWordCount));
      _poolNotice =
          'Words per unlock adjusted to $practiceWordCount to match your available practice words.';
    }
    _progressByApp
      ..clear()
      ..addAll(await _repository.gateRoundProgress());
    _pendingAnswers
      ..clear()
      ..addAll(await _repository.pendingGateAnswers());
    notifyListeners();
  }

  NativeGateStatus get nativeStatus => _nativeStatus;
  bool get nativeBusy => _nativeBusy;
  String? get nativeError => _nativeError;

  String displayNameForApp(String target) {
    for (final app in _nativeStatus.applications) {
      if (app.id == target) return app.label;
    }
    return _service.shortcutAppNames[target] ??
        (target.startsWith('native:') || target.startsWith('shortcut:')
            ? 'Protected app'
            : target);
  }

  Future<void> refreshNativeScreenTime() async {
    try {
      _nativeStatus = await _service.getScreenTimeStatus();
      _nativeError = null;
      for (final application in _nativeStatus.applications) {
        if (_nativeStatus.enabled &&
            application.unlockedUntil?.isAfter(_now()) == true) {
          final key = application.id.toLowerCase();
          if (_progressByApp.containsKey(key) ||
              _pendingAnswers.containsKey(key)) {
            try {
              await _repository.clearGateRoundProgress(key);
              _progressByApp.remove(key);
              _pendingAnswers.remove(key);
            } catch (error) {
              debugPrint('Could not clear an already earned round: $error');
            }
          }
        }
      }
    } on PlatformException catch (error) {
      _nativeError = error.message ?? 'Could not read Screen Time protection.';
    }
    notifyListeners();
  }

  Future<bool> _nativeOperation(Future<void> Function() operation) async {
    if (_nativeBusy) return false;
    _nativeBusy = true;
    _nativeError = null;
    notifyListeners();
    try {
      await operation();
      return true;
    } on PlatformException catch (error) {
      _nativeError =
          error.message ??
          'Screen Time could not be updated. Please try again.';
      return false;
    } on MissingPluginException {
      _nativeError = 'Screen Time is not available in this build.';
      return false;
    } catch (error, stack) {
      debugPrint('Screen Time operation failed: $error\n$stack');
      _nativeError = 'Could not save protection settings. Please try again.';
      return false;
    } finally {
      _nativeBusy = false;
      notifyListeners();
    }
  }

  Future<bool> enableNativeProtection({required int totalWords}) async {
    if (!canEnable(totalWords)) {
      _nativeError = totalWords < GateConfig.minRequiredWords
          ? 'Save at least ${GateConfig.minRequiredWords} words before enabling protection.'
          : 'Choose at least one practice word before enabling protection.';
      notifyListeners();
      return false;
    }
    final completed = await _nativeOperation(() async {
      _nativeStatus = await _service.requestScreenTimeAuthorization();
      if (!_nativeStatus.authorized) {
        throw PlatformException(
          code: 'SCREEN_TIME_DENIED',
          message: 'Screen Time access was not allowed.',
        );
      }
      if (_nativeStatus.applications.isEmpty &&
          !await _service.chooseScreenTimeApplications()) {
        return;
      }
      _nativeStatus = await _service.getScreenTimeStatus();
      if (_nativeStatus.applications.isEmpty) {
        throw PlatformException(
          code: 'NO_APPS',
          message: 'Choose at least one app to protect.',
        );
      }
      _nativeStatus = await _service.setScreenTimeEnabled(
        true,
        minutes: _nativeStatus.passMinutes,
      );
    });
    return completed && _nativeStatus.enabled;
  }

  Future<bool> disableNativeProtection() => _nativeOperation(() async {
    _nativeStatus = await _service.setScreenTimeEnabled(
      false,
      minutes: _nativeStatus.passMinutes,
    );
  });

  Future<bool> chooseNativeApplications() => _nativeOperation(() async {
    if (!_nativeStatus.authorized) {
      _nativeStatus = await _service.requestScreenTimeAuthorization();
      if (!_nativeStatus.authorized) {
        throw PlatformException(
          code: 'SCREEN_TIME_DENIED',
          message: 'Screen Time access was not allowed.',
        );
      }
    }
    await _service.chooseScreenTimeApplications();
    _nativeStatus = await _service.getScreenTimeStatus();
  });

  Future<bool> setNativeDuration(int minutes) => _nativeOperation(() async {
    if (!ProtectionDuration.isValid(minutes)) {
      throw PlatformException(
        code: 'INVALID_DURATION',
        message: 'Choose from 5 minutes to 24 hours.',
      );
    }
    _nativeStatus = await _service.setScreenTimeDuration(minutes);
  });

  Future<String?> manageNativeApplications() async {
    String? target;
    await _nativeOperation(() async {
      target = await _service.manageScreenTimeApplications();
    });
    return target;
  }

  Future<bool> setNativeApplicationDuration(String target, int? minutes) =>
      _nativeOperation(() async {
        if (minutes != null && !ProtectionDuration.isValid(minutes)) {
          throw PlatformException(
            code: 'INVALID_DURATION',
            message: 'Choose from 5 minutes to 24 hours.',
          );
        }
        _nativeStatus = await _service.setScreenTimeApplicationDuration(
          target,
          minutes,
        );
      });

  Future<bool> removeNativeApplication(String target) => _nativeOperation(
    () async {
      _nativeStatus = await _service.removeScreenTimeApplication(target);
      final key = _stateKey(target);
      _progressByApp.remove(key);
      _pendingAnswers.remove(key);
      // iOS has already removed the shield. History cleanup cannot undo that
      // success or require the user to repeat a destructive-looking action.
      try {
        await _repository.clearGateRoundProgress(key);
      } catch (error) {
        debugPrint('App removed but round cleanup could not be saved: $error');
      }
    },
  );

  /// Saved progress (`completedCount`) per app when `wordsPerUnlock > 1`, so
  /// leaving mid-challenge preserves progress (LockFeed behavior).
  final Map<String, Set<String>> _progressByApp = {};

  /// Active pass expiry timestamps (`DateTime`) per normalized app name.
  final Map<String, DateTime> _unlockedUntilByApp = {};

  AppGateService get service => _service;
  GateConfig get config => _config;
  List<GateLog> get logs => _logs;

  /// Apps detected as actually installed on the user's phone.
  List<String> get installedApps => _installedApps;
  bool get isScanningApps => _scanningApps;

  bool get isInitialized => _initialized;
  String? get lastError => _lastError;

  /// Guardrail 2.1: Requires at least 3 non-deleted words in local SQLite
  /// before the user can enable App Gate in Settings.
  bool canEnable(int totalWords) =>
      totalWords >= GateConfig.minRequiredWords && practiceWordCount > 0;

  /// Number of words already solved in the current unlock round for [app].
  int progressForApp(String app) => solvedWordIdsForApp(app).length;

  /// Records 1 solved word towards unlocking [app] without granting the final pass yet.
  Future<VocabularyWord?> recordStepCompletion({
    required String wordId,
    required String targetApp,
    required int attempts,
  }) async {
    final key = _stateKey(targetApp);
    await _validateAnswerWord(wordId, targetApp);
    final updatedWord = await _repository.recordGateCompletion(
      wordId: wordId,
      targetApp: key,
      attempts: attempts,
      now: _now(),
      completesRound: false,
    );
    if (updatedWord == null) {
      throw PlatformException(
        code: 'WORD_REMOVED',
        message:
            'This word is no longer in your notebook. Choose another word.',
      );
    }
    (_progressByApp[key] ??= {}).add(wordId);
    _replaceCachedWord(updatedWord);
    _wordTurns = await _repository.gateWordTurns();
    _logs = await _repository.recentGateLogs();
    notifyListeners();
    return updatedWord;
  }

  /// Active pass expiration for [app], or `null` if locked/expired.
  DateTime? unlockedUntilFor(String app) {
    if (app.startsWith('native:')) {
      if (!_nativeStatus.enabled) return null;
      for (final application in _nativeStatus.applications) {
        if (application.id.toLowerCase() == app.toLowerCase()) {
          final expiry = application.unlockedUntil;
          return expiry != null && expiry.isAfter(_now()) ? expiry : null;
        }
      }
      return null;
    }
    final key = app.trim().toLowerCase();
    final expiry = _unlockedUntilByApp[key];
    if (expiry == null) return null;
    if (!expiry.isAfter(_now())) {
      _unlockedUntilByApp.remove(key);
      return null;
    }
    return expiry;
  }

  Future<void> init() async {
    try {
      _config = await _repository.getGateConfig();
      if (_config.enabled || _config.passDurationMinutes <= 0) {
        _config = _config.copyWith(enabled: false, passDurationMinutes: 15);
        await _repository.saveGateConfig(_config);
      }
      _logs = await _repository.recentGateLogs();
      await prepareChallenge();
      _installedApps = const [];
      _initialized = true;
      await refreshNativeScreenTime();
      await _service.setGateEnabled(
        enabled: _config.enabled,
        passMinutes: _config.passDurationMinutes,
        gatedApps: _config.gatedApps,
      );
    } catch (error, stack) {
      debugPrint('AppGateProvider init failed: $error\n$stack');
    }
    notifyListeners();
  }

  /// Actively scans the user's phone for installed apps and updates [installedApps].
  Future<List<String>> scanInstalledApps() async {
    _scanningApps = true;
    notifyListeners();
    try {
      final detected = await _service.getInstalledApps();
      _installedApps = detected;
      return detected;
    } finally {
      _scanningApps = false;
      notifyListeners();
    }
  }

  /// Toggles App Gate on or off, enforcing the 3-word minimum guardrail.
  Future<bool> setEnabled(
    bool enabled, {
    required int totalWords,
    bool useDefaultApps = true,
  }) async {
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
      _installedApps = const [];
    }
    final defaultApps = useDefaultApps && _config.gatedApps.isEmpty && enabled
        ? (_installedApps.isNotEmpty
              ? _installedApps.take(4).toList(growable: false)
              : const ['Facebook', 'Instagram', 'TikTok', 'YouTube'])
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
    await _service.setGateEnabled(
      enabled: updated.enabled,
      passMinutes: updated.passDurationMinutes,
      gatedApps: updated.gatedApps,
    );
  }

  Future<void> setWordsPerUnlock(int count) async {
    await prepareChallenge();
    if (practiceWordCount == 0) {
      throw PlatformException(
        code: 'EMPTY_PRACTICE_POOL',
        message: 'Choose your practice words first.',
      );
    }
    final clamped = count.clamp(1, practiceWordCount);
    if (clamped == _config.wordsPerUnlock) return;
    await _settlePendingAnswers();
    await _save(_config.copyWith(wordsPerUnlock: clamped));
    _poolNotice = null;
    await prepareChallenge();
  }

  Future<void> setPracticeWords(List<String>? ids) async {
    _notebook = await _repository.exportAll();
    final available = _notebook.map((word) => word.id).toSet();
    final selected = ids?.where(available.contains).toSet().toList();
    if (selected != null && selected.isEmpty) {
      throw PlatformException(
        code: 'EMPTY_PRACTICE_POOL',
        message: 'Choose at least one word, or use all saved words.',
      );
    }
    await _settlePendingAnswers(selected?.toSet());
    final maximum = selected?.length ?? available.length;
    final count = _config.wordsPerUnlock.clamp(1, maximum == 0 ? 1 : maximum);
    _poolNotice = count != _config.wordsPerUnlock
        ? 'Words per unlock adjusted to $count to match your practice pool.'
        : null;
    await _save(
      _config.copyWith(
        practiceWordIds: selected,
        useAllWords: ids == null,
        wordsPerUnlock: count,
      ),
    );
    await prepareChallenge();
  }

  Future<void> _settlePendingAnswers([Set<String>? retainedIds]) async {
    for (final entry in _pendingAnswers.entries.toList()) {
      if (retainedIds != null && !retainedIds.contains(entry.value.wordId)) {
        continue;
      }
      await _repository.recordGateCompletion(
        wordId: entry.value.wordId,
        targetApp: entry.key,
        attempts: entry.value.attempts,
        now: _now(),
        completesRound: false,
      );
    }
  }

  Future<void> setAutoPronounce(bool value) =>
      _save(_config.copyWith(autoPronounce: value));
  Future<void> setDailyWordGoal(bool value) =>
      _save(_config.copyWith(dailyWordGoal: value));

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
    await _service.setGateEnabled(
      enabled: updated.enabled,
      passMinutes: updated.passDurationMinutes,
      gatedApps: updated.gatedApps,
    );
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
      return <String>{
        ...installed,
        ..._config.gatedApps,
      }.toList(growable: false);
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
  /// Cycles through the selected pool, using learning priority to break ties.
  Future<VocabularyWord?> selectGateWord({
    String? targetApp,
    Set<String> excludeIds = const {},
  }) async {
    _notebook = await _repository.exportAll();
    _wordTurns = await _repository.gateWordTurns();
    return GateWordQueue.selectInRotation(
      practiceWords,
      now: _now(),
      turns: _wordTurns,
      excludeIds: {
        ...excludeIds,
        if (targetApp != null) ...solvedWordIdsForApp(targetApp),
      },
    );
  }

  /// Records a completed gate challenge, updates SRS fields in SQLite, and
  /// grants the native OS unlock pass for [targetApp].
  Future<VocabularyWord?> completeGateChallenge({
    required String wordId,
    required String targetApp,
    required int attempts,
  }) async {
    final key = _stateKey(targetApp);
    if (!_submittingApps.add(key)) {
      throw PlatformException(
        code: 'UNLOCK_BUSY',
        message: 'Your unlock is already being saved.',
      );
    }
    try {
      final roundAlreadyEarned = progressForApp(targetApp) >= requiredWords;
      var pending = pendingAnswerForApp(targetApp);
      final answerId = pending?.wordId ?? wordId;
      final answerAttempts = pending?.attempts ?? attempts;
      await _validateAnswerWord(
        answerId,
        targetApp,
        allowCompleted: roundAlreadyEarned,
      );
      if (!roundAlreadyEarned &&
          progressForApp(targetApp) + 1 < requiredWords) {
        throw PlatformException(
          code: 'ROUND_INCOMPLETE',
          message: 'Complete the remaining words before earning access.',
        );
      }
      final needsLearningCredit =
          !(_progressByApp[key]?.contains(answerId) ?? false);
      if (pending == null && needsLearningCredit) {
        pending = GatePendingAnswer(wordId: answerId, attempts: answerAttempts);
        await _repository.savePendingGateAnswer(key, pending);
        _pendingAnswers[key] = pending;
      }
      // Establish the native unlock first. A failed relock schedule must not be
      // recorded or presented as a successful earned pass.
      final nativeTarget = targetApp.startsWith('native:');
      final grantedStatus = await _service.grantPass(
        targetApp: targetApp,
        durationMinutes: nativeTarget
            ? _nativeStatus.durationFor(targetApp)
            : _config.passDurationMinutes,
      );
      if (nativeTarget) {
        if (grantedStatus != null) {
          _nativeStatus = grantedStatus;
        } else {
          await refreshNativeScreenTime();
        }
      } else if (_config.passDurationMinutes > 0) {
        _unlockedUntilByApp[key] = _now().add(
          Duration(minutes: _config.passDurationMinutes),
        );
      } else {
        _unlockedUntilByApp.remove(key);
      }
      // Once iOS has granted access, a history write failure must not tell the
      // user that the app is still locked or ask them to earn the same pass twice.
      VocabularyWord? updatedWord;
      _lastError = null;
      try {
        updatedWord = !needsLearningCredit
            ? await _repository.findById(answerId)
            : await _repository.recordGateCompletion(
                wordId: answerId,
                targetApp: key,
                attempts: answerAttempts,
                now: _now(),
              );
        if (updatedWord != null) _replaceCachedWord(updatedWord);
        _wordTurns = await _repository.gateWordTurns();
        _logs = await _repository.recentGateLogs();
      } catch (error) {
        debugPrint('Access earned but history could not be saved: $error');
        _lastError =
            'Access is unlocked, but your learning history could not be saved.';
      } finally {
        _progressByApp.remove(key);
        _pendingAnswers.remove(key);
        try {
          await _repository.clearGateRoundProgress(key);
        } catch (error) {
          debugPrint('Could not clear the consumed round: $error');
        }
      }

      notifyListeners();
      return updatedWord;
    } finally {
      _submittingApps.remove(key);
    }
  }

  Future<void> _validateAnswerWord(
    String wordId,
    String targetApp, {
    bool allowCompleted = false,
  }) async {
    final word = await _repository.findById(wordId);
    if (word == null || word.isDeleted) {
      throw PlatformException(
        code: 'WORD_REMOVED',
        message:
            'This word is no longer in your notebook. Choose another word.',
      );
    }
    if (!allowCompleted && solvedWordIdsForApp(targetApp).contains(wordId)) {
      throw PlatformException(
        code: 'WORD_ALREADY_SOLVED',
        message:
            'You already completed this word. Continue with the next word.',
      );
    }
    if (!practiceWords.any((candidate) => candidate.id == wordId)) {
      throw PlatformException(
        code: 'WORD_OUTSIDE_POOL',
        message:
            'This word is no longer in your practice pool. Continue with your selected words.',
      );
    }
  }

  void _replaceCachedWord(VocabularyWord word) {
    _notebook = [
      for (final previous in _notebook)
        if (previous.id == word.id) word else previous,
    ];
  }

  /// Immediately re-locks [targetApp] and revokes its active pass.
  Future<void> revokePass(String targetApp, {bool resetProgress = true}) async {
    final key = _stateKey(targetApp);
    await _service.revokePass(targetApp);
    if (resetProgress) await _repository.clearGateRoundProgress(key);
    _unlockedUntilByApp.remove(key);
    if (resetProgress) {
      _progressByApp.remove(key);
      _pendingAnswers.remove(key);
    }
    if (targetApp.startsWith('native:')) await refreshNativeScreenTime();
    notifyListeners();
  }

  void consumeError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }

  Future<void> _save(GateConfig next) async {
    await _repository.saveGateConfig(next);
    _config = next;
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
