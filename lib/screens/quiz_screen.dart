import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/l10n/app_strings.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_theme.dart';
import '../models/vocabulary_word.dart';
import '../providers/locale_provider.dart';

class QuizScreen extends StatefulWidget {
  final List<VocabularyWord> words;

  const QuizScreen({super.key, required this.words});

  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends State<QuizScreen> {
  late final List<VocabularyWord> _shuffled;
  late final List<_Question> _questions;
  late AppStrings _s;

  int _index = 0;
  int _score = 0;
  int? _selectedOption; // index of selected answer
  bool get _answered => _selectedOption != null;
  bool get _isDone => _index >= _questions.length;

  @override
  void initState() {
    super.initState();
    final rng = math.Random();
    _shuffled = List.of(widget.words)..shuffle(rng);
    _questions = _shuffled.map((w) => _buildQuestion(w, rng)).toList().cast<_Question>();
  }

  _Question _buildQuestion(VocabularyWord correct, math.Random rng) {
    // Pick 3 unique wrong answers
    final pool = widget.words.where((w) => w.id != correct.id).toList()
      ..shuffle(rng);
    final wrongs = pool.take(3).toList();

    final options = [correct.vietnameseMeaning, ...wrongs.map((w) => w.vietnameseMeaning)]
      ..shuffle(rng);

    return _Question(
      word: correct,
      options: options,
      correctIndex: options.indexOf(correct.vietnameseMeaning),
    );
  }

  void _select(int optionIndex) {
    if (_answered) return;
    setState(() {
      _selectedOption = optionIndex;
      if (optionIndex == _questions[_index].correctIndex) _score++;
    });
  }

  void _next() {
    setState(() {
      _index++;
      _selectedOption = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    _s = AppStrings(context.watch<LocaleProvider>().isVietnamese);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(context),
            if (!_isDone) ...[
              _buildProgress(),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                  child: _buildQuestionWidget(),
                ),
              ),
              if (_answered)
                _buildNextButton(),
              const SizedBox(height: 16),
            ] else
              Expanded(child: _buildSummary(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.secondary,
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              ),
              child: const Icon(Icons.arrow_back_ios_new_rounded,
                  size: 18, color: AppColors.foreground),
            ),
          ),
          const SizedBox(width: 16),
          Text(
            _s.multipleChoice,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const Spacer(),
          if (!_isDone)
            Text(
              '${_index + 1}/${_questions.length}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.mutedForeground,
                  ),
            ),
        ],
      ),
    );
  }

  Widget _buildProgress() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _index / _questions.length,
              minHeight: 5,
              backgroundColor: AppColors.secondary,
              valueColor:
                  const AlwaysStoppedAnimation(AppColors.accent),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _s.correct + ': $_score',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF10B981),
                    ),
              ),
              Text(
                _s.wrong + ': ${_index - _score}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFFEF4444),
                    ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQuestionWidget() {
    final q = _questions[_index];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _s.quizQuestion,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.mutedForeground,
              ),
        ),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppColors.accent.withValues(alpha: 0.15),
                AppColors.primary.withValues(alpha: 0.1),
              ],
            ),
            borderRadius: BorderRadius.circular(AppTheme.radiusXl),
            border: Border.all(
              color: AppColors.accent.withValues(alpha: 0.3),
            ),
          ),
          child: Text(
            q.word.word,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
        ),
        const SizedBox(height: 28),
        ...List.generate(q.options.length, (i) => _buildOption(q, i)),
      ],
    );
  }

  Widget _buildOption(_Question q, int optionIndex) {
    final isCorrect = optionIndex == q.correctIndex;
    final isSelected = _selectedOption == optionIndex;

    Color borderColor = AppColors.border;
    Color bgColor = AppColors.card;
    Color textColor = AppColors.foreground;

    if (_answered) {
      if (isCorrect) {
        borderColor = const Color(0xFF10B981);
        bgColor = const Color(0xFF10B981).withValues(alpha: 0.12);
        textColor = const Color(0xFF10B981);
      } else if (isSelected) {
        borderColor = const Color(0xFFEF4444);
        bgColor = const Color(0xFFEF4444).withValues(alpha: 0.12);
        textColor = const Color(0xFFEF4444);
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: () => _select(optionIndex),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              _buildOptionLabel(optionIndex, isCorrect, isSelected),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  q.options[optionIndex],
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: textColor,
                        fontWeight: isCorrect && _answered
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                ),
              ),
              if (_answered && isCorrect)
                const Icon(Icons.check_circle_rounded,
                    color: Color(0xFF10B981), size: 20),
              if (_answered && isSelected && !isCorrect)
                const Icon(Icons.cancel_rounded,
                    color: Color(0xFFEF4444), size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOptionLabel(int index, bool isCorrect, bool isSelected) {
    const labels = ['A', 'B', 'C', 'D'];
    Color bg = AppColors.secondary;
    Color fg = AppColors.mutedForeground;

    if (_answered) {
      if (isCorrect) {
        bg = const Color(0xFF10B981);
        fg = Colors.white;
      } else if (isSelected) {
        bg = const Color(0xFFEF4444);
        fg = Colors.white;
      }
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 28,
      height: 28,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Center(
        child: Text(
          labels[index],
          style: TextStyle(
            color: fg,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildNextButton() {
    final isLast = _index >= _questions.length - 1;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: SizedBox(
        width: double.infinity,
        height: 50,
        child: ElevatedButton(
          onPressed: _next,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            ),
          ),
          child: Text(
            isLast ? _s.seeResults : _s.nextQuestion,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  Widget _buildSummary(BuildContext context) {
    final pct = (_score / _questions.length * 100).round();
    final isGood = pct >= 70;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                gradient: isGood
                    ? const LinearGradient(
                        colors: [Color(0xFF10B981), Color(0xFF059669)])
                    : AppColors.primaryGradient,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  '$pct%',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              isGood ? _s.excellentResult : _s.needMorePractice,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              _s.quizScore(_score, _questions.length),
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: AppColors.mutedForeground,
                  ),
            ),
            const SizedBox(height: 40),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      setState(() {
                        final rng = math.Random();
                        _shuffled.shuffle(rng);
                        for (int i = 0; i < _shuffled.length; i++) {
                          _questions[i] = _buildQuestion(_shuffled[i], rng);
                        }
                        _index = 0;
                        _score = 0;
                        _selectedOption = null;
                      });
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.foreground,
                      side: BorderSide(color: AppColors.border),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                      ),
                    ),
                    child: Text(_s.tryAgain,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                      ),
                    ),
                    child: Text(_s.backToStudy,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Question {
  final VocabularyWord word;
  final List<String> options;
  final int correctIndex;

  const _Question({
    required this.word,
    required this.options,
    required this.correctIndex,
  });
}
