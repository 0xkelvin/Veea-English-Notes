import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import '../models/vocabulary_word.dart';
import '../providers/widget_provider.dart';
import 'tts_service.dart';

/// Manages data syncing for native iOS WidgetKit and Android AppWidget.
class WidgetService {
  WidgetService._();

  static const String appGroupId = 'group.com.veea.veea_english_app';
  static const String iOSWidgetName = 'WordOfDayWidget';
  static const String androidWidgetName = 'WordOfDayWidgetProvider';

  /// Sets widget rotation interval preference in native shared storage.
  static Future<void> setRotationInterval(int intervalMinutes) async {
    if (kIsWeb) return;
    try {
      await HomeWidget.setAppGroupId(appGroupId);
      await HomeWidget.saveWidgetData<int>(
        'widget_rotation_interval_minutes',
        intervalMinutes,
      );
      await HomeWidget.updateWidget(
        iOSName: iOSWidgetName,
        androidName: androidWidgetName,
      );
    } catch (error, stack) {
      debugPrint('Could not set rotation interval: $error\n$stack');
    }
  }

  /// Rotates to the next word in the list and updates the native widget.
  static Future<void> rotateToNextWord() async {
    if (kIsWeb) return;
    try {
      await HomeWidget.setAppGroupId(appGroupId);
      final jsonString =
          await HomeWidget.getWidgetData<String>('widget_words_json');
      if (jsonString == null || jsonString.isEmpty) return;

      final dynamic decoded = jsonDecode(jsonString);
      if (decoded is! List || decoded.isEmpty) return;

      final currentIndex =
          (await HomeWidget.getWidgetData<int>('widget_rotation_index')) ?? 0;
      final nextIndex = (currentIndex + 1) % decoded.length;
      final currentItem = decoded[nextIndex] as Map<String, dynamic>;

      await Future.wait([
        HomeWidget.saveWidgetData<int>('widget_rotation_index', nextIndex),
        HomeWidget.saveWidgetData<String>(
          'widget_word',
          currentItem['word']?.toString() ?? '',
        ),
        HomeWidget.saveWidgetData<String>(
          'widget_ipa',
          currentItem['ipa']?.toString() ?? '',
        ),
        HomeWidget.saveWidgetData<String>(
          'widget_pos',
          currentItem['pos']?.toString() ?? '',
        ),
        HomeWidget.saveWidgetData<String>(
          'widget_meaning',
          currentItem['meaning']?.toString() ?? '',
        ),
        HomeWidget.saveWidgetData<String>(
          'widget_example',
          currentItem['example']?.toString() ?? '',
        ),
      ]);

      await HomeWidget.updateWidget(
        iOSName: iOSWidgetName,
        androidName: androidWidgetName,
      );
    } catch (error, stack) {
      debugPrint('Could not rotate to next widget word: $error\n$stack');
    }
  }

  /// Updates native Home Screen & Lock Screen widgets with today's list of words.
  static Future<void> updateWidgetWords({
    required List<VocabularyWord> words,
    required int streakDays,
  }) async {
    if (kIsWeb || words.isEmpty) return;

    try {
      await HomeWidget.setAppGroupId(appGroupId);

      final wordsJson = jsonEncode(
        words.map((w) => {
          'word': w.word,
          'ipa': w.pronunciation ?? '',
          'pos': w.partOfSpeech?.short ?? '',
          'meaning': w.meaning,
          'example': w.examples.isNotEmpty ? w.examples.first : '',
        }).toList(),
      );

      final currentIndex =
          (await HomeWidget.getWidgetData<int>('widget_rotation_index')) ?? 0;
      final safeIndex = currentIndex % words.length;
      final currentWord = words[safeIndex];

      await Future.wait([
        HomeWidget.saveWidgetData<String>('widget_words_json', wordsJson),
        HomeWidget.saveWidgetData<int>('widget_rotation_index', safeIndex),
        HomeWidget.saveWidgetData<String>('widget_word', currentWord.word),
        HomeWidget.saveWidgetData<String>(
          'widget_ipa',
          currentWord.pronunciation ?? '',
        ),
        HomeWidget.saveWidgetData<String>(
          'widget_pos',
          currentWord.partOfSpeech?.short ?? '',
        ),
        HomeWidget.saveWidgetData<String>('widget_meaning', currentWord.meaning),
        HomeWidget.saveWidgetData<String>(
          'widget_example',
          currentWord.examples.isNotEmpty ? currentWord.examples.first : '',
        ),
        HomeWidget.saveWidgetData<int>('widget_streak', streakDays),
      ]);

      await HomeWidget.updateWidget(
        iOSName: iOSWidgetName,
        androidName: androidWidgetName,
      );
    } catch (error, stack) {
      debugPrint('Could not update native widget list: $error\n$stack');
    }
  }

