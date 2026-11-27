import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/config/app_config.dart';
import '../providers/app_gate_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/pro_provider.dart';
import '../screens/app_gate_screen.dart';
import '../screens/pro_screen.dart';
import '../screens/selected_practice_words_screen.dart';
import 'pixel/pixel_box.dart';
import 'pixel/pixel_button.dart';
import 'practice_word_picker.dart';

/// Learning rules are shared by native protection and Shortcut protection.
class GateLearningSettings extends StatefulWidget {
  const GateLearningSettings({
    super.key,
    required this.gate,
    required this.totalWords,
  });
  final AppGateProvider gate;
  final int totalWords;

  @override
  State<GateLearningSettings> createState() => _GateLearningSettingsState();
}

class _GateLearningSettingsState extends State<GateLearningSettings> {
  bool _saving = false;

  bool _hasProSupport(BuildContext context, {bool listen = false}) {
    try {
      if (listen) {
        context.watch<ProProvider>();
        context.watch<AuthProvider>();
      } else {
        context.read<ProProvider>();
        context.read<AuthProvider>();
      }
      return true;
    } on ProviderNotFoundException {
      return false;
    }
  }

  Future<void> _openProUpgrade(BuildContext context) async {
    if (_hasProSupport(context)) {
      await ProScreen.open(context);
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Upgrade to Veea Pro to require multiple words per unlock. Upgrades are unavailable right now.',
        ),
      ),
    );
  }

  Future<void> _practice() async {
    setState(() => _saving = true);
    try {
      await widget.gate.prepareChallenge();
      if (!mounted) return;
      final nativeApps = widget.gate.nativeStatus.applications;
      final target = nativeApps.isNotEmpty
          ? nativeApps.first.id
          : widget.gate.config.gatedApps.firstOrNull ?? 'Practice';
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChangeNotifierProvider.value(
            value: widget.gate,
            child: AppGateScreen(targetApp: target, previewMode: true),
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not load the practice challenge. Please try again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save(Future<void> Function() action) async {
    setState(() => _saving = true);
    try {
      await action();
    } on PlatformException catch (error) {
      if (!mounted) return;
      if (error.code == 'PRO_REQUIRED' && !AppConfig.isFreeLaunch) {
        await _openProUpgrade(context);
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error.message ??
                'Could not save your learning rule. Please try again.',
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not save your learning rule. Please try again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.gate,
    builder: (context, _) {
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final words = widget.gate.practiceWords;
      final count = words.length;
      final wordLabel = count == 1 ? 'word' : 'words';
      final multiple = widget.gate.canUseMultipleWords;
      return PixelBox(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Words to unlock', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              count == 0
                  ? 'Choose your first word'
                  : 'Review $count $wordLabel to unlock',
              key: const Key('unlock_rule_summary'),
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              count == 0
                  ? 'Pick a word from your notebook to get started.'
                  : 'Every unlock includes every word selected below.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            for (final word in words.take(3))
              ListTile(
                key: ValueKey('practice_word_preview_${word.id}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.check_circle_outline,
                  color: colors.primary,
                ),
                title: Text(word.word, style: theme.textTheme.titleSmall),
                subtitle: Text(
                  word.meaning,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (count > 0)
              TextButton.icon(
                key: const Key('view_selected_practice_words'),
                onPressed: _saving
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              SelectedPracticeWordsScreen(gate: widget.gate),
                        ),
                      ),
                icon: const Icon(Icons.format_list_bulleted),
                label: Text(
                  count == 1
                      ? 'View selected word'
                      : 'View all $count selected words',
                ),
              ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('edit_unlock_words'),
                onPressed: _saving || widget.totalWords == 0
                    ? null
                    : () => _save(() async {
                        await choosePracticeWords(
                          context,
                          widget.gate,
                          onUpgrade: () => _openProUpgrade(context),
                        );
                      }),
                icon: const Icon(Icons.edit_outlined),
                label: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(count == 0 ? 'Choose words' : 'Change words'),
                ),
              ),
            ),
            if (!multiple) ...[
              const SizedBox(height: 12),
              Text(
                'Free includes 1 selected word. Choose more words with a one-time Pro upgrade.',
                style: theme.textTheme.bodySmall,
              ),
              if (widget.gate.pausedPracticeWordCount > 0)
                Text(
                  '${widget.gate.pausedPracticeWordCount} more saved ${widget.gate.pausedPracticeWordCount == 1 ? 'word is' : 'words are'} paused on Free. Pro restores the full selection.',
                  style: theme.textTheme.bodySmall,
                ),
              TextButton.icon(
                key: const Key('upgrade_words_per_unlock'),
                onPressed: _saving ? null : () => _openProUpgrade(context),
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: const Text('Choose more words with Pro'),
              ),
            ],
            const Divider(height: 32),
            Material(
              type: MaterialType.transparency,
              child: SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto-play pronunciation'),
                subtitle: const Text(
                  'Read words aloud after answers and hints.',
                ),
                value: widget.gate.config.autoPronounce,
                onChanged: _saving
                    ? null
                    : (value) =>
                          _save(() => widget.gate.setAutoPronounce(value)),
              ),
            ),
            const SizedBox(height: 8),
            PixelButton(
              label: 'Practice challenge',
              expand: true,
              onPressed: _saving || count == 0 ? null : _practice,
            ),
            const SizedBox(height: 8),
            Text(
              'Preview this exact word list. Your learning progress stays unchanged.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              'If you leave a challenge, completed words are saved for that app.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      );
    },
  );
}
