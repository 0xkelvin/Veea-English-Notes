import 'dart:convert';
import 'package:http/http.dart' as http;

import '../data/cartridges_data.dart';
import '../models/part_of_speech.dart';
import '../models/vocabulary_word.dart';

/// Data class holding suggestion details for an English word.
class WordSuggestion {
  const WordSuggestion({
    required this.word,
    this.meaning,
    this.partOfSpeech,
    this.source,
  });

  final String word;
  final String? meaning;
  final PartOfSpeech? partOfSpeech;
  final String? source;
}

/// Offline-first & online-enriched vocabulary suggestion service.
///
/// Automatically provides Vietnamese meanings and grammatical Part of Speech
/// detection for ANY English word entered by the user.
class WordSuggestionService {
  static final Map<String, WordSuggestion> _cache = {};

  /// Fast synchronous lookup (cache -> user notes -> career cartridges -> offline dictionary -> heuristics).
  static WordSuggestion? suggestFast(
    String rawWord, {
    List<VocabularyWord>? userWords,
  }) {
    final word = rawWord.trim().toLowerCase();
    if (word.isEmpty || word.length < 2) return null;

    if (_cache.containsKey(word)) {
      return _cache[word];
    }

    // 1. User's previously saved notebook words
    if (userWords != null && userWords.isNotEmpty) {
      for (final uw in userWords) {
        if (uw.word.trim().toLowerCase() == word) {
          final res = WordSuggestion(
            word: word,
            meaning: uw.meaning.isNotEmpty ? uw.meaning : null,
            partOfSpeech: uw.partOfSpeech ?? detectPartOfSpeech(word),
            source: 'Previous note',
          );
          _cache[word] = res;
          return res;
        }
      }
    }

    // 2. Career Cartridge dictionary
    for (final cartridge in CartridgesData.allCartridges) {
      for (final cw in cartridge.words) {
        if (cw.word.trim().toLowerCase() == word) {
          final res = WordSuggestion(
            word: word,
            meaning: cw.meaning,
            partOfSpeech: cw.partOfSpeech,
            source: 'Tech Cartridge',
          );
          _cache[word] = res;
          return res;
        }
      }
    }

    // 3. Built-in comprehensive offline dictionary
    if (_offlineDict.containsKey(word)) {
      final entry = _offlineDict[word]!;
      final res = WordSuggestion(
        word: word,
        meaning: entry.meaning,
        partOfSpeech: entry.pos ?? detectPartOfSpeech(word),
        source: 'Dictionary',
      );
      _cache[word] = res;
      return res;
    }

    // 4. Fallback: grammatical suffix heuristic for Part of Speech
    final detectedPos = detectPartOfSpeech(word);
    if (detectedPos != null) {
      return WordSuggestion(
        word: word,
        meaning: null,
        partOfSpeech: detectedPos,
        source: 'Grammar heuristic',
      );
    }

    return null;
  }

