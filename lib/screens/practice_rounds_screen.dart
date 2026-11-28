import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/vocabulary_word.dart';
import '../providers/vocabulary_provider.dart';
import 'pro_screen.dart';
import 'review_screen.dart';
import 'word_editor_screen.dart';

/// Selects a fixed round size, then runs the same cards and rating flow as Review.
class PracticeRoundsScreen extends StatefulWidget {
  const PracticeRoundsScreen({super.key});

  @override
  State<PracticeRoundsScreen> createState() => _PracticeRoundsScreenState();
}

class _PracticeRoundsScreenState extends State<PracticeRoundsScreen> {
  final _count = TextEditingController(text: '2');

  @override
  void dispose() {
    _count.dispose();
    super.dispose();
  }

  Future<List<VocabularyWord>> _loadWords() async {
    final words = await context.read<VocabularyProvider>().allWords();
    return words
        .where((w) => w.word.trim().isNotEmpty && w.meaning.trim().isNotEmpty)
        .toList();
  }

  late final Future<List<VocabularyWord>> _words = _loadWords();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(practiceText(context, 'Practice Rounds', 'Lượt luyện tập')),
      ),
      body: SafeArea(
        child: FutureBuilder<List<VocabularyWord>>(
          future: _words,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Text(
                  practiceText(
                    context,
                    'Could not load your words. Reopen Practice Rounds to retry.',
                    'Không tải được từ vựng. Hãy mở lại Lượt luyện tập để thử lại.',
                  ),
                ),
              );
            }
            final words = snapshot.data;
            if (words == null) {
              return const Center(child: CircularProgressIndicator());
            }
            if (words.isEmpty) {
              return ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text(
                    practiceText(
                      context,
                      'Save a word with a meaning to start a round.',
                      'Lưu một từ kèm nghĩa để bắt đầu luyện tập.',
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        Navigator.of(context).pushReplacement<void, void>(
                          MaterialPageRoute<void>(
                            builder: (_) => const WordEditorScreen(),
                          ),
                        ),
                    child: Text(practiceText(context, 'Add a word', 'Thêm từ')),
                  ),
                ],
              );
            }
            return ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  practiceText(
                    context,
                    'Words ready to practise: ${words.length}',
                    'Số từ có thể luyện: ${words.length}',
                  ),
                ),
                const SizedBox(height: 16),
                if (words.length > 1)
                  TextField(
                    key: const Key('practice_round_count'),
                    controller: _count,
                    decoration: InputDecoration(
                      labelText: practiceText(
                        context,
                        'Words per round',
                        'Số từ mỗi lượt',
                      ),
                      helperText: '1–${words.length}',
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  )
                else
                  Text(
                    practiceText(
                      context,
                      'One word per round',
                      'Mỗi lượt một từ',
                    ),
                  ),
                if (words.length == 1)
                  Text(
                    practiceText(
                      context,
                      'Save more words with meanings for a longer round.',
                      'Lưu thêm từ kèm nghĩa để luyện nhiều từ hơn.',
                    ),
                  ),
                const SizedBox(height: 16),
                FilledButton(
                  key: const Key('start_practice_round'),
                  onPressed: () {
                    final count = words.length > 1
                        ? int.tryParse(_count.text)
                        : 1;
                    if (count == null || count < 1 || count > words.length) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            practiceText(
                              context,
                              'Choose between 1 and ${words.length} words.',
                              'Chọn từ 1 đến ${words.length} từ.',
                            ),
                          ),
                        ),
                      );
                      return;
                    }
                    final selection = words.toList()..shuffle();
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => ReviewScreen.practiceRound(
                          words: selection.take(count).toList(),
                        ),
                      ),
                    );
                  },
                  child: Text(practiceText(context, 'Start round', 'Bắt đầu')),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
