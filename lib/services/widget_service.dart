import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import '../models/vocabulary_word.dart';

/// Manages data syncing for native iOS WidgetKit and Android AppWidget.
class WidgetService {
  WidgetService._();

  static const String appGroupId = 'group.com.veea.veea_english_app';
  static const String iOSWidgetName = 'WordOfDayWidget';
  static const String androidWidgetName = 'WordOfDayWidgetProvider';

  /// Updates native Home Screen & Lock Screen widgets with the Word of the Day.
  static Future<void> updateWidgetData({
    required VocabularyWord word,
    required int streakDays,
  }) async {
    if (kIsWeb) return;

    try {
      await HomeWidget.setAppGroupId(appGroupId);

      await Future.wait([
        HomeWidget.saveWidgetData<String>('widget_word', word.word),
        HomeWidget.saveWidgetData<String>(
          'widget_ipa',
          word.pronunciation ?? '',
        ),
        HomeWidget.saveWidgetData<String>(
          'widget_pos',
          word.partOfSpeech?.short ?? '',
        ),
        HomeWidget.saveWidgetData<String>('widget_meaning', word.meaning),
        HomeWidget.saveWidgetData<String>(
          'widget_example',
          word.examples.isNotEmpty ? word.examples.first : '',
        ),
        HomeWidget.saveWidgetData<int>('widget_streak', streakDays),
      ]);

      await HomeWidget.updateWidget(
        iOSName: iOSWidgetName,
        androidName: androidWidgetName,
      );
    } catch (error, stack) {
      debugPrint('Could not update native widget data: $error\n$stack');
    }
  }

  /// Clears native widget data.
  static Future<void> clearWidgetData() async {
    if (kIsWeb) return;

    try {
      await HomeWidget.setAppGroupId(appGroupId);
      await Future.wait([
        HomeWidget.saveWidgetData<String>('widget_word', ''),
        HomeWidget.saveWidgetData<String>('widget_ipa', ''),
        HomeWidget.saveWidgetData<String>('widget_pos', ''),
        HomeWidget.saveWidgetData<String>('widget_meaning', ''),
        HomeWidget.saveWidgetData<String>('widget_example', ''),
        HomeWidget.saveWidgetData<int>('widget_streak', 0),
      ]);

      await HomeWidget.updateWidget(
        iOSName: iOSWidgetName,
        androidName: androidWidgetName,
      );
    } catch (error, stack) {
      debugPrint('Could not clear native widget data: $error\n$stack');
    }
  }
}
