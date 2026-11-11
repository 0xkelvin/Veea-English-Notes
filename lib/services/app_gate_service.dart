import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/native_gate_status.dart';
import '../models/shortcut_setup.dart';
import '../models/universal_gate_status.dart';

/// Platform channel bridge for the App Gate ("Earn Screen Time" / "Word Toll") feature.
///
/// Communicates over `MethodChannel('app.veea.english/app_gate')` with iOS
/// (`FamilyControls` / `ManagedSettings` / URL schemes) and Android
/// (`VeeaGateAccessibilityService` / `PackageManager`).
class AppGateService {
  AppGateService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static const String channelName = 'app.veea.english/app_gate';

  final MethodChannel _channel;
  final StreamController<String> _gateTriggeredController =
      StreamController<String>.broadcast();

  String? _pendingTargetApp;
  final Map<String, String> shortcutAppNames = {};

  Future<UniversalGateStatus> getUniversalGateStatus() async {
    final value = await _channel.invokeMapMethod<String, dynamic>(
      'getUniversalGateStatus',
    );
    final status = UniversalGateStatus.fromMap(value);
    final pendingTarget = value?['pendingTarget'];
    final pendingName = value?['pendingAppName'];
    if (pendingTarget is String && pendingName is String) {
      shortcutAppNames[pendingTarget] = pendingName;
    }
    for (final app in status.apps) {
      shortcutAppNames[app.id] = app.name;
    }
    return status;
  }

  Future<void> setUniversalGateEnabled(bool enabled) => _channel
      .invokeMethod<void>('setUniversalGateEnabled', {'enabled': enabled});

  Future<void> cancelUniversalGate(String app) =>
      _channel.invokeMethod<void>('cancelUniversalGate', {'targetApp': app});

  /// Emits the target app name / identifier whenever the native OS intercepts
  /// a locked app launch (`onGateTriggered`).
  Stream<String> get onGateTriggered => _gateTriggeredController.stream;

