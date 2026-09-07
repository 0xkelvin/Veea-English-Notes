import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:veea_english_app/models/part_of_speech.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/services/word_suggestion_service.dart';

void main() {
  group('WordSuggestionService', () {
    setUp(() {
      WordSuggestionService.clearCache();
      WordSuggestionService.allowOnlineTranslation = true;
    });

    test('suggests Vietnamese meaning and PartOfSpeech for solution', () async {
      final suggestion = await WordSuggestionService.suggest('solution');
      expect(suggestion, isNotNull);
      expect(suggestion!.meaning, contains('giải pháp'));
      expect(suggestion.partOfSpeech, PartOfSpeech.noun);
    });

    test(
      'suggests Vietnamese meaning and PartOfSpeech for common dictionary words',
      () async {
        final suggestion = await WordSuggestionService.suggest('resilient');
        expect(suggestion, isNotNull);
        expect(suggestion!.meaning, contains('kiên cường'));
        expect(suggestion.partOfSpeech, PartOfSpeech.adjective);
      },
    );

    test('suggests fast synchronously from local dictionary', () {
      final suggestion = WordSuggestionService.suggestFast('solution');
      expect(suggestion, isNotNull);
      expect(suggestion!.meaning, contains('giải pháp'));
      expect(suggestion.partOfSpeech, PartOfSpeech.noun);
    });

    test('suggests from career cartridges', () async {
      final suggestion = await WordSuggestionService.suggest('idempotent');
      expect(suggestion, isNotNull);
      expect(suggestion!.meaning, contains('Bảo toàn kết quả'));
      expect(suggestion.partOfSpeech, PartOfSpeech.adjective);
      expect(suggestion.source, 'Tech Cartridge');
    });

    test('prefers user previous notes if provided', () async {
      final userWords = [
        VocabularyWord.create(
          id: '1',
          word: 'customword',
          meaning: 'nghĩa đặc biệt của tôi',
          date: '2026-09-03',
          partOfSpeech: PartOfSpeech.noun,
          now: DateTime.now(),
        ),
      ];

      final suggestion = await WordSuggestionService.suggest(
        'customword',
        userWords: userWords,
      );
      expect(suggestion, isNotNull);
      expect(suggestion!.meaning, 'nghĩa đặc biệt của tôi');
      expect(suggestion.partOfSpeech, PartOfSpeech.noun);
      expect(suggestion.source, 'Previous note');
    });

    test(
      'detects grammatical PartOfSpeech for unknown words using suffix heuristics',
      () {
        expect(
          WordSuggestionService.detectPartOfSpeech('modernization'),
          PartOfSpeech.noun,
        );
        expect(
          WordSuggestionService.detectPartOfSpeech('thoughtfully'),
          PartOfSpeech.adverb,
        );
        expect(
          WordSuggestionService.detectPartOfSpeech('orchestrate'),
          PartOfSpeech.verb,
        );
        expect(
          WordSuggestionService.detectPartOfSpeech('effortless'),
          PartOfSpeech.adjective,
        );
        expect(
          WordSuggestionService.detectPartOfSpeech('in a heartbeat'),
          PartOfSpeech.phrase,
        );
      },
    );

    test('returns null for blank or 1-letter inputs', () async {
      expect(await WordSuggestionService.suggest(''), isNull);
      expect(await WordSuggestionService.suggest('a'), isNull);
      expect(WordSuggestionService.suggestFast(''), isNull);
    });

    test('allowOnlineTranslation defaults to true', () {
      expect(WordSuggestionService.allowOnlineTranslation, isTrue);
    });

    test(
      'online translation suggests Vietnamese meaning for words not in offline dict',
      () async {
        final mockClient = MockClient((request) async {
          expect(request.url.queryParameters['q'], 'labyrinthine');
          expect(request.url.queryParameters['tl'], 'vi');
          return http.Response.bytes(
            utf8.encode(
              jsonEncode([
                [
                  ['như mê cung', 'labyrinthine', null, null, 1],
                ],
                [
                  [
                    'adjective',
                    ['rắc rối', 'phức tạp'],
                  ],
                ],
              ]),
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        });

        final suggestion = await WordSuggestionService.suggest(
          'labyrinthine',
          client: mockClient,
        );

        expect(suggestion, isNotNull);
        expect(suggestion!.meaning, contains('như mê cung'));
        expect(suggestion.meaning, contains('rắc rối'));
        expect(suggestion.partOfSpeech, PartOfSpeech.adjective);
        expect(suggestion.source, 'Dictionary');
      },
    );

    test('disabling online translation skips remote query', () async {
      var clientCalled = false;
      final mockClient = MockClient((request) async {
        clientCalled = true;
        return http.Response('[]', 200);
      });

      final suggestion = await WordSuggestionService.suggest(
        'labyrinthine',
        client: mockClient,
        allowOnline: false,
      );

      expect(clientCalled, isFalse);
      expect(suggestion?.meaning, isNull);
    });

    test('suggests Vietnamese meaning and PartOfSpeech for option', () async {
      final fast = WordSuggestionService.suggestFast('option');
      expect(fast, isNotNull);
      expect(fast!.meaning, contains('lựa chọn'));
      expect(fast.partOfSpeech, PartOfSpeech.noun);

      final asyncSug = await WordSuggestionService.suggest('option');
      expect(asyncSug, isNotNull);
      expect(asyncSug!.meaning, contains('lựa chọn'));
      expect(asyncSug.partOfSpeech, PartOfSpeech.noun);
    });

    test(
      'falls back to MyMemory API when Google Translate returns HTML block page',
      () async {
        final mockClient = MockClient((request) async {
          if (request.url.host == 'translate.googleapis.com') {
            // Simulate Google's bot captcha / rate limit HTML block page
            return http.Response(
              '<html><head><title>Sorry...</title></head><body>automated queries</body></html>',
              200,
              headers: {'content-type': 'text/html; charset=utf-8'},
            );
          }
          if (request.url.host == 'api.mymemory.translated.net') {
            return http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'responseData': {
                    'translatedText': 'người nhìn xa trông rộng',
                    'match': 1,
                  },
                  'responseStatus': 200,
                }),
              ),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response('Not Found', 404);
        });

        final suggestion = await WordSuggestionService.suggest(
          'visionary',
          client: mockClient,
        );

        expect(suggestion, isNotNull);
        expect(suggestion!.meaning, 'người nhìn xa trông rộng');
        expect(suggestion.source, 'Dictionary');
      },
    );

    test('handles online translation network error gracefully', () async {
      final mockClient = MockClient((request) async {
        throw Exception('Network unreachable');
      });

      final suggestion = await WordSuggestionService.suggest(
        'kaleidoscopic',
        client: mockClient,
      );

      expect(suggestion, isNotNull);
      expect(suggestion!.partOfSpeech, PartOfSpeech.adjective);
      expect(suggestion.meaning, isNull);
    });
  });
}
