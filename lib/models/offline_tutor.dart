import 'dart:convert';

import 'word_identity.dart';

/// Only installed, local capabilities are reported here. No account or server
/// configuration participates in a camera lesson.
class OfflineTutorStatus {
  const OfflineTutorStatus({
    this.supported = false,
    this.runtimeAvailable = false,
    this.canRun = false,
    this.modelReady = false,
    this.modelBytes = 0,
    this.deviceMemoryBytes = 0,
    this.speechLocales = const [],
    this.message,
  });

  factory OfflineTutorStatus.fromMap(Map<Object?, Object?> map) =>
      OfflineTutorStatus(
        supported: map['supported'] == true,
        runtimeAvailable: map['runtimeAvailable'] == true,
        canRun: map['canRun'] == true,
        modelReady: map['modelReady'] == true,
        modelBytes: (map['modelBytes'] as num?)?.toInt() ?? 0,
        deviceMemoryBytes: (map['deviceMemoryBytes'] as num?)?.toInt() ?? 0,
        speechLocales: List.unmodifiable(
          (map['speechLocales'] as List? ?? const []).whereType<String>().where(
            (locale) => locale == 'vi-VN' || locale == 'en-US',
          ),
        ),
        message: map['message'] is String ? map['message'] as String : null,
      );

  final bool supported;
  final bool runtimeAvailable;
  final bool canRun;
  final bool modelReady;
  final int modelBytes;
  final int deviceMemoryBytes;
  final List<String> speechLocales;
  final String? message;
  bool get ready => supported && runtimeAvailable && canRun && modelReady;
}

class TutorVocabulary {
  const TutorVocabulary({
    required this.word,
    required this.meaningVi,
    required this.exampleEn,
    this.pronunciation,
  });
  final String word;
  final String meaningVi;
  final String exampleEn;
  final String? pronunciation;
}

class TutorReply {
  const TutorReply({
    required this.explanationVi,
    required this.answerEn,
    required this.vocabulary,
  });

  /// Model output is data, never markup, URLs, commands, or trusted app state.
  /// Never display raw output on a parse failure (it may contain reasoning).
  factory TutorReply.parse(String raw) {
    if (raw.length > 65536) throw const FormatException('Reply too large');
    var input = raw.trim();
    if (input.startsWith('```') && input.endsWith('```')) {
      final newline = input.indexOf('\n');
      if (newline < 0) throw const FormatException('Missing JSON');
      input = input.substring(newline + 1, input.length - 3).trim();
    }
    final decoded = jsonDecode(input);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Expected a lesson');
    }
    String requiredText(String key) {
      final value = decoded[key];
      if (value is! String || value.trim().isEmpty || value.length > 2000) {
        throw const FormatException('Incomplete lesson');
      }
      return value.trim();
    }

    final explanation = requiredText('explanationVi');
    final answer = requiredText('answerEn');
    final items = decoded['vocabulary'];
    if (items is! List) throw const FormatException('Missing vocabulary');
    final seen = <String>{};
    final words = <TutorVocabulary>[];
    for (final item in items.take(12)) {
      if (words.length == 4) break;
      if (item is! Map) continue;
      final word = item['word'];
      final meaning = item['meaningVi'];
      final example = item['exampleEn'];
      if (word is! String ||
          word.trim().isEmpty ||
          word.length > 80 ||
          word.contains('\n') ||
          meaning is! String ||
          meaning.trim().isEmpty ||
          meaning.length > 500 ||
          example is! String ||
          example.length > 800) {
        continue;
      }
      if (!seen.add(WordIdentity.key(word))) continue;
      final ipa = item['pronunciation'];
      words.add(
        TutorVocabulary(
          word: word.trim(),
          meaningVi: meaning.trim(),
          exampleEn: example.trim(),
          pronunciation: ipa is String && ipa.length <= 120 && ipa.isNotEmpty
              ? ipa.trim()
              : null,
        ),
      );
    }
    return TutorReply(
      explanationVi: explanation,
      answerEn: answer,
      vocabulary: List.unmodifiable(words),
    );
  }

  final String explanationVi;
  final String answerEn;
  final List<TutorVocabulary> vocabulary;
}

class TutorTurn {
  const TutorTurn({required this.question, required this.reply});
  final String question;
  final TutorReply reply;
}