  /// Returns and clears any buffered gate target received before a listener
  /// attached (e.g. during cold start).
  String? consumePendingTargetApp() {
    final pending = _pendingTargetApp;
    _pendingTargetApp = null;
    return pending;
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onGateTriggered') {
      final args = call.arguments;
      String? targetApp;
      if (args is Map) {
        targetApp = args['targetApp']?.toString();
        final name = args['appName'];
        if (targetApp != null && name is String) {
          shortcutAppNames[targetApp] = name;
        }
      } else if (args is String) {
        targetApp = args;
      }
      if (targetApp != null && targetApp.trim().startsWith('native:')) {
        final cleaned = targetApp.trim();
        if (_gateTriggeredController.hasListener) {
          _gateTriggeredController.add(cleaned);
        } else {
          _pendingTargetApp = cleaned;
        }
      }
      return true;
    }
    return null;
  }

  /// Simulates or triggers a gate interception in Dart (also used by tests).
  void triggerGate(String targetApp) {
    if (_gateTriggeredController.isClosed) return;
    if (_gateTriggeredController.hasListener) {
      _gateTriggeredController.add(targetApp);
    } else {
      _pendingTargetApp = targetApp;
    }
  }

  /// Polls the native host for any pending cold-start gate target that was
  /// received before the Flutter engine finished initializing.
  Future<String?> consumeNativePendingGate() async {
    final buffered = consumePendingTargetApp();
    if (buffered != null && buffered.isNotEmpty) return buffered;
    try {
      final nativePending = await _channel.invokeMethod<String>(
        'consumePendingGate',
        <String, dynamic>{},
      );
      if (nativePending != null && nativePending.trim().startsWith('native:')) {
        return nativePending.trim();
      }
    } on MissingPluginException {
      // No native host in unit tests.
    } on PlatformException catch (error) {
      debugPrint('AppGate consumePendingGate failed: $error');
    }
    return null;
  }

  /// Requests OS-level permissions (`FamilyControls` on iOS, Accessibility /
  /// Usage Access / Overlay on Android).
  Future<bool> requestPermissions() async {
    try {
      final granted = await _channel.invokeMethod<bool>(
        'requestPermissions',
        <String, dynamic>{},
      );
      return granted ?? true;
    } on MissingPluginException {
      return true;
    } on PlatformException catch (error) {
      debugPrint('AppGate requestPermissions failed: $error');
      return false;
    }
  }

  /// Opens the native app selector (`FamilyActivityPicker` on iOS) and returns
  /// the selected app identifiers/names, or `null` if unavailable/cancelled.
  Future<List<String>?> pickAppsToGate() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>(
        'pickAppsToGate',
        <String, dynamic>{},
      );
      if (result == null) return null;
      return result.map((e) => e.toString()).toList(growable: false);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('AppGate pickAppsToGate failed: $error');
      return null;
    }
  }

  /// Queries launchable user apps installed on the device (`getInstalledApps`).
  Future<List<String>> getInstalledApps() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>(
        'getInstalledApps',
        <String, dynamic>{},
      );
      if (result == null) return const [];
      return result
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    } on MissingPluginException {
      return const [];
    } on PlatformException catch (error) {
      debugPrint('AppGate getInstalledApps failed: $error');
      return const [];
    }
  }

  /// Enables or disables active OS shields / accessibility interception.
  Future<void> setGateEnabled({
    required bool enabled,
    required int passMinutes,
    List<String> gatedApps = const [],
  }) async {
    try {
      await _channel.invokeMethod<void>('setGateEnabled', <String, dynamic>{
        // Retire any persisted pre-launch Shortcut/accessibility configuration.
        'enabled': false,
        'passMinutes': 15,
        'gatedApps': const <String>[],
      });
    } on MissingPluginException {
      // No-op when running without native host.
    } on PlatformException catch (error) {
      debugPrint('AppGate setGateEnabled failed: $error');
    }
  }

  Future<NativeGateStatus> getScreenTimeStatus() async {
    try {
      final raw = await _channel.invokeMapMethod<dynamic, dynamic>(
        'getScreenTimeStatus',
      );
      return NativeGateStatus.fromMap(raw);
    } on MissingPluginException {
      return const NativeGateStatus();
    }
  }

  Future<NativeGateStatus> requestScreenTimeAuthorization() async {
    final raw = await _channel.invokeMapMethod<dynamic, dynamic>(
      'requestScreenTimeAuthorization',
    );
    return NativeGateStatus.fromMap(raw);
  }

  Future<bool> chooseScreenTimeApplications() async =>
      await _channel.invokeMethod<bool>('chooseScreenTimeApplications') ??
      false;

  Future<NativeGateStatus> setScreenTimeEnabled(
    bool enabled, {
    required int minutes,
  }) async {
    final raw = await _channel.invokeMapMethod<dynamic, dynamic>(
      'setScreenTimeEnabled',
      {'enabled': enabled, 'passMinutes': minutes},
    );
    return NativeGateStatus.fromMap(raw);
  }

  Future<NativeGateStatus> setScreenTimeDuration(int minutes) async {
    final raw = await _channel.invokeMapMethod<dynamic, dynamic>(
      'setScreenTimeDuration',
      {'passMinutes': minutes},
    );
    return NativeGateStatus.fromMap(raw);
  }

  Future<String?> manageScreenTimeApplications() =>
      _channel.invokeMethod<String>('manageScreenTimeApplications');

  Future<NativeGateStatus> setScreenTimeApplicationLocked(
    String target,
    bool enabled,
  ) async => NativeGateStatus.fromMap(
    await _channel.invokeMapMethod<dynamic, dynamic>(
      'setScreenTimeApplicationLocked',
      {'targetApp': target, 'enabled': enabled},
    ),
  );

  Future<NativeGateStatus> setScreenTimeApplicationDuration(
    String target,
    int? minutes,
  ) async => NativeGateStatus.fromMap(
    await _channel.invokeMapMethod<dynamic, dynamic>(
      'setScreenTimeApplicationDuration',
      {'targetApp': target, 'passMinutes': minutes},
    ),
  );

  Future<NativeGateStatus> removeScreenTimeApplication(String target) async =>
      NativeGateStatus.fromMap(
        await _channel.invokeMapMethod<dynamic, dynamic>(
          'removeScreenTimeApplication',
          {'targetApp': target},
        ),
      );

  Future<ShortcutSetupStatus> getShortcutSetupStatus() async =>
      ShortcutSetupStatus.fromMap(
        await _channel.invokeMapMethod<dynamic, dynamic>(
          'getShortcutSetupStatus',
        ),
      );

  Future<void> beginShortcutSetupTest(String app) =>
      _channel.invokeMethod<void>('beginShortcutSetupTest', {'targetApp': app});

  /// Lifts the shield/overlay for [targetApp] for [durationMinutes] and
  /// schedules automatic re-lock.
  Future<NativeGateStatus?> grantPass({
    required String targetApp,
    required int durationMinutes,
  }) async {
    try {
      final result = await _channel.invokeMethod<dynamic>(
        'grantPass',
        <String, dynamic>{
          'targetApp': targetApp,
          'durationMinutes': durationMinutes,
        },
      );
      return result is Map ? NativeGateStatus.fromMap(result) : null;
    } on MissingPluginException {
      if (targetApp.startsWith('native:')) {
        throw PlatformException(
          code: 'SCREEN_TIME_UNAVAILABLE',
          message: 'Screen Time protection is not available in this build.',
        );
      }
      // No-op when running without native host.
      return null;
    }
  }

  /// Immediately revokes an active unlock pass for [targetApp] and re-applies
  /// the lock.
  Future<void> revokePass(String targetApp) async {
    try {
      await _channel.invokeMethod<void>('revokePass', <String, dynamic>{
        'targetApp': targetApp,
      });
    } on MissingPluginException {
      // No-op when running without native host.
    }
  }

  /// Launches the unlocked [targetApp] directly on the device via its native
  /// URL scheme (iOS) or package launch intent (Android).
  Future<bool> launchApp(String targetApp) async {
    try {
      final launched = await _channel.invokeMethod<bool>(
        'launchApp',
        <String, dynamic>{'targetApp': targetApp},
      );
      return launched ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      debugPrint('AppGate launchApp failed: $error');
      return false;
    }
  }

  void dispose() {
    _gateTriggeredController.close();
  }
}
