import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  final prefs = await SharedPreferences.getInstance();
  final storageService = StorageService(prefs);

  runApp(VeeaEnglishApp(storageService: storageService));
}

class VeeaEnglishApp extends StatelessWidget {
  final StorageService storageService;

  const VeeaEnglishApp({super.key, required this.storageService});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => VocabularyProvider(storageService),
        ),
        ChangeNotifierProvider(
          create: (_) => TtsService(),
        ),
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
