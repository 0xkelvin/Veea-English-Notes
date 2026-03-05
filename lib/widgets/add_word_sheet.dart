import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_theme.dart';
import '../providers/vocabulary_provider.dart';

class AddWordSheet extends StatefulWidget {
  const AddWordSheet({super.key});

  @override
  State<AddWordSheet> createState() => _AddWordSheetState();
}

class _AddWordSheetState extends State<AddWordSheet> {
  final _wordController = TextEditingController();
  final _meaningController = TextEditingController();
  final List<TextEditingController> _exampleControllers = [];
  bool _saving = false;

  @override
  void dispose() {
    _wordController.dispose();
    _meaningController.dispose();
    for (final c in _exampleControllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _addExample() {
    setState(() {
      _exampleControllers.add(TextEditingController());
    });
  }

  void _removeExample(int index) {
    setState(() {
      _exampleControllers[index].dispose();
      _exampleControllers.removeAt(index);
    });
  }

  bool get _isValid =>
      _wordController.text.trim().isNotEmpty &&
      _meaningController.text.trim().isNotEmpty;

  Future<void> _save() async {
    if (!_isValid || _saving) return;
    setState(() => _saving = true);

    await context.read<VocabularyProvider>().addWord(
      word: _wordController.text,
      vietnameseMeaning: _meaningController.text,
      examples: _exampleControllers.map((c) => c.text).toList(),
    );

    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      padding: EdgeInsets.only(bottom: bottomPadding),
      decoration: const BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.mutedForeground.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    gradient: AppColors.primaryGradient,
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  ),
                  child: const Icon(Icons.auto_awesome, size: 18, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Text(
                  'Add New Word',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.secondary,
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    ),
                    child: const Icon(Icons.close, size: 18, color: AppColors.mutedForeground),
                  ),
                ),
              ],
            ),
          ),

          Divider(color: AppColors.border, height: 1),

          // Form
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildLabel(context, 'English Word'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _wordController,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(color: AppColors.foreground),
                    decoration: const InputDecoration(
                      hintText: 'Enter an English word',
                    ),
                    textCapitalization: TextCapitalization.sentences,
                  ),

                  const SizedBox(height: 20),

                  // Sparkles divider
                  Row(
                    children: [
                      Expanded(child: Divider(color: AppColors.border)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Icon(
                          Icons.auto_awesome,
                          size: 16,
                          color: AppColors.primary.withValues(alpha: 0.6),
                        ),
                      ),
                      Expanded(child: Divider(color: AppColors.border)),
                    ],
                  ),

                  const SizedBox(height: 20),

                  _buildLabel(context, 'Vietnamese Meaning'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _meaningController,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(color: AppColors.foreground),
                    decoration: const InputDecoration(
                      hintText: 'Enter Vietnamese meaning',
                    ),
                    textCapitalization: TextCapitalization.sentences,
                  ),

                  const SizedBox(height: 20),

                  // Examples
                  Row(
                    children: [
                      _buildLabel(context, 'Examples'),
                      const SizedBox(width: 4),
                      Text(
                        '(optional)',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.mutedForeground,
                          fontSize: 12,
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: _addExample,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.add,
                                size: 14,
                                color: AppColors.primary,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Add',
                                style: TextStyle(
                                  color: AppColors.primary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  ..._exampleControllers.asMap().entries.map((entry) {
                    final index = entry.key;
                    final controller = entry.value;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: controller,
                              style: const TextStyle(
                                color: AppColors.foreground,
                                fontSize: 14,
                              ),
                              maxLines: 2,
                              minLines: 1,
                              decoration: InputDecoration(
                                hintText: 'Example sentence ${index + 1}',
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                              ),
                              textCapitalization: TextCapitalization.sentences,
                            ),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () => _removeExample(index),
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: AppColors.destructive.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                              ),
                              child: const Icon(
                                Icons.close,
                                size: 16,
                                color: AppColors.destructive,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),

                  if (_exampleControllers.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.secondary,
                        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                        border: Border.all(
                          color: AppColors.border,
                          style: BorderStyle.solid,
                        ),
                      ),
                      child: Text(
                        'Tap "Add" to include example sentences',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.mutedForeground,
                        ),
                      ),
                    ),

                  const SizedBox(height: 24),

                  // Save button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isValid ? _save : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isValid
                            ? AppColors.primary
                            : AppColors.primary.withValues(alpha: 0.3),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                        ),
                      ),
                      child: _saving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.save_rounded, size: 18),
                                const SizedBox(width: 8),
                                Text(
                                  'Save to Vocabulary',
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelLarge
                                      ?.copyWith(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                              ],
                            ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLabel(BuildContext context, String text) {
    return Text(
      text,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w500,
        color: AppColors.foreground,
      ),
    );
  }
}
