import 'package:animerank/features/achievements/domain/achievement.dart';
import 'package:animerank/features/achievements/presentation/achievements_controller.dart';
import 'package:animerank/features/achievements/presentation/screens/achievements_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_achievements.dart';

void main() {
  ProviderContainer container(FakeAchievementsRepository repo) {
    final c = ProviderContainer(
      overrides: [achievementsRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    FakeAchievementsRepository repo,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [achievementsRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: AchievementsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('Achievement', () {
    test('un obiettivo nascosto non e visibile finche non si sblocca', () {
      expect(buildAchievement(hidden: true).isVisible, isFalse);
      expect(
        buildAchievement(hidden: true, unlockedAt: DateTime(2026)).isVisible,
        isTrue,
      );
    });

    test('parse legge la riga del catalogo', () {
      final achievement = Achievement.parse({
        'id': 'x',
        'code': 'c',
        'name': 'Nome',
        'description': 'Desc',
        'icon': '🏆',
        'requirement': 'Fai qualcosa',
        'hidden': true,
      });

      expect(achievement.name, 'Nome');
      expect(achievement.hidden, isTrue);
      expect(achievement.isUnlocked, isFalse);
    });
  });

  group('AchievementsController', () {
    test('carica gli obiettivi dell utente', () async {
      final repo = FakeAchievementsRepository();
      final c = container(repo);

      final values = await c.read(achievementsProvider.future);

      expect(values, hasLength(2));
      expect(repo.loadCalls, 1);
    });

    test('un errore non ritentato resta visibile', () async {
      final repo = FakeAchievementsRepository()
        ..loadFailure = const AchievementsFailure('Obiettivi non disponibili.');
      final c = container(repo);

      await expectLater(
        c.read(achievementsProvider.future),
        throwsA(isA<AchievementsFailure>()),
      );
    });
  });

  group('schermata obiettivi', () {
    testWidgets('mostra il riepilogo e tutti gli obiettivi', (tester) async {
      final repo = FakeAchievementsRepository();
      await pumpScreen(tester, repo);

      // Un solo sbloccato su due: la frase e' al singolare.
      expect(find.text('Ti manca un obiettivo su 2.'), findsOneWidget);
      expect(find.text('Primo voto'), findsOneWidget);
      expect(find.text('Dieci voti'), findsOneWidget);
      // Il bloccato mostra cosa serve per sbloccarlo, non solo che manca.
      expect(find.text('Vota 10 anime'), findsOneWidget);
      // Lo sbloccato mostra la data.
      expect(find.text('Sbloccato il 1 febbraio 2026'), findsOneWidget);
    });

    testWidgets('tutti sbloccati: nessun obiettivo mancante', (tester) async {
      final repo = FakeAchievementsRepository(
        achievements: [
          buildAchievement(unlockedAt: DateTime(2026, 2, 1)),
          buildAchievement(
            id: 'a2',
            name: 'Dieci voti',
            unlockedAt: DateTime(2026, 3, 1),
          ),
        ],
      );
      await pumpScreen(tester, repo);

      expect(find.text('Li hai sbloccati tutti. Complimenti.'), findsOneWidget);
    });

    testWidgets('catalogo vuoto: lo dice invece di restare muta', (tester) async {
      final repo = FakeAchievementsRepository(achievements: []);
      await pumpScreen(tester, repo);

      expect(find.text('Nessun obiettivo'), findsOneWidget);
    });

    testWidgets('un errore offre il retry', (tester) async {
      final repo = FakeAchievementsRepository()
        ..loadFailure = const AchievementsFailure('Obiettivi non disponibili. Riprova.', isRetryable: true);
      await pumpScreen(tester, repo);

      expect(find.text('Obiettivi non disponibili. Riprova.'), findsOneWidget);

      repo.loadFailure = null;
      await tester.tap(find.text('Riprova'));
      await tester.pumpAndSettle();

      expect(repo.loadCalls, greaterThan(1));
      expect(find.text('Primo voto'), findsOneWidget);
    });
  });
}