  /// Updates native Home Screen & Lock Screen widgets with the Word of the Day.
  static Future<void> updateWidgetData({
    required VocabularyWord word,
    required int streakDays,
  }) async {
    await updateWidgetWords(words: [word], streakDays: streakDays);
  }

  /// Clears native widget data.
  static Future<void> clearWidgetData() async {
    if (kIsWeb) return;

    try {
      await HomeWidget.setAppGroupId(appGroupId);
      await Future.wait([
        HomeWidget.saveWidgetData<String>('widget_words_json', ''),
        HomeWidget.saveWidgetData<int>('widget_rotation_index', 0),
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

  /// Returns the word currently displayed on the widget.
  static Future<String?> getCurrentWidgetWord() async {
    if (kIsWeb) return null;
    try {
      await HomeWidget.setAppGroupId(appGroupId);
      final word = await HomeWidget.getWidgetData<String>('widget_word');
      if (word != null && word.trim().isNotEmpty) return word.trim();

      final jsonString =
          await HomeWidget.getWidgetData<String>('widget_words_json');
      if (jsonString == null || jsonString.isEmpty) return null;

      final dynamic decoded = jsonDecode(jsonString);
      if (decoded is! List || decoded.isEmpty) return null;

      final currentIndex =
          (await HomeWidget.getWidgetData<int>('widget_rotation_index')) ?? 0;
      final currentItem = decoded[currentIndex % decoded.length];
      if (currentItem is Map<String, dynamic>) {
        return currentItem['word']?.toString();
      }
      return null;
    } catch (error, stack) {
      debugPrint('Could not get current widget word: $error\n$stack');
      return null;
    }
  }

  /// Sets up widget click handling for cold start and live app listening.
  static Future<void> handleWidgetClick({
    required WidgetProvider widgetProvider,
    required TtsService ttsService,
  }) async {
    if (kIsWeb) return;
    try {
      await HomeWidget.setAppGroupId(appGroupId);

      // 1. If launched from widget tap (cold start)
      final launchedUri = await HomeWidget.initiallyLaunchedFromHomeWidget();
      if (launchedUri != null) {
        await processWidgetTap(
          widgetProvider: widgetProvider,
          ttsService: ttsService,
        );
      }

      // 2. Stream listener for widget taps while app is in background or foreground
      HomeWidget.widgetClicked.listen((Uri? uri) async {
        await processWidgetTap(
          widgetProvider: widgetProvider,
          ttsService: ttsService,
        );
      });
    } catch (error, stack) {
      debugPrint('Could not initialize widget click listener: $error\n$stack');
    }
  }

  /// Processes a widget click: rotates to next word if enabled.
  static Future<void> processWidgetTap({
    required WidgetProvider widgetProvider,
    TtsService? ttsService,
  }) async {
    try {
      if (widgetProvider.rotateOnTap) {
        await rotateToNextWord();
      }
    } catch (error, stack) {
      debugPrint('Could not process widget tap: $error\n$stack');
    }
  }
}
