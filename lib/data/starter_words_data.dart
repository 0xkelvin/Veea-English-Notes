import 'package:uuid/uuid.dart';

import '../models/part_of_speech.dart';
import '../models/vocabulary_word.dart';

/// Curated starter words designed to give new users an immediate 1-tap jumpstart.
///
/// These 5 high-utility words immediately unlock:
/// - 4 Arcade games (Vocab Invaders, Snake, Word Rush, Pixel Typer)
/// - Commute audio cassette playback
/// - Spaced Repetition (SM-2) review queue
/// - Home screen widget
class StarterWordsData {
  const StarterWordsData._();

  static const List<StarterWordDefinition> definitions = [
    StarterWordDefinition(
      word: 'resilient',
      pronunciation: '/rɪˈzɪl.jənt/',
      partOfSpeech: PartOfSpeech.adjective,
      meaning:
          'Kiên cường, có khả năng phục hồi nhanh chóng sau khó khăn hoặc nghịch cảnh.',
      example:
          'The engineering team remained resilient despite the tight deadline and system outage.',
      tags: ['starter', 'mindset'],
    ),
    StarterWordDefinition(
      word: 'bottleneck',
      pronunciation: '/ˈbɑː.t̬əl.nek/',
      partOfSpeech: PartOfSpeech.noun,
      meaning: 'Điểm nghẽn, nút thắt cổ chai làm chậm trễ toàn bộ tiến trình.',
      example:
          'Database query execution time is currently the main bottleneck in our system.',
      tags: ['starter', 'system'],
    ),
    StarterWordDefinition(
      word: 'trade-off',
      pronunciation: '/ˈtreɪd.ɑːf/',
      partOfSpeech: PartOfSpeech.noun,
      meaning: 'Sự đánh đổi, sự cân nhắc thỏa hiệp giữa hai yếu tố đối lập.',
      example:
          'There is always a trade-off between development speed and code quality.',
      tags: ['starter', 'strategy'],
    ),
    StarterWordDefinition(
      word: 'serendipity',
      pronunciation: '/ˌser.ənˈdɪp.ə.t̬i/',
      partOfSpeech: PartOfSpeech.noun,
      meaning: 'Sự tình cờ may mắn, cơ duyên bất ngờ tìm thấy điều tốt đẹp.',
      example: 'Finding this vintage book in the attic was pure serendipity.',
      tags: ['starter', 'life'],
    ),
    StarterWordDefinition(
      word: 'pragmatic',
      pronunciation: '/præɡˈmæt̬.ɪk/',
      partOfSpeech: PartOfSpeech.adjective,
      meaning:
          'Thực tế, thực dụng, giải quyết vấn đề dựa trên điều kiện thực tiễn.',
      example:
          'We need to take a pragmatic approach to meet the release deadline.',
      tags: ['starter', 'work'],
    ),
  ];

  /// Creates a list of [VocabularyWord] ready to be inserted into the database.
  static List<VocabularyWord> createStarterWords({
    required String date,
    required DateTime now,
    Uuid uuid = const Uuid(),
  }) {
    return definitions.map((def) {
      return VocabularyWord.create(
        id: uuid.v4(),
        word: def.word,
        meaning: def.meaning,
        date: date,
        now: now,
        pronunciation: def.pronunciation,
        partOfSpeech: def.partOfSpeech,
        source: 'Starter Pack',
        examples: [def.example],
        tags: def.tags,
      );
    }).toList();
  }
}

class StarterWordDefinition {
  const StarterWordDefinition({
    required this.word,
    required this.pronunciation,
    required this.partOfSpeech,
    required this.meaning,
    required this.example,
    required this.tags,
  });

  final String word;
  final String pronunciation;
  final PartOfSpeech partOfSpeech;
  final String meaning;
  final String example;
  final List<String> tags;
}
