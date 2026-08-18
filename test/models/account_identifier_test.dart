import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/models/account_identifier.dart';

/// These rules mirror `Identifier::parse` and `PhoneNumber` on the server.
/// If one side changes, the app will start accepting input the API rejects,
/// so the cases here are deliberately the same ones the Rust tests cover.
void main() {
  group('email', () {
    test('is recognised and lowercased', () {
      final result = AccountIdentifier.parse('  Kelvin@Example.COM ');
      expect(result.kind, IdentifierKind.email);
      expect(result.value, 'kelvin@example.com');
      expect(result.isValid, isTrue);
    });

    test('rejects an address with no domain', () {
      final result = AccountIdentifier.parse('kelvin@');
      expect(result.isValid, isFalse);
      expect(result.error, isNotNull);
    });

    test('rejects an address with no dot in the domain', () {
      expect(AccountIdentifier.parse('kelvin@localhost').isValid, isFalse);
    });

    test('rejects an address containing a space', () {
      expect(AccountIdentifier.parse('kel vin@example.com').isValid, isFalse);
    });
  });

  group('phone', () {
    test('normalises presentation characters to E.164', () {
      // All four spellings must reach the server as one value, or they would
      // register as four separate accounts.
      for (final raw in [
        '+84901234567',
        '+84 90 123 4567',
        '+84-901-234-567',
        '+84 (901) 234.567',
      ]) {
        final result = AccountIdentifier.parse(raw);
        expect(result.kind, IdentifierKind.phone, reason: raw);
        expect(result.value, '+84901234567', reason: raw);
      }
    });

    test('accepts the double-zero international prefix', () {
      expect(AccountIdentifier.parse('0084901234567').value, '+84901234567');
    });

    test('rejects a bare national number', () {
      // Resolving 0901234567 needs a country the app cannot know.
      final result = AccountIdentifier.parse('0901234567');
      expect(result.kind, IdentifierKind.phone);
      expect(result.isValid, isFalse);
      expect(result.error, contains('country code'));
    });

    test('enforces the length bounds', () {
      expect(AccountIdentifier.parse('+123456').error, contains('short'));
      expect(
        AccountIdentifier.parse('+1234567890123456').error,
        contains('long'),
      );
    });

    test('reports a phone problem for phone-shaped input', () {
      // Not "that is not a valid email", which is what a naive fallback to
      // email parsing would say.
      final result = AccountIdentifier.parse('+8490');
      expect(result.kind, IdentifierKind.phone);
      expect(result.error, isNot(contains('email')));
    });
  });

  group('shape detection', () {
    test('anything with an @ is treated as an email', () {
      expect(AccountIdentifier.looksLikePhone('+84@example.com'), isFalse);
    });

    test('a leading + or 0 marks phone-shaped input', () {
      expect(AccountIdentifier.looksLikePhone('+84901234567'), isTrue);
      expect(AccountIdentifier.looksLikePhone('0901234567'), isTrue);
    });

    test('a bare word is not phone-shaped', () {
      expect(AccountIdentifier.looksLikePhone('kelvin'), isFalse);
      expect(AccountIdentifier.looksLikePhone(''), isFalse);
    });
  });

  group('empty input', () {
    test('is rejected with a prompt for either kind', () {
      final result = AccountIdentifier.parse('   ');
      expect(result.isValid, isFalse);
      expect(result.kind, IdentifierKind.unknown);
    });
  });

  group('field label', () {
    test('reflects how the input was read', () {
      expect(AccountIdentifier.parse('a@b.com').kindLabel, 'EMAIL');
      expect(AccountIdentifier.parse('+84901234567').kindLabel, 'PHONE');
      expect(AccountIdentifier.parse('').kindLabel, 'EMAIL OR PHONE');
    });
  });
}
