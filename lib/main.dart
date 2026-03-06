import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'core/theme/app_theme.dart';
import 'providers/vocabulary_provider.dart';
import 'screens/home_screen.dart';
import 'services/storage_service.dart';
import 'services/tts_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ),
  );

  final storageService = StorageService();
  final vocabProvider = VocabularyProvider(storageService);
  await vocabProvider.init();

  runApp(VeeaEnglishApp(vocabProvider: vocabProvider));
}

class VeeaEnglishApp extends StatelessWidget {
  final VocabularyProvider vocabProvider;

  const VeeaEnglishApp({super.key, required this.vocabProvider});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: vocabProvider),
        ChangeNotifierProvider(create: (_) => TtsService()),
      ],
      child: MaterialApp(
        title: 'Veea English',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        home: const HomeScreen(),
      ),
    );
  }
}
