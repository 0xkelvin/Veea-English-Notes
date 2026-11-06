import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform channel bridge for the App Gate ("Word Toll") feature.
///
/// Communicates over `MethodChannel('app.veea.english/app_gate')` with iOS
/// (`FamilyControls` / `ManagedSettings` / `DeviceActivity`) and Android
/// (`VeeaGateAccessibilityService` / `UsageStatsManager` / overlay).
class AppGateService {
  AppGateService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static const String channelName = 'app.veea.english/app_gate';

  final MethodChannel _channel;
  final StreamController<String> _gateTriggeredController =
      StreamController<String>.broadcast();

  /// Emits the target app name / identifier whenever the native OS intercepts
  /// a locked app launch (`onGateTriggered`).
  Stream<String> get onGateTriggered => _gateTriggeredController.stream;

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onGateTriggered') {
      final args = call.arguments;
      String? targetApp;
      if (args is Map) {
        targetApp = args['targetApp']?.toString();
      } else if (args is String) {
        targetApp = args;
      }
      if (targetApp != null && targetApp.trim().isNotEmpty) {
        _gateTriggeredController.add(targetApp.trim());
      }
      return true;
    }
    return null;
  }

  /// Simulates or triggers a gate interception in Dart (also used by tests).
  void triggerGate(String targetApp) {
    if (!_gateTriggeredController.isClosed) {
      _gateTriggeredController.add(targetApp);
    }
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
      // Graceful fallback in desktop/test environments where no native host is
      // attached.
      return true;
    } on PlatformException catch (error) {
      debugPrint('AppGate requestPermissions failed: $error');
      return false;
    }
  }

  /// Opens the native app selector (`FamilyActivityPicker` on iOS or installed
  /// apps sheet on Android) and returns the selected app identifiers/names.
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

  /// Queries launchable user apps from the native OS (`getInstalledApps`),
  /// returning an empty list when running on platforms without package queries.
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
        'enabled': enabled,
        'passMinutes': passMinutes,
        'gatedApps': gatedApps,
      });
    } on MissingPluginException {
      // No-op when running without native host.
    } on PlatformException catch (error) {
      debugPrint('AppGate setGateEnabled failed: $error');
    }
  }

  /// Lifts the shield/overlay for [targetApp] for [durationMinutes] and
  /// schedules automatic re-lock.
  Future<void> grantPass({
    required String targetApp,
    required int durationMinutes,
  }) async {
    try {
      await _channel.invokeMethod<void>('grantPass', <String, dynamic>{
        'targetApp': targetApp,
        'durationMinutes': durationMinutes,
      });
    } on MissingPluginException {
      // No-op when running without native host.
    } on PlatformException catch (error) {
      debugPrint('AppGate grantPass failed: $error');
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
