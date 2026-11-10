import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/shortcut_setup.dart';
import 'app_gate_provider.dart';

typedef OpenShortcutLink = Future<bool> Function(Uri url);

/// The operating system owns import and activation. Opening a link or returning
/// from Shortcuts is never treated as proof that an automation was enabled.
class ShortcutSetupController extends ChangeNotifier {
  ShortcutSetupController({
    required this.gate,
    required this.template,
    OpenShortcutLink? openLink,
  }) : _openLink = openLink ?? _launch;

  final AppGateProvider gate;
  final ShortcutTemplate template;
  final OpenShortcutLink _openLink;
  bool busy = false;
  bool openedInstaller = false;
  bool testing = false;
  bool tested = false;
  String? error;
  bool _disposed = false;
  bool _reviewingSetup = false;

  static Future<bool> _launch(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<bool> _operation(Future<void> Function() work) async {
    if (busy) return false;
    busy = true;
    error = null;
    _notify();
    try {
      await work();
      return true;
    } catch (_) {
      error ??= 'Could not finish this step. Please try again.';
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> refresh() async {
    try {
      final status = await gate.service.getShortcutSetupStatus();
      tested =
          (!_reviewingSetup || testing) &&
          gate.config.enabled &&
          gate.config.passDurationMinutes == 0 &&
          !gate.nativeStatus.enabled &&
          gate.config.gatedApps.any(
            (app) => app.toLowerCase() == template.app.toLowerCase(),
          ) &&
          status.wasTested(template.app);
      if (tested) {
        testing = false;
        _reviewingSetup = false;
      }
      _notify();
    } catch (_) {
      // A failed status read never promotes an app to Tested.
    }
  }

  void reviewSetup() {
    _reviewingSetup = true;
    tested = false;
    testing = false;
    error = null;
    _notify();
  }

  Future<bool> addShortcut({required int totalWords}) => _operation(() async {
    final status = await gate.service.getShortcutSetupStatus();
    if (!status.supportsImport) {
      error = 'Ready-made app automations need iOS 27 or later.';
      throw StateError('unsupported');
    }
    await _prepare(totalWords);
    if (!await _openLink(template.installUrl)) {
      error =
          'Could not open Apple Shortcuts. Check your connection and try again.';
      throw StateError('installer');
    }
    openedInstaller = true;
    tested = false;
    testing = true;
  });

  Future<bool> openAutomation() => _operation(() async {
    if (!await _openLink(template.editorUrl)) {
      error = 'Open Shortcuts and find “${template.name}”.';
      throw StateError('editor');
    }
  });

  Future<void> _prepare(int totalWords) async {
    if (!gate.canEnable(totalWords)) {
      error = 'Save at least 3 words and choose your practice words first.';
      throw StateError('words');
    }
    // Configure the exact chosen app before enabling; do not add the provider's
    // default apps or reset the user's other selected apps or learning rules.
    if (gate.nativeStatus.enabled && !await gate.disableNativeProtection()) {
      error = gate.nativeError ?? 'Could not switch from timed access.';
      throw StateError('native');
    }
    await gate.setGatedApps({...gate.config.gatedApps, template.app}.toList());
    await gate.setPassDurationMinutes(0);
    if (!await gate.setEnabled(true, totalWords: totalWords)) {
      error = gate.lastError ?? 'Could not turn on protection.';
      throw StateError('enable');
    }
    // An earned return token from an earlier trial must not hide this test.
    await gate.revokePass(template.app, resetProgress: false);
    await gate.service.beginShortcutSetupTest(template.app);
    tested = false;
    testing = false;
  }

  Future<bool> test({required int totalWords}) => _operation(() async {
    await _prepare(totalWords);
    tested = false;
    testing = true;
    if (!await gate.service.launchApp(template.app)) {
      error =
          'Could not open ${template.app}. Make sure it is installed, then try again.';
      testing = false;
      throw StateError('launch');
    }
  });

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
