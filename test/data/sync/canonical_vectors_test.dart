import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/data/sync/canonical.dart';

/// TRD 05 §15.2 check 11: the Dart encoder and validator produce exactly the
/// bytes, sizes, code-point counts and invalid details the Go encoder
/// generated (backend/internal/learning/testdata/canonical_vectors.json).
void main() {
  final file = File(
    'backend/internal/learning/testdata/canonical_vectors.json',
  );
  final data = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  final vectors = (data['vectors']! as List).cast<Map<String, Object?>>();

  test('the vector file has the shared limits', () {
    final limits = data['limits']! as Map<String, Object?>;
    expect(limits['max_item_bytes'], SyncLimits.maxItemBytes);
    expect(limits['max_word'], SyncLimits.maxWord);
    expect(limits['max_meaning'], SyncLimits.maxMeaning);
    expect(limits['max_pronunciation'], SyncLimits.maxPronunciation);
    expect(limits['max_source'], SyncLimits.maxSource);
    expect(limits['max_examples'], SyncLimits.maxExamples);
    expect(limits['max_example'], SyncLimits.maxExample);
    expect(limits['max_tags'], SyncLimits.maxTags);
    expect(limits['max_tag'], SyncLimits.maxTag);
    expect(limits['max_live_words'], SyncLimits.maxLiveWords);
    expect(limits['max_content_bytes'], SyncLimits.maxContentBytes);
    expect(vectors.length, greaterThan(30));
  });

  for (final v in vectors) {
    test('vector: ${v['name']}', () {
      final item = v['item']! as Map<String, Object?>;
      final c = SyncContent.fromJson(item);
      final bytes = canonicalEncode(c);
      expect(
        base64.encode(bytes),
        v['canonical_b64'],
        reason: 'canonical bytes',
      );
      expect(bytes.length, v['size']);
      expect(canonicalSize(c), v['size']);
      expect(c.word.runes.length, v['word_code_points']);
      final invalid = validateSyncItem(
        c,
        captureDay: item['capture_day']! as String,
        clientCreatedAt: item['client_created_at']! as String,
      );
      expect(invalid?.detail ?? '', v['invalid_detail']);
      expect(invalid?.field ?? '', v['invalid_field']);
    });
  }

  test('a lone surrogate, which no Go vector can hold, is invalid_utf8', () {
    final c = SyncContent(word: 'a\uD800b', meaning: 'm');
    expect(
      validateSyncItem(
        c,
        captureDay: '2026-11-14',
        clientCreatedAt: '2026-11-14T00:00:00Z',
      )?.detail,
      'invalid_utf8',
    );
  });
}
