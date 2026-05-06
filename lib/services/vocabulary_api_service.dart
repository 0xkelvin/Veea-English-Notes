import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/vocabulary_word.dart';

class VocabularyApiService {
  static const String _baseUrl = 'http://localhost:8386/api/v1';

  final http.Client _client;

  VocabularyApiService({http.Client? client}) : _client = client ?? http.Client();

  // ── Helpers ───────────────────────────────────────────────────────────────

  Map<String, String> _headers(String accessToken) => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      };

  Future<Map<String, dynamic>> _handleResponse(http.Response res) async {
    final body = json.decode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 200 && res.statusCode < 300) return body;
    final error = (body['error'] as Map<String, dynamic>?)?['message'] ?? 'Unknown error';
    throw Exception(error);
  }

  VocabularyWord _fromApiJson(Map<String, dynamic> j) {
    return VocabularyWord(
      id: j['id'] as String,
      word: j['word'] as String,
      vietnameseMeaning: j['vietnamese_meaning'] as String,
      phonetic: j['phonetic'] as String?,
      examples: (j['examples'] as List<dynamic>? ?? []).cast<String>(),
      date: j['date'] as String,
      createdAt: DateTime.parse(j['created_at'] as String),
      reviewCount: j['review_count'] as int? ?? 0,
      easeFactor: (j['ease_factor'] as num?)?.toDouble() ?? 2.5,
      intervalDays: j['interval_days'] as int? ?? 0,
      nextReviewDate: j['next_review_date'] as String?,
    );
  }

  // ── CRUD ──────────────────────────────────────────────────────────────────

  Future<List<VocabularyWord>> fetchAll(String accessToken) async {
    final res = await _client.get(
      Uri.parse('$_baseUrl/vocabulary'),
      headers: _headers(accessToken),
    );
    final body = await _handleResponse(res);
    final items = (body['data']['items'] as List<dynamic>);
    return items.map((e) => _fromApiJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<VocabularyWord>> fetchDue(String accessToken) async {
    final res = await _client.get(
      Uri.parse('$_baseUrl/vocabulary/due'),
      headers: _headers(accessToken),
    );
    final body = await _handleResponse(res);
    final items = (body['data']['items'] as List<dynamic>);
    return items.map((e) => _fromApiJson(e as Map<String, dynamic>)).toList();
  }

  Future<VocabularyWord> create({
    required String accessToken,
    required String word,
    required String vietnameseMeaning,
    String? phonetic,
    required List<String> examples,
    required String date,
  }) async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/vocabulary'),
      headers: _headers(accessToken),
      body: json.encode({
        'word': word,
        'vietnamese_meaning': vietnameseMeaning,
        if (phonetic != null && phonetic.isNotEmpty) 'phonetic': phonetic,
        'examples': examples,
        'date': date,
      }),
    );
    final body = await _handleResponse(res);
    return _fromApiJson(body['data'] as Map<String, dynamic>);
  }

  Future<VocabularyWord> update({
    required String accessToken,
    required String id,
    String? word,
    String? vietnameseMeaning,
    String? phonetic,
    List<String>? examples,
    String? date,
  }) async {
    final payload = <String, dynamic>{};
    if (word != null) payload['word'] = word;
    if (vietnameseMeaning != null) payload['vietnamese_meaning'] = vietnameseMeaning;
    if (phonetic != null) payload['phonetic'] = phonetic;
    if (examples != null) payload['examples'] = examples;
    if (date != null) payload['date'] = date;

    final res = await _client.put(
      Uri.parse('$_baseUrl/vocabulary/$id'),
      headers: _headers(accessToken),
      body: json.encode(payload),
    );
    final body = await _handleResponse(res);
    return _fromApiJson(body['data'] as Map<String, dynamic>);
  }

  Future<void> delete({required String accessToken, required String id}) async {
    final res = await _client.delete(
      Uri.parse('$_baseUrl/vocabulary/$id'),
      headers: _headers(accessToken),
    );
    if (res.statusCode != 204) {
      final body = json.decode(res.body) as Map<String, dynamic>;
      final error = (body['error'] as Map<String, dynamic>?)?['message'] ?? 'Delete failed';
      throw Exception(error);
    }
  }

  Future<VocabularyWord> applyReview({
    required String accessToken,
    required String id,
    required int quality,
  }) async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/vocabulary/$id/review'),
      headers: _headers(accessToken),
      body: json.encode({'quality': quality}),
    );
    final body = await _handleResponse(res);
    return _fromApiJson(body['data'] as Map<String, dynamic>);
  }

  Future<AiSuggestion> suggest({
    required String accessToken,
    required String word,
  }) async {
    final res = await _client.post(
      Uri.parse('$_baseUrl/vocabulary/suggest'),
      headers: _headers(accessToken),
      body: json.encode({'word': word}),
    );
    final body = await _handleResponse(res);
    final data = body['data'] as Map<String, dynamic>;
    return AiSuggestion(
      vietnameseMeaning: data['vietnamese_meaning'] as String,
      phonetic: data['phonetic'] as String,
      examples: (data['examples'] as List<dynamic>).cast<String>(),
    );
  }
}

class AiSuggestion {
  final String vietnameseMeaning;
  final String phonetic;
  final List<String> examples;

  const AiSuggestion({
    required this.vietnameseMeaning,
    required this.phonetic,
    required this.examples,
  });
}
