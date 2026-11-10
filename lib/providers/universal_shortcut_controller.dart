import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/universal_gate_status.dart';
import 'app_gate_provider.dart';
import 'shortcut_setup_controller.dart';

class UniversalShortcutController extends ChangeNotifier {
  UniversalShortcutController({
    required this.gate,
    required this.installUrl,
    OpenShortcutLink? openLink,
  }) : _openLink =
           openLink ??
           ((url) => launchUrl(url, mode: LaunchMode.externalApplication));
  final AppGateProvider gate;
  final Uri installUrl;
  final OpenShortcutLink _openLink;
  UniversalGateStatus status = const UniversalGateStatus();
  bool busy = false;
  bool openedInstaller = false;
  String? error;
  bool _disposed = false;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> refresh() async {
    try {
      status = await gate.service.getUniversalGateStatus();
      error = status.error;
      _changed();
    } catch (_) {
      /* Returning from Apple never implies setup was completed. */
    }
  }

  Future<void> setup(int totalWords) async {
    if (busy) return;
    busy = true;
    error = null;
    _changed();
    try {
      if (installUrl.scheme != 'https' ||
          installUrl.host != 'www.icloud.com' ||
          !RegExp(r'^/shortcuts/[a-f0-9]{32}$').hasMatch(installUrl.path)) {
        throw StateError('The setup link is unavailable. Please update Veea.');
      }
      final compatibility = await gate.service.getShortcutSetupStatus();
      if (!compatibility.supportsImport) {
        throw StateError('Ready-made app automations need iOS 27 or later.');
      }
      await gate.prepareChallenge();
      if (!gate.canEnable(totalWords)) {
        throw StateError(
          'Save at least 3 words and choose your practice words first.',
        );
      }
      if (gate.nativeStatus.enabled && !await gate.disableNativeProtection()) {
        throw StateError(
          gate.nativeError ?? 'Could not switch from timed access.',
        );
      }
      await gate.setPassDurationMinutes(0);
      if (!await gate.setEnabled(
        true,
        totalWords: totalWords,
        useDefaultApps: false,
      )) {
        throw StateError(gate.lastError ?? 'Could not prepare Every Open.');
      }
      await gate.service.setUniversalGateEnabled(true);
      if (!await _openLink(installUrl)) {
        throw StateError('Could not open Apple Shortcuts. Please try again.');
      }
      openedInstaller = true;
      await refresh();
    } catch (failure) {
      error = failure is StateError
          ? failure.message.toString()
          : 'Could not finish setup. Please try again.';
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> turnOff() async {
    if (busy) return;
    busy = true;
    error = null;
    _changed();
    try {
      await gate.service.setUniversalGateEnabled(false);
      await refresh();
    } catch (_) {
      error = 'Could not turn off Every Open. Please try again.';
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> manage() async {
    try {
      if (await _openLink(Uri.parse('shortcuts://'))) return;
    } catch (_) {
      // Keep the instructions visible when Apple Shortcuts cannot be opened.
    }
    error = 'Open Apple Shortcuts → Automation → Veea App Gate.';
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