  /// Full async suggestion: checks local sources, and if meaning is missing,
  /// fetches online translation with automatic POS detection.
  static Future<WordSuggestion?> suggest(
    String rawWord, {
    List<VocabularyWord>? userWords,
    http.Client? client,
  }) async {
    final clean = rawWord.trim().toLowerCase();
    if (clean.isEmpty || clean.length < 2) return null;

    final local = suggestFast(clean, userWords: userWords);
    if (local != null && local.meaning != null && local.meaning!.isNotEmpty) {
      return local;
    }

    // Online translation lookup
    try {
      final httpClient = client ?? http.Client();
      final uri = Uri.parse(
        'https://translate.googleapis.com/translate_a/single?client=gtx&sl=en&tl=vi&dt=t&dt=bd&q=${Uri.encodeComponent(clean)}',
      );
      final response = await httpClient.get(uri).timeout(
        const Duration(seconds: 3),
      );

      if (response.statusCode == 200) {
        final dynamic data = jsonDecode(response.body);
        String? primaryMeaning;
        PartOfSpeech? pos;

        // Parse translation segments
        if (data is List && data.isNotEmpty && data[0] is List) {
          final segments = data[0] as List;
          if (segments.isNotEmpty && segments[0] is List) {
            primaryMeaning = segments[0][0]?.toString().trim();
          }
        }

        // Parse dictionary / POS / alternatives
        if (data is List && data.length > 1 && data[1] is List) {
          final dictEntries = data[1] as List;
          if (dictEntries.isNotEmpty && dictEntries[0] is List) {
            final firstEntry = dictEntries[0] as List;
            final posStr = firstEntry[0]?.toString().toLowerCase();
            pos = _mapPos(posStr);

            // If alternative meanings exist, append top alternate
            if (firstEntry.length > 1 && firstEntry[1] is List) {
              final alts = (firstEntry[1] as List)
                  .map((e) => e.toString().trim())
                  .where((e) =>
                      e.isNotEmpty &&
                      e.toLowerCase() != primaryMeaning?.toLowerCase())
                  .toList();
              if (alts.isNotEmpty && primaryMeaning != null) {
                primaryMeaning = '$primaryMeaning, ${alts.first}';
              }
            }
          }
        }

        pos ??= local?.partOfSpeech ?? detectPartOfSpeech(clean);

        if (primaryMeaning != null && primaryMeaning.isNotEmpty) {
          final res = WordSuggestion(
            word: clean,
            meaning: primaryMeaning,
            partOfSpeech: pos,
            source: 'Dictionary',
          );
          _cache[clean] = res;
          return res;
        }
      }
    } catch (_) {
      // Fallback cleanly on network timeout
    }

    return local;
  }

  static PartOfSpeech? _mapPos(String? posStr) {
    if (posStr == null) return null;
    switch (posStr.toLowerCase()) {
      case 'noun':
        return PartOfSpeech.noun;
      case 'verb':
        return PartOfSpeech.verb;
      case 'adjective':
        return PartOfSpeech.adjective;
      case 'adverb':
        return PartOfSpeech.adverb;
      case 'phrase':
      case 'preposition':
      case 'conjunction':
        return PartOfSpeech.phrase;
      case 'idiom':
        return PartOfSpeech.idiom;
      default:
        return null;
    }
  }

  /// Heuristically deduces [PartOfSpeech] from English suffixes & patterns.
  static PartOfSpeech? detectPartOfSpeech(String word) {
    final clean = word.trim().toLowerCase();
    if (clean.contains(' ')) {
      // Phrases & Idioms
      if (clean.startsWith('in ') ||
          clean.startsWith('on ') ||
          clean.startsWith('at ') ||
          clean.startsWith('by ') ||
          clean.startsWith('for ') ||
          clean.startsWith('with ') ||
          clean.startsWith('as ') ||
          clean.startsWith('to ')) {
        return PartOfSpeech.phrase;
      }
      return PartOfSpeech.idiom;
    }

    // Adverbs (e.g. clearly, resiliently)
    if (clean.endsWith('ly') ||
        clean.endsWith('ward') ||
        clean.endsWith('wards') ||
        clean.endsWith('wise')) {
      return PartOfSpeech.adverb;
    }

    // Adjectives (e.g. resilient, scalable, beautiful, toxic, dangerous)
    if (clean.endsWith('able') ||
        clean.endsWith('ible') ||
        clean.endsWith('al') ||
        clean.endsWith('ful') ||
        clean.endsWith('ic') ||
        clean.endsWith('ive') ||
        clean.endsWith('ous') ||
        clean.endsWith('less') ||
        clean.endsWith('ish') ||
        clean.endsWith('ent') ||
        clean.endsWith('ant') ||
        clean.endsWith('ary')) {
      return PartOfSpeech.adjective;
    }

    // Nouns (e.g. solution, architecture, resilience, development, happiness)
    if (clean.endsWith('tion') ||
        clean.endsWith('sion') ||
        clean.endsWith('ment') ||
        clean.endsWith('ness') ||
        clean.endsWith('ity') ||
        clean.endsWith('ance') ||
        clean.endsWith('ence') ||
        clean.endsWith('ship') ||
        clean.endsWith('dom') ||
        clean.endsWith('ist') ||
        clean.endsWith('ism') ||
        clean.endsWith('er') ||
        clean.endsWith('or') ||
        clean.endsWith('ure')) {
      return PartOfSpeech.noun;
    }

    // Verbs (e.g. optimize, integrate, notify, broaden)
    if (clean.endsWith('ize') ||
        clean.endsWith('ise') ||
        clean.endsWith('ate') ||
        clean.endsWith('ify') ||
        clean.endsWith('en')) {
      return PartOfSpeech.verb;
    }

    return null;
  }

