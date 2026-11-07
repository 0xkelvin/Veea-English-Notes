import 'dart:convert';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';
import '../data/remote/api_client.dart';

class FeedbackReport {
  FeedbackReport(this.data);
  final Map<String, Object?> data;
  String get id => data['id']! as String;
  String get kind => data['kind']! as String;
  String get message => data['message']! as String;
  String get status => data['status']! as String;
  String? get reply => data['team_reply'] as String?;
  String? get error => data['last_error'] as String?;
  bool get queued => status == 'queued';
  String get statusLabel => switch (status) {
    'received' => 'Received',
    'reviewing' => 'Under review',
    'planned' => 'Planned',
    'completed' => 'Completed',
    'closed' => 'Closed',
    _ => 'Waiting to send',
  };
  Map<String, Object?> get payload => {
    'id': id,
    'kind': kind,
    'message': message,
    'contact': data['contact'],
    'diagnostics': jsonDecode(data['diagnostics']! as String),
    'screenshot_base64': data['screenshot_base64'],
  };
}

/// Each notebook has a separate, random receipt key. It is never a phone number
/// or account token and never included in diagnostics or the on-device outbox.
class FeedbackReceiptStore {
  const FeedbackReceiptStore([this.storage = const FlutterSecureStorage()]);
  final FlutterSecureStorage storage;
  Future<String> keyFor(String owner) async {
    final slot = 'feedback.receipt.$owner';
    final saved = await storage.read(key: slot);
    if (saved != null) return saved;
    final random = Random.secure();
    final key = base64UrlEncode(
      List.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    await storage.write(key: slot, value: key);
    return key;
  }
}

class FeedbackRepository {
  FeedbackRepository(
    this.database,
    this.client, {
    FeedbackReceiptStore? receipts,
  }) : receipts = receipts ?? const FeedbackReceiptStore();
  final Database database;
  final ApiClient client;
  final FeedbackReceiptStore receipts;
  Future<List<FeedbackReport>> list(String owner) async =>
      (await database.query(
        'feedback_outbox',
        where: 'owner_id = ?',
        whereArgs: [owner],
        orderBy: 'created_at DESC',
      )).map(FeedbackReport.new).toList();
  Future<void> enqueue(Map<String, Object?> row) =>
      database.insert('feedback_outbox', row).then((_) {});
  Future<void> discard(String owner, String id) => database
      .delete(
        'feedback_outbox',
        where: "id = ? AND owner_id = ? AND status = 'queued'",
        whereArgs: [id, owner],
      )
      .then((_) {});
  Future<void> forgetOwner(String owner) => database
      .delete('feedback_outbox', where: 'owner_id = ?', whereArgs: [owner])
      .then((_) {});
  Future<Map<String, Object?>> config() =>
      client.get('/client/config', authenticated: false);
  Future<void> deliver(String owner) async {
    final key = await receipts.keyFor(owner);
    final headers = {'x-feedback-key': key};
    for (final report in await list(owner)) {
      if (!report.queued) continue;
      try {
        final result = await client.post(
          '/feedback',
          body: report.payload,
          authenticated: false,
          extraHeaders: headers,
        );
        final status = result['status'] as String?;
        if (result['id'] != report.id ||
            ![
              'received',
              'reviewing',
              'planned',
              'completed',
              'closed',
            ].contains(status)) {
          throw const ApiException(
            'Could not confirm delivery. Please try again.',
          );
        }
        // Drop the private attachment from the local outbox after acknowledgement.
        await database.update(
          'feedback_outbox',
          {
            'status': status,
            'team_reply': result['team_reply'],
            'last_error': null,
            'screenshot_base64': null,
          },
          where: 'id = ? AND owner_id = ?',
          whereArgs: [report.id, owner],
        );
      } catch (_) {
        await database.update(
          'feedback_outbox',
          {
            'last_error':
                'Could not send yet. Your feedback is saved on this device.',
          },
          where: 'id = ? AND owner_id = ?',
          whereArgs: [report.id, owner],
        );
        rethrow;
      }
    }
    final result = await client.get(
      '/feedback',
      authenticated: false,
      extraHeaders: headers,
    );
    for (final report
        in (result['reports'] as List? ?? const []).whereType<Map>()) {
      if (![
        'received',
        'reviewing',
        'planned',
        'completed',
        'closed',
      ].contains(report['status'])) {
        continue;
      }
      await database.update(
        'feedback_outbox',
        {
          'status': report['status'],
          'team_reply': report['team_reply'],
          'last_error': null,
        },
        where: 'id = ? AND owner_id = ?',
        whereArgs: [report['id'], owner],
      );
    }
  }
}
