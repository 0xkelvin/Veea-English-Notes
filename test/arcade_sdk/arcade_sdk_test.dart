import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veea_english_app/arcade_sdk/arcade_sdk.dart';
import 'package:veea_english_app/widgets/pixel/pixel_icon.dart';

void main() {
  group('ArcadeRegistry', () {
    setUp(() {
      ArcadeRegistry.reset();
    });

    test('registers and retrieves games correctly', () {
      final manifest1 = ArcadeGameManifest(
        id: 'test_game_1',
        title: 'TEST GAME 1',
        tagline: 'A sample game',
        author: '@veea_team',
        version: '1.0.0',
        glyph: PixelGlyph.gamepad,
        category: ArcadeGameCategory.retroArcade,
        badge: 'OFFICIAL',
        builder: (ctx) => const SizedBox(),
      );

      final manifest2 = ArcadeGameManifest(
        id: 'test_game_2',
        title: 'COMMUNITY GAME',
        tagline: 'A community game',
        author: '@contributor',
        version: '1.0.0',
        glyph: PixelGlyph.fire,
        category: ArcadeGameCategory.community,
        badge: 'COMMUNITY',
        builder: (ctx) => const SizedBox(),
      );

      ArcadeRegistry.register(manifest1);
      ArcadeRegistry.register(manifest2);

      expect(ArcadeRegistry.allGames.length, 2);
      expect(ArcadeRegistry.officialGames.length, 1);
      expect(ArcadeRegistry.officialGames.first.id, 'test_game_1');
      expect(ArcadeRegistry.communityGames.length, 1);
      expect(ArcadeRegistry.communityGames.first.id, 'test_game_2');
      expect(ArcadeRegistry.findById('test_game_1')?.title, 'TEST GAME 1');
      expect(ArcadeRegistry.findById('non_existent'), isNull);
    });

    test('ArcadeDefaults registers all standard games', () {
      ArcadeDefaults.registerDefaults();
      expect(ArcadeRegistry.allGames.length, greaterThanOrEqualTo(10));
      expect(ArcadeRegistry.findById('word_rush'), isNotNull);
      expect(ArcadeRegistry.findById('vocab_invaders'), isNotNull);
      expect(ArcadeRegistry.findById('starter_template'), isNotNull);
    });
  });

  group('Arcade Particle System', () {
    test('createExplosion creates correct number of particles', () {
      final particles = ArcadeParticle.createExplosion(
        originX: 100,
        originY: 100,
        color: Colors.red,
        count: 12,
      );

      expect(particles.length, 12);
      for (final p in particles) {
        expect(p.x, 100);
        expect(p.y, 100);
        expect(p.life, greaterThan(0));
      }
    });

    test('particle updates position and decays life', () {
      final particle = ArcadeParticle(
        x: 50,
        y: 50,
        vx: 10,
        vy: 20,
        color: Colors.yellow,
        life: 1.0,
      );

      final isAlive = particle.update(0.1);
      expect(isAlive, isTrue);
      expect(particle.x, 51.0);
      expect(particle.y, 52.0);
      expect(particle.life, lessThan(1.0));
    });
  });

  group('Arcade Falling Badge Data', () {
    test('applies gravity acceleration and fades out', () {
      final badge = ArcadeFallingBadgeData(
        id: '1',
        meaning: 'kiên cường',
        x: 100,
        y: 50,
        vy: 10.0,
      );

      final initialY = badge.y;
      final initialVy = badge.vy;
      final isAlive = badge.update(0.1);

      expect(isAlive, isTrue);
      expect(badge.y, greaterThan(initialY));
      expect(badge.vy, greaterThan(initialVy));
      expect(badge.opacity, lessThan(1.0));
    });
  });
}
