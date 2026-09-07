import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/services/feedback_service.dart';

void main() {
  test('FeedbackService generates correct diagnostics report', () {
    final report = FeedbackService.generateReport(
      totalWords: 42,
      streakDays: 7,
    );

    expect(report, contains('App: Veea English v1.0.1'));
    expect(report, contains('Total Words: 42'));
    expect(report, contains('Streak: 7 days'));
    expect(report, contains('DIAGNOSTICS'));
    expect(report, contains('Timestamp:'));
  });
}
