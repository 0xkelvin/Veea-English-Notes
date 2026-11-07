import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../providers/app_gate_provider.dart';
import '../models/gate_config.dart';
import '../screens/app_gate_screen.dart';
import 'pixel/pixel_box.dart';
import 'pixel/pixel_button.dart';
import 'pixel/pixel_icon.dart';

class NativeGateSettings extends StatelessWidget {
  const NativeGateSettings({
    super.key,
    required this.gate,
    required this.totalWords,
    this.onAddWord,
  });

  final AppGateProvider gate;
  final int totalWords;
  final VoidCallback? onAddWord;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: gate,
      builder: (context, _) {
        final status = gate.nativeStatus;
        final busy = gate.nativeBusy;
        return PixelBox(
          padding: const EdgeInsets.all(PixelMetrics.space4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SCREEN TIME PROTECTION',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: PixelMetrics.space2),
              const Text(
                'Choose your apps once. Complete vocabulary challenges to earn timed access. No Shortcuts setup needed.',
              ),
              const SizedBox(height: PixelMetrics.space3),
              if (!status.available)
                const Text(
                  'Screen Time protection is not available in this build. You can keep using the Shortcut setup below.',
                )
              else ...[
                if (!gate.canEnable(totalWords)) ...[
                  Text(
                    totalWords < GateConfig.minRequiredWords
                        ? 'Save at least ${GateConfig.minRequiredWords} words before starting protection ($totalWords/${GateConfig.minRequiredWords} saved).'
                        : 'Choose at least one practice word in Learning Rules before starting protection.',
                  ),
                  if (onAddWord != null &&
                      totalWords < GateConfig.minRequiredWords)
                    TextButton(
                      onPressed: onAddWord,
                      child: const Text('Add a word'),
                    ),
                  const SizedBox(height: PixelMetrics.space2),
                ],
                if (status.configured && !status.authorized) ...[
                  const Text(
                    'Screen Time access was removed. Your apps are not protected. Restore access to turn protection back on.',
                  ),
                  const SizedBox(height: PixelMetrics.space2),
                ],
                if (!status.enabled)
                  const Text(
                    'Setup: save vocabulary → allow Screen Time access → choose apps.',
                  ),
                Text(
                  status.enabled
                      ? '${status.applications.length} ${status.applications.length == 1 ? 'app' : 'apps'} protected'
                      : 'Protection is off',
                ),
                const SizedBox(height: PixelMetrics.space2),
                const Text('EARNED ACCESS DURATION'),
                Wrap(
                  spacing: PixelMetrics.space2,
                  children: [
                    for (final minutes in [15, 30])
                      ChoiceChip(
                        label: Text('$minutes min'),
                        selected: status.passMinutes == minutes,
                        onSelected: busy
                            ? null
                            : (_) => gate.setNativeDuration(minutes),
                      ),
                  ],
                ),
                const Text(
                  'Timed passes remain active if you close Veea. Every Open and 5-minute passes are available in Shortcut mode below.',
                ),
                const SizedBox(height: PixelMetrics.space3),
                if (!status.enabled)
                  PixelButton(
                    label: busy
                        ? 'Setting up…'
                        : status.configured && !status.authorized
                        ? 'Restore Screen Time access'
                        : status.applications.isNotEmpty
                        ? 'Turn on protection'
                        : 'Set up Screen Time',
                    filled: true,
                    glyph: PixelGlyph.shield,
                    expand: true,
                    onPressed: busy || !gate.canEnable(totalWords)
                        ? null
                        : () => gate.enableNativeProtection(
                            totalWords: totalWords,
                          ),
                  )
                else ...[
                  PixelButton(
                    label: 'Protected apps · Learn to unlock',
                    glyph: PixelGlyph.shield,
                    expand: true,
                    onPressed: busy
                        ? null
                        : () async {
                            final target = await gate
                                .manageNativeApplications();
                            if (!context.mounted || target == null) return;
                            await gate.prepareChallenge();
                            if (!context.mounted) return;
                            await Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => ChangeNotifierProvider.value(
                                  value: gate,
                                  child: AppGateScreen(targetApp: target),
                                ),
                              ),
                            );
                          },
                  ),
                  const SizedBox(height: PixelMetrics.space2),
                  PixelButton(
                    label: 'Change protected apps',
                    expand: true,
                    onPressed: busy
                        ? null
                        : () => gate.chooseNativeApplications(),
                  ),
                  const Text(
                    'Existing Veea Shortcuts are paused while Screen Time protection is on.',
                  ),
                ],
                if (status.configured || status.enabled)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => gate.disableNativeProtection(),
                    child: const Text('Turn off Screen Time protection'),
                  ),
              ],
              if (status.error != null) ...[
                Text(
                  status.error!,
                  style: TextStyle(color: context.palette.danger),
                ),
                TextButton(
                  onPressed: busy ? null : () => gate.disableNativeProtection(),
                  child: const Text('Reset protection'),
                ),
              ],
              if (gate.nativeError != null) ...[
                const SizedBox(height: PixelMetrics.space2),
                Text(
                  gate.nativeError!,
                  style: TextStyle(color: context.palette.danger),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
