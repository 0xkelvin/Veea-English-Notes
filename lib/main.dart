import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'core/theme/app_theme.dart';
import 'providers/auth_provider.dart';
import 'providers/locale_provider.dart';
import 'providers/vocabulary_provider.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/vocabulary_api_service.dart';
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

  final authProvider = AuthProvider();
  await authProvider.init();

  final localeProvider = LocaleProvider();
  await localeProvider.init();

  final vocabProvider = VocabularyProvider(VocabularyApiService(), authProvider);
  if (authProvider.isAuthenticated) {
    await vocabProvider.init();
  }

  runApp(VeeaEnglishApp(
    vocabProvider: vocabProvider,
    authProvider: authProvider,
    localeProvider: localeProvider,
  ));
}

class VeeaEnglishApp extends StatelessWidget {
  final VocabularyProvider vocabProvider;
  final AuthProvider authProvider;
  final LocaleProvider localeProvider;

  const VeeaEnglishApp({
    super.key,
    required this.vocabProvider,
    required this.authProvider,
    required this.localeProvider,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: authProvider),
        ChangeNotifierProvider.value(value: vocabProvider),
        ChangeNotifierProvider.value(value: localeProvider),
        ChangeNotifierProvider(create: (_) => TtsService()),
      ],
      child: MaterialApp(
        title: 'Veea English',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        home: const _AuthGate(),
      ),
    );
  }
}

class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  AuthStatus? _prevStatus;

  @override
  Widget build(BuildContext context) {
    final status = context.select<AuthProvider, AuthStatus>((p) => p.status);

    // When transitioning to authenticated, load vocabulary
    if (status == AuthStatus.authenticated && _prevStatus != AuthStatus.authenticated) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          context.read<VocabularyProvider>().init();
        }
      });
    }
    _prevStatus = status;

    switch (status) {
      case AuthStatus.loading:
        return const _SplashScreen();
      case AuthStatus.authenticated:
        return const HomeScreen();
      case AuthStatus.unauthenticated:
        return const LoginScreen();
    }
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
