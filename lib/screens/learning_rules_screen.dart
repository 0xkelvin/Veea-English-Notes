import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_gate_provider.dart';
import '../widgets/gate_learning_settings.dart';

class LearningRulesScreen extends StatelessWidget {
  const LearningRulesScreen({super.key, required this.gate});
  final AppGateProvider gate;
  @override
  Widget build(BuildContext context) => ChangeNotifierProvider.value(
    value: gate,
    child: Scaffold(
      appBar: AppBar(title: const Text('Learning rules')),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: gate,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              GateLearningSettings(
                gate: gate,
                totalWords: gate.notebookWords.length,
              ),
              const SizedBox(height: 20),
              const Text('OPTIONAL NOTEBOOK GOAL'),
              const SizedBox(height: 8),
              Material(
                child: SwitchListTile.adaptive(
                  title: const Text('Add one new word each day'),
                  subtitle: const Text(
                    'Show a daily goal in your notebook. This never blocks app access.',
                  ),
                  value: gate.config.dailyWordGoal,
                  onChanged: (value) async {
                    try {
                      await gate.setDailyWordGoal(value);
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Could not save your daily goal. Please try again.',
                            ),
                          ),
                        );
                      }
                    }
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
