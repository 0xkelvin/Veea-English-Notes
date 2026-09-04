import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veea_english_app/models/vocabulary_word.dart';
import 'package:veea_english_app/services/commute_playlist_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late CommutePlaylistService service;

  final words = [
    VocabularyWord(
      id: 'w1',
      word: 'resilient',
      meaning: 'kiên cường',
      date: '2026-08-18',
      createdAt: DateTime(2026, 8, 18, 10),
      updatedAt: DateTime(2026, 8, 18, 10),
    ),
    VocabularyWord(
      id: 'w2',
      word: 'bottleneck',
      meaning: 'điểm nghẽn',
      date: '2026-08-18',
      createdAt: DateTime(2026, 8, 18, 11),
      updatedAt: DateTime(2026, 8, 18, 11),
    ),
    VocabularyWord(
      id: 'w3',
      word: 'paradigm',
      meaning: 'mô hình',
      date: '2026-08-17',
      createdAt: DateTime(2026, 8, 17, 9),
      updatedAt: DateTime(2026, 8, 17, 9),
    ),
  ];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    service = CommutePlaylistService(prefs: prefs);
    await service.init();
  });

  test('groupWordsByDate groups words correctly and sorts descending', () {
    final grouped = CommutePlaylistService.groupWordsByDate(words);
    expect(grouped.keys.toList(), ['2026-08-18', '2026-08-17']);
    expect(grouped['2026-08-18']!.length, 2);
    expect(grouped['2026-08-17']!.length, 1);
  });

  test('createPlaylist adds and persists new playlist', () async {
    final pl = await service.createPlaylist('Tech Standup', ['w1', 'w2']);
    expect(pl.name, 'Tech Standup');
    expect(pl.wordIds, ['w1', 'w2']);
    expect(service.playlists.length, 1);

    // Re-instantiate from prefs to test persistence
    final service2 = CommutePlaylistService(prefs: prefs);
    await service2.init();
    expect(service2.playlists.length, 1);
    expect(service2.playlists.first.name, 'Tech Standup');
  });

  test('updatePlaylist updates existing playlist', () async {
    final pl = await service.createPlaylist('Tech Standup', ['w1']);
    await service.updatePlaylist(pl.copyWith(name: 'Tech Interview', wordIds: ['w1', 'w2']));

    expect(service.playlists.first.name, 'Tech Interview');
    expect(service.playlists.first.wordIds, ['w1', 'w2']);
  });

  test('deletePlaylist removes playlist from storage', () async {
    final pl = await service.createPlaylist('Temp', ['w1']);
    expect(service.playlists.length, 1);

    await service.deletePlaylist(pl.id);
    expect(service.playlists, isEmpty);
  });
}
