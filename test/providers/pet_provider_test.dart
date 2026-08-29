import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veea_english_app/models/pet_companion.dart';
import 'package:veea_english_app/providers/pet_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('PetCompanion Model', () {
    test('calculates level and stages correctly', () {
      const pet1 = PetCompanion(xp: 20);
      expect(pet1.level, 1);
      expect(pet1.stage, PetStage.egg);

      const pet2 = PetCompanion(xp: 120);
      expect(pet2.level, 3);
      expect(pet2.stage, PetStage.hatchling);

      const pet3 = PetCompanion(xp: 320);
      expect(pet3.level, 7);
      expect(pet3.stage, PetStage.cyberPup);

      const pet4 = PetCompanion(xp: 600);
      expect(pet4.level, 13);
      expect(pet4.stage, PetStage.mechaDragon);
    });

    test('derives mood from activity and streak', () {
      const pet = PetCompanion(wordsFedToday: 6);
      expect(pet.calculateMood(streakDays: 5, dueCount: 0), PetMood.ecstatic);

      const petHungry = PetCompanion(wordsFedToday: 0);
      expect(petHungry.calculateMood(streakDays: 0, dueCount: 3), PetMood.hungry);
    });
  });

  group('PetProvider', () {
    test('feeds word and gains XP', () async {
      final provider = PetProvider();
      await provider.init();

      final initialXp = provider.pet.xp;
      await provider.feedWord('resilient');

      expect(provider.pet.xp, initialXp + 15);
      expect(provider.pet.wordsFedToday, 1);
      expect(provider.currentSpeech, contains('resilient'));
    });

    test('pets and gains affection XP', () async {
      final provider = PetProvider();
      await provider.init();

      final initialXp = provider.pet.xp;
      await provider.petTouch();

      expect(provider.pet.xp, initialXp + 2);
    });

    test('renames pet successfully', () async {
      final provider = PetProvider();
      await provider.init();

      await provider.rename('PixelDragon');
      expect(provider.pet.name, 'PIXELDRAGON');
    });
  });
}
