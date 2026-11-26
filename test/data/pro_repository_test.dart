import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/core/config/app_config.dart';
import 'package:veea_english_app/data/pro_repository.dart';
import 'package:veea_english_app/data/remote/go/api_client.dart';
import 'package:veea_english_app/data/remote/go/session_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('veea.test.purchase-origin');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    AppConfig.overrideBaseUrl(null);
    messenger.setMockMethodCallHandler(channel, null);
  });
  test(
    'native purchase cache separates public API endpoints and strips URL extras',
    () async {
      Map<dynamic, dynamic>? arguments;
      messenger.setMockMethodCallHandler(channel, (call) async {
        arguments = call.arguments as Map<dynamic, dynamic>;
        return <String, Object?>{};
      });
      final repository = ProRepository(
        client: GoApiClient(tokens: GoTokenStore()),
        channel: channel,
      );
      AppConfig.overrideBaseUrl(
        'https://accounts.example.test:8443/path/?ignored=value#fragment',
      );
      await repository.configure('00000000-0000-0000-0000-000000000001');
      expect(
        arguments?['apiOrigin'],
        'https://accounts.example.test:8443/path',
      );
      AppConfig.overrideBaseUrl(
        'https://accounts.example.test:8443/production',
      );
      await repository.configure('00000000-0000-0000-0000-000000000001');
      expect(
        arguments?['apiOrigin'],
        'https://accounts.example.test:8443/production',
      );
      // Offline/unconfigured builds must not throw while initializing Free usage.
      AppConfig.overrideBaseUrl('');
      await repository.configure(null);
      expect(arguments?['apiOrigin'], '');
      AppConfig.overrideBaseUrl('relative/path');
      await repository.configure(null);
      expect(arguments?['apiOrigin'], '');
    },
  );
}