  static final Map<String, _DictEntry> _offlineDict = {
    // --- TECH & PRODUCT ESSENTIALS ---
    'solution': _DictEntry('giải pháp, cách giải quyết', PartOfSpeech.noun),
    'problem': _DictEntry('vấn đề, khó khăn cần giải quyết', PartOfSpeech.noun),
    'issue': _DictEntry('vấn đề, sự cố kỹ thuật', PartOfSpeech.noun),
    'system': _DictEntry('hệ thống', PartOfSpeech.noun),
    'feature': _DictEntry('tính năng, đặc điểm sản phẩm', PartOfSpeech.noun),
    'function': _DictEntry('chức năng, hàm xử lý', PartOfSpeech.noun),
    'method': _DictEntry('phương thức, cách thức thực hiện', PartOfSpeech.noun),
    'process': _DictEntry('quy trình, tiến trình xử lý', PartOfSpeech.noun),
    'variable': _DictEntry('biến số, tham số', PartOfSpeech.noun),
    'result': _DictEntry('kết quả', PartOfSpeech.noun),
    'device': _DictEntry('thiết bị', PartOfSpeech.noun),
    'network': _DictEntry('mạng lưới, kết nối mạng', PartOfSpeech.noun),
    'security': _DictEntry('bảo mật, an toàn thông tin', PartOfSpeech.noun),
    'performance': _DictEntry('hiệu năng, tốc độ xử lý', PartOfSpeech.noun),
    'experience': _DictEntry('trải nghiệm, kinh nghiệm', PartOfSpeech.noun),
    'knowledge': _DictEntry('kiến thức, sự hiểu biết', PartOfSpeech.noun),
    'opportunity': _DictEntry('cơ hội, thời cơ', PartOfSpeech.noun),
    'challenge': _DictEntry('thử thách, thách thức', PartOfSpeech.noun),
    'strategy': _DictEntry('chiến lược, đường lối', PartOfSpeech.noun),
    'analysis': _DictEntry('sự phân tích, nghiên cứu', PartOfSpeech.noun),
    'design': _DictEntry('thiết kế, kiến trúc giao diện', PartOfSpeech.noun),
    'development': _DictEntry('sự phát triển, lập trình', PartOfSpeech.noun),
    'requirement': _DictEntry('yêu cầu, điều kiện tiên quyết', PartOfSpeech.noun),
    'environment': _DictEntry('môi trường (máy chủ, hệ thống)', PartOfSpeech.noun),
    'management': _DictEntry('sự quản lý, ban quản lý', PartOfSpeech.noun),
    'resource': _DictEntry('tài nguyên, nguồn lực', PartOfSpeech.noun),
    'communication': _DictEntry('sự giao tiếp, trao đổi thông tin', PartOfSpeech.noun),
    'interaction': _DictEntry('sự tương tác qua lại', PartOfSpeech.noun),
    'interface': _DictEntry('giao diện người dùng hoặc phần cứng', PartOfSpeech.noun),
    'component': _DictEntry('thành phần, khối cấu trúc', PartOfSpeech.noun),
    'framework': _DictEntry('bộ khung phần mềm, cấu trúc nền', PartOfSpeech.noun),
    'library': _DictEntry('thư viện mã nguồn', PartOfSpeech.noun),
    'database': _DictEntry('cơ sở dữ liệu', PartOfSpeech.noun),
    'service': _DictEntry('dịch vụ', PartOfSpeech.noun),
    'server': _DictEntry('máy chủ', PartOfSpeech.noun),
    'client': _DictEntry('máy khách, người dùng', PartOfSpeech.noun),
    'request': _DictEntry('yêu cầu, lời đề nghị', PartOfSpeech.noun),
    'response': _DictEntry('phản hồi, kết quả trả về', PartOfSpeech.noun),
    'success': _DictEntry('sự thành công', PartOfSpeech.noun),
    'failure': _DictEntry('sự thất bại, sự cố', PartOfSpeech.noun),
    'error': _DictEntry('lỗi phần mềm, sai sót', PartOfSpeech.noun),
    'warning': _DictEntry('cảnh báo', PartOfSpeech.noun),
    'information': _DictEntry('thông tin, dữ liệu', PartOfSpeech.noun),
    'message': _DictEntry('tin nhắn, thông điệp', PartOfSpeech.noun),
    'status': _DictEntry('trạng thái, tình trạng hiện tại', PartOfSpeech.noun),
    'action': _DictEntry('hành động, tác vụ', PartOfSpeech.noun),
    'event': _DictEntry('sự kiện, biến cố', PartOfSpeech.noun),
    'condition': _DictEntry('điều kiện, trạng thái', PartOfSpeech.noun),
    'decision': _DictEntry('quyết định', PartOfSpeech.noun),
    'operation': _DictEntry('hoạt động, vận hành', PartOfSpeech.noun),
    'execution': _DictEntry('sự thực thi câu lệnh hoặc chương trình', PartOfSpeech.noun),
    'implementation': _DictEntry('sự triển khai, hiện thực hóa', PartOfSpeech.noun),
    'configuration': _DictEntry('cấu hình, thiết lập hệ thống', PartOfSpeech.noun),
    'integration': _DictEntry('sự tích hợp hệ thống', PartOfSpeech.noun),
    'maintenance': _DictEntry('sự bảo trì, bảo dưỡng', PartOfSpeech.noun),
    'update': _DictEntry('cập nhật, làm mới', PartOfSpeech.verb),
    'upgrade': _DictEntry('nâng cấp phiên bản', PartOfSpeech.verb),
    'create': _DictEntry('tạo mới, sáng tạo', PartOfSpeech.verb),
    'delete': _DictEntry('xóa bỏ', PartOfSpeech.verb),
    'modify': _DictEntry('chỉnh sửa, biến đổi', PartOfSpeech.verb),
    'execute': _DictEntry('thực thi, chạy mã', PartOfSpeech.verb),
    'implement': _DictEntry('triển khai, hiện thực hóa', PartOfSpeech.verb),
    'configure': _DictEntry('cấu hình, cài đặt tham số', PartOfSpeech.verb),
    'integrate': _DictEntry('tích hợp, gắn kết', PartOfSpeech.verb),
    'connect': _DictEntry('kết nối', PartOfSpeech.verb),
    'disconnect': _DictEntry('ngắt kết nối', PartOfSpeech.verb),
    'support': _DictEntry('hỗ trợ, tương thích', PartOfSpeech.verb),
    'maintain': _DictEntry('duy trì, gìn giữ', PartOfSpeech.verb),
    'improve': _DictEntry('cải thiện, nâng cấp chất lượng', PartOfSpeech.verb),
    'enhance': _DictEntry('tăng cường, trau chuốt', PartOfSpeech.verb),
    'develop': _DictEntry('phát triển, xây dựng', PartOfSpeech.verb),
    'resolve': _DictEntry('giải quyết dứt điểm', PartOfSpeech.verb),
    'manage': _DictEntry('quản lý, điều hành', PartOfSpeech.verb),
    'control': _DictEntry('kiểm soát, điều khiển', PartOfSpeech.verb),
    'monitor': _DictEntry('giám sát, theo dõi thời gian thực', PartOfSpeech.verb),
    'evaluate': _DictEntry('đánh giá, thẩm định', PartOfSpeech.verb),
    'analyze': _DictEntry('phân tích chi tiết', PartOfSpeech.verb),
    'identify': _DictEntry('nhận diện, phát hiện', PartOfSpeech.verb),
    'verify': _DictEntry('kiểm tra, chứng thực', PartOfSpeech.verb),
    'validate': _DictEntry('xác thực tính hợp lệ', PartOfSpeech.verb),
    'generate': _DictEntry('sinh ra, tạo ra tự động', PartOfSpeech.verb),
    'produce': _DictEntry('sản xuất, tạo thành phẩm', PartOfSpeech.verb),
    'deliver': _DictEntry('bàn giao, phân phối', PartOfSpeech.verb),
    'provide': _DictEntry('cung cấp, mang lại', PartOfSpeech.verb),
    'receive': _DictEntry('tiếp nhận, nhận được', PartOfSpeech.verb),
    'send': _DictEntry('gửi đi', PartOfSpeech.verb),
    'store': _DictEntry('lưu trữ dữ liệu', PartOfSpeech.verb),
    'retrieve': _DictEntry('truy xuất, lấy dữ liệu', PartOfSpeech.verb),
    'calculate': _DictEntry('tính toán số liệu', PartOfSpeech.verb),
    'estimate': _DictEntry('ước lượng, phỏng đoán', PartOfSpeech.verb),
    'predict': _DictEntry('tiên đoán, dự đoán xu hướng', PartOfSpeech.verb),
    'prevent': _DictEntry('ngăn chặn, phòng tránh', PartOfSpeech.verb),
    'protect': _DictEntry('bảo vệ, che chắn', PartOfSpeech.verb),
    'secure': _DictEntry('bảo đảm an toàn, siết chặt', PartOfSpeech.verb),
    'enable': _DictEntry('kích hoạt, bật tính năng', PartOfSpeech.verb),
    'disable': _DictEntry('vô hiệu hóa, tắt tính năng', PartOfSpeech.verb),

    // --- HIGH-FREQUENCY ESSENTIALS ---
    'resilient': _DictEntry('kiên cường, bền bỉ (khả năng phục hồi nhanh)', PartOfSpeech.adjective),
    'resilience': _DictEntry('sự kiên cường, khả năng hồi phục', PartOfSpeech.noun),
    'tenacious': _DictEntry('kiên trì, dai dẳng, bám sát mục tiêu', PartOfSpeech.adjective),
    'tenacity': _DictEntry('sự bền bỉ, tính kiên cường', PartOfSpeech.noun),
    'eloquent': _DictEntry('hùng biện, lưu loát, giàu sức thuyết phục', PartOfSpeech.adjective),
    'eloquence': _DictEntry('tài hùng biện, sự lưu loát', PartOfSpeech.noun),
    'serendipity': _DictEntry('sự tình cờ may mắn, duyên may', PartOfSpeech.noun),
    'serendipitous': _DictEntry('tình cờ may mắn', PartOfSpeech.adjective),
    'quintessential': _DictEntry('tinh túy, hoàn hảo, điển hình nhất', PartOfSpeech.adjective),
    'meticulous': _DictEntry('tỉ mỉ, cẩn thận, chăm chút từng chi tiết', PartOfSpeech.adjective),
    'inquisitive': _DictEntry('tò mò, ham học hỏi, thích tìm hiểu', PartOfSpeech.adjective),
    'pragmatic': _DictEntry('thực dụng, thực tế, coi trọng hiệu quả', PartOfSpeech.adjective),
    'pragmatism': _DictEntry('chủ nghĩa thực tế', PartOfSpeech.noun),
    'lucid': _DictEntry('rõ ràng, minh bạch, dễ hiểu', PartOfSpeech.adjective),
    'ambiguous': _DictEntry('mơ hồ, nước đôi, không rõ ràng', PartOfSpeech.adjective),
    'ambiguity': _DictEntry('sự mơ hồ, tính không rõ ràng', PartOfSpeech.noun),
    'ubiquitous': _DictEntry('phổ biến khắp nơi, đâu đâu cũng thấy', PartOfSpeech.adjective),
    'proactive': _DictEntry('chủ động, tiên phong giải quyết vấn đề', PartOfSpeech.adjective),
    'paradigm': _DictEntry('mô hình, khuôn mẫu tư duy', PartOfSpeech.noun),
    'benchmark': _DictEntry('tiêu chuẩn đối sánh, mốc chuẩn', PartOfSpeech.noun),
    'leverage': _DictEntry('tận dụng, khai thác đòn bẩy', PartOfSpeech.verb),
    'streamline': _DictEntry('tinh gọn, tối ưu hoá quy trình', PartOfSpeech.verb),
    'holistic': _DictEntry('toàn diện, tổng thể', PartOfSpeech.adjective),
    'catalyst': _DictEntry('chất xúc tác, nhân tố thúc đẩy', PartOfSpeech.noun),
    'empathy': _DictEntry('sự thấu cảm, đồng cảm sâu sắc', PartOfSpeech.noun),
    'synergy': _DictEntry('sự cộng hưởng, sức mạnh tổng hợp', PartOfSpeech.noun),
    'scalable': _DictEntry('có khả năng mở rộng', PartOfSpeech.adjective),
    'scalability': _DictEntry('khả năng mở rộng quy mô', PartOfSpeech.noun),
    'robust': _DictEntry('mạnh mẽ, vững chắc, tin cậy', PartOfSpeech.adjective),
    'robustness': _DictEntry('tính vững chắc, độ tin cậy', PartOfSpeech.noun),
    'optimize': _DictEntry('tối ưu hoá', PartOfSpeech.verb),
    'optimization': _DictEntry('sự tối ưu hoá', PartOfSpeech.noun),
    'refactor': _DictEntry('tái cấu trúc mã nguồn (không đổi tính năng)', PartOfSpeech.verb),
    'mitigate': _DictEntry('giảm thiểu, xoa dịu rủi ro', PartOfSpeech.verb),
    'mitigation': _DictEntry('sự giảm thiểu rủi ro', PartOfSpeech.noun),
    'bottleneck': _DictEntry('điểm nghẽn, nút cổ chai', PartOfSpeech.noun),
    'bandwidth': _DictEntry('băng thông, năng lực xử lý công việc', PartOfSpeech.noun),
    'latency': _DictEntry('độ trễ thời gian phản hồi', PartOfSpeech.noun),
    'throughput': _DictEntry('thông lượng, lượng xử lý trên đơn vị thời gian', PartOfSpeech.noun),
    'concurrency': _DictEntry('tính đồng thời, đa nhiệm', PartOfSpeech.noun),
    'synchronous': _DictEntry('đồng bộ', PartOfSpeech.adjective),
    'asynchronous': _DictEntry('bất đồng bộ', PartOfSpeech.adjective),
    'immutable': _DictEntry('bất biến, không thể sửa đổi sau khi tạo', PartOfSpeech.adjective),
    'deprecate': _DictEntry('ngừng hỗ trợ, loại bỏ dần', PartOfSpeech.verb),
    'deprecation': _DictEntry('sự ngừng hỗ trợ tính năng cũ', PartOfSpeech.noun),
    'deterministic': _DictEntry('định tiền, xác định rõ ràng không ngẫu nhiên', PartOfSpeech.adjective),
    'heuristic': _DictEntry('phương pháp suy nghiệm, phỏng đoán kinh nghiệm', PartOfSpeech.noun),
    'redundancy': _DictEntry('sự dự phòng, tính dư thừa an toàn', PartOfSpeech.noun),
    'redundant': _DictEntry('dư thừa, có tính dự phòng', PartOfSpeech.adjective),
    'orchestration': _DictEntry('sự điều phối các dịch vụ tự động', PartOfSpeech.noun),
    'seamless': _DictEntry('liền mạch, mượt mà, không gián đoạn', PartOfSpeech.adjective),
    'seamlessly': _DictEntry('một cách liền mạch, trơn tru', PartOfSpeech.adverb),
    'deadlock': _DictEntry('bế tắc, khóa chết lẫn nhau', PartOfSpeech.noun),
    'vulnerability': _DictEntry('lỗ hổng bảo mật, điểm yếu', PartOfSpeech.noun),
    'vulnerable': _DictEntry('dễ bị tổn thương, dễ bị tấn công', PartOfSpeech.adjective),
    'fallback': _DictEntry('phương án dự phòng khi thất bại', PartOfSpeech.noun),
    'scaffold': _DictEntry('khung sườn dựng sẵn, giàn giáo', PartOfSpeech.noun),
    'tradeoff': _DictEntry('sự đánh đổi giữa hai lựa chọn', PartOfSpeech.noun),
    'diligence': _DictEntry('sự siêng năng, chu toàn, cẩn trọng', PartOfSpeech.noun),
    'diligent': _DictEntry('chăm chỉ, cần mẫn, chu đáo', PartOfSpeech.adjective),
    'adversity': _DictEntry('nghịch cảnh, hoàn cảnh khó khăn', PartOfSpeech.noun),
    'compromise': _DictEntry('sự thỏa hiệp, làm tổn hại đến', PartOfSpeech.verb),
    'feasible': _DictEntry('khả thi, có thể thực hiện được', PartOfSpeech.adjective),
    'feasibility': _DictEntry('tính khả thi', PartOfSpeech.noun),
    'comprehensive': _DictEntry('toàn diện, bao quát mọi mặt', PartOfSpeech.adjective),
    'comprehend': _DictEntry('thấu hiểu, lĩnh hội', PartOfSpeech.verb),
    'ephemeral': _DictEntry('phù du, ngắn ngủi, tạm thời', PartOfSpeech.adjective),
    'transient': _DictEntry('tạm thời, thoáng qua', PartOfSpeech.adjective),
    'obsolete': _DictEntry('lỗi thời, không còn được dùng', PartOfSpeech.adjective),
    'prolific': _DictEntry('năng suất cao, sáng tác nhiều', PartOfSpeech.adjective),
    'innovative': _DictEntry('mang tính đổi mới, sáng tạo', PartOfSpeech.adjective),
    'innovate': _DictEntry('đổi mới, cách tân', PartOfSpeech.verb),
    'innovation': _DictEntry('sự đổi mới, sáng kiến', PartOfSpeech.noun),
    'collaborate': _DictEntry('hợp tác, phối hợp làm việc', PartOfSpeech.verb),
    'collaboration': _DictEntry('sự hợp tác làm việc nhóm', PartOfSpeech.noun),
    'authentic': _DictEntry('đích thực, chân thực, nguyên bản', PartOfSpeech.adjective),
    'authenticity': _DictEntry('tính chân thực, tính xác thực', PartOfSpeech.noun),
    'authenticate': _DictEntry('xác thực danh tính', PartOfSpeech.verb),
    'authorize': _DictEntry('cấp quyền, ủy quyền', PartOfSpeech.verb),
    'authorization': _DictEntry('sự phân quyền, cấp phép', PartOfSpeech.noun),

    // --- DAILY & COMMON CONVERSATION ---
    'acquire': _DictEntry('tiếp thu, thu nhận được (kỹ năng, kiến thức)', PartOfSpeech.verb),
    'accomplish': _DictEntry('hoàn thành xuất sắc, đạt được', PartOfSpeech.verb),
    'accurate': _DictEntry('chính xác, đúng đắn', PartOfSpeech.adjective),
    'adequate': _DictEntry('đầy đủ, thỏa đáng, đáp ứng yêu cầu', PartOfSpeech.adjective),
    'anticipate': _DictEntry('dự đoán trước, lường trước', PartOfSpeech.verb),
    'apparent': _DictEntry('rõ ràng, hiển nhiên', PartOfSpeech.adjective),
    'appreciate': _DictEntry('trân trọng, cảm kích, đánh giá cao', PartOfSpeech.verb),
    'approach': _DictEntry('cách tiếp cận, phương pháp giải quyết', PartOfSpeech.noun),
    'appropriate': _DictEntry('thích hợp, phù hợp', PartOfSpeech.adjective),
    'aspire': _DictEntry('khao khát, hướng tới mục tiêu', PartOfSpeech.verb),
    'aspiration': _DictEntry('nguyện vọng, hoài bão', PartOfSpeech.noun),
    'assume': _DictEntry('giả định, cho rằng', PartOfSpeech.verb),
    'clarify': _DictEntry('làm sáng tỏ, giải thích rõ ràng', PartOfSpeech.verb),
    'clarity': _DictEntry('sự rõ ràng, tính mạch lạc', PartOfSpeech.noun),
    'coherent': _DictEntry('mạch lạc, chặt chẽ, gắn kết', PartOfSpeech.adjective),
    'cohesive': _DictEntry('gắn kết, có tính liên kết cao', PartOfSpeech.adjective),
    'consistent': _DictEntry('nhất quán, kiên định trước sau như một', PartOfSpeech.adjective),
    'consistency': _DictEntry('sự nhất quán', PartOfSpeech.noun),
    'crucial': _DictEntry('cốt yếu, mang tính quyết định', PartOfSpeech.adjective),
    'dedicate': _DictEntry('cống hiến, dành riêng cho', PartOfSpeech.verb),
    'deliberate': _DictEntry('có chủ đích, thận trọng, cân nhắc kỹ', PartOfSpeech.adjective),
    'efficient': _DictEntry('hiệu quả, tiết kiệm thời gian công sức', PartOfSpeech.adjective),
    'effective': _DictEntry('hiệu nghiệm, đạt kết quả mong muốn', PartOfSpeech.adjective),
    'essential': _DictEntry('thiết yếu, không thể thiếu', PartOfSpeech.adjective),
    'fundamental': _DictEntry('cơ bản, nền tảng, gốc rễ', PartOfSpeech.adjective),
    'inevitable': _DictEntry('không thể tránh khỏi, tất yếu', PartOfSpeech.adjective),
    'initiative': _DictEntry('sáng kiến, tính chủ động', PartOfSpeech.noun),
    'insight': _DictEntry('sự thấu hiểu sâu sắc, góc nhìn đắt giá', PartOfSpeech.noun),
    'insightful': _DictEntry('sâu sắc, mang lại nhiều góc nhìn hay', PartOfSpeech.adjective),
    'perspective': _DictEntry('góc nhìn, quan điểm cá nhân', PartOfSpeech.noun),
    'priority': _DictEntry('sự ưu tiên, thứ tự quan trọng', PartOfSpeech.noun),
    'prioritize': _DictEntry('ưu tiên việc quan trọng trước', PartOfSpeech.verb),
    'profound': _DictEntry('sâu sắc, uyên thâm', PartOfSpeech.adjective),
    'relentless': _DictEntry('không ngừng nghỉ, kiên quyết tới cùng', PartOfSpeech.adjective),
    'substantial': _DictEntry('đáng kể, có giá trị lớn', PartOfSpeech.adjective),
    'subtle': _DictEntry('tinh tế, phảng phất, khó nhận thấy', PartOfSpeech.adjective),
    'sustainable': _DictEntry('bền vững, duy trì lâu dài', PartOfSpeech.adjective),
    'tangible': _DictEntry('hữu hình, có thể thấy rõ ràng', PartOfSpeech.adjective),
    'transparent': _DictEntry('minh bạch, trong suốt, rõ ràng', PartOfSpeech.adjective),
    'transparency': _DictEntry('sự minh bạch', PartOfSpeech.noun),
    'unprecedented': _DictEntry('chưa từng có tiền lệ', PartOfSpeech.adjective),
    'vital': _DictEntry('sống còn, cực kỳ quan trọng', PartOfSpeech.adjective),

    // --- IDIOMS & PHRASES ---
    'touch base': _DictEntry('liên lạc, trao đổi ngắn gọn để cập nhật tình hình', PartOfSpeech.phrase),
    'in a nutshell': _DictEntry('tóm lại một cách ngắn gọn', PartOfSpeech.phrase),
    'on the same page': _DictEntry('cùng chung quan điểm, đồng thuận hiểu ý nhau', PartOfSpeech.idiom),
    'piece of cake': _DictEntry('dễ như ăn kẹo, việc cực kỳ dễ dàng', PartOfSpeech.idiom),
    'call it a day': _DictEntry('kết thúc công việc hôm nay, nghỉ ngơi', PartOfSpeech.idiom),
    'cut corners': _DictEntry('đốt cháy giai đoạn, làm cẩu thả để tiết kiệm', PartOfSpeech.idiom),
    'bite the bullet': _DictEntry('ngậm đắng nuốt cay, can đảm đối mặt việc khó', PartOfSpeech.idiom),
    'break a leg': _DictEntry('chúc may mắn (trong buổi biểu diễn / phỏng vấn)', PartOfSpeech.idiom),
    'see eye to eye': _DictEntry('đồng lòng, hoàn toàn đồng tình với nhau', PartOfSpeech.idiom),
    'at the end of the day': _DictEntry('suy cho cùng, xét đến cùng', PartOfSpeech.phrase),
    'back to the drawing board': _DictEntry('làm lại từ đầu sau khi thất bại', PartOfSpeech.idiom),
    'hit the sack': _DictEntry('đi ngủ', PartOfSpeech.idiom),
    'under the weather': _DictEntry('cảm thấy mệt mỏi, không được khỏe', PartOfSpeech.idiom),
  };
}

class _DictEntry {
  const _DictEntry(this.meaning, this.pos);
  final String meaning;
  final PartOfSpeech? pos;
}
