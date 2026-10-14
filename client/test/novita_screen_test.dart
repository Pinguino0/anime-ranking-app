import 'package:animerank/features/anime/data/anime_repository.dart';
import 'package:animerank/features/anime/domain/anime.dart';
import 'package:animerank/features/anime/presentation/anime_controller.dart';
import 'package:animerank/features/history/domain/watch_history.dart';
import 'package:animerank/features/history/presentation/history_controller.dart';
import 'package:animerank/features/novita/presentation/screens/novita_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_anime.dart';

/// La pagina "Novita'".
///
/// E' una pagina a se': raccoglie in tre righe quello che la home sparpaglia.
/// Quello che i test devono fissare e' che le tre righe esistano quando c'e'
/// qualcosa da mostrare, e che l'assenza di contenuti non diventi una pagina
/// bianca: "non c'e' niente" e "non ho potuto leggere" sono due risposte
/// diverse e devono restare distinguibili.
void main() {
  Future<void> pumpNovita(
    WidgetTester tester, {
    required FakeAnimeRepository repository,
    List<ContinueWatchingItem> continueWatching = const [],
    Size size = const Size(420, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeRepositoryProvider.overrideWithValue(repository),
          // Sovrascritto direttamente: la riga "continua" dipende dallo storico
          // e dall'utente collegato, e qui interessa solo cosa succede quando la
          // lista arriva piena o vuota.
          continueWatchingProvider.overrideWith((ref) async => continueWatching),
        ],
        child: const MaterialApp(home: NovitaScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('mostra in uscita, nuovi episodi e continua a guardare',
      (tester) async {
    final repository = FakeAnimeRepository(
      initial: [
        animeFixture(
          externalId: '1',
          title: 'Uscita uno',
          status: AnimeAirStatus.airing,
        ),
        animeFixture(
          externalId: '2',
          title: 'Uscita due',
          status: AnimeAirStatus.airing,
        ),
      ],
    )..recentEpisodesResult = [
        animeFixture(externalId: '3', title: 'Puntata fresca'),
      ];

    await pumpNovita(
      tester,
      repository: repository,
      continueWatching: const [
        ContinueWatchingItem(
          animeId: 'a',
          animeTitle: 'Lasciato a meta',
          episodeId: 'e',
          episodeNumber: 3,
          currentSeconds: 120,
        ),
      ],
    );

    // Le tre intestazioni: sono l'indice della pagina.
    expect(find.text('In uscita'), findsOneWidget);
    expect(find.text('Nuovi episodi'), findsOneWidget);
    expect(find.text('Continua a guardare'), findsOneWidget);

    // E i contenuti sotto, uno per riga.
    expect(find.text('Uscita uno'), findsOneWidget);
    expect(find.text('Puntata fresca'), findsOneWidget);
    expect(find.text('Lasciato a meta'), findsOneWidget);
  });

  testWidgets('senza niente da mostrare lo dice invece di restare vuota',
      (tester) async {
    await pumpNovita(tester, repository: FakeAnimeRepository());

    expect(find.text('Nessuna novita\''), findsOneWidget);
    expect(find.text('In uscita'), findsNothing);
  });

  testWidgets('un guasto di rete offre il riprova', (tester) async {
    // Nessuna riga popolata e la stagione in errore: non c'e' niente da
    // mostrare e la causa non e' "non c'e' niente di nuovo".
    final repository = FakeAnimeRepository()
      ..seasonFailure = const AnimeFailure('stagione giu', isRetryable: true);

    await pumpNovita(tester, repository: repository);

    expect(
      find.text('Non riesco a leggere le novita\'. Controlla la rete e riprova.'),
      findsOneWidget,
    );
    expect(find.text('Riprova'), findsOneWidget);
  });
}
