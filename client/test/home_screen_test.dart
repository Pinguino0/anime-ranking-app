import 'package:animerank/features/anime/domain/anime.dart';
import 'package:animerank/features/anime/presentation/anime_controller.dart';
import 'package:animerank/features/auth/presentation/auth_controller.dart';
import 'package:animerank/features/groups/domain/group.dart';
import 'package:animerank/features/home/domain/friend_activity.dart';
import 'package:animerank/features/home/home_controller.dart';
import 'package:animerank/features/home/screens/home_screen.dart';
import 'package:animerank/features/history/domain/watch_history.dart';
import 'package:animerank/features/history/presentation/history_controller.dart';
import 'package:animerank/features/watchlist/domain/watchlist.dart';
import 'package:animerank/features/watchlist/presentation/watchlist_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_anime.dart';
import 'helpers/fake_auth.dart';

/// Le sezioni della home, disegnate davvero.
///
/// I test puri fissano cosa entra in ogni riga; questi fissano che le righe
/// esistano, che quelle senza dati non compaiano, e che la pagina non sfori
/// ne' su telefono ne' su desktop. Sono cose che `flutter analyze` non vede: un
/// overflow e' un errore di layout che si manifesta solo disegnando.
class _StubHistory extends WatchHistoryController {
  _StubHistory(this.rows);

  final List<WatchHistoryItem> rows;

  @override
  Future<List<WatchHistoryItem>> build() async => rows;
}

class _StubMyList extends MyListController {
  _StubMyList(this.rows);

  final List<WatchlistEntry> rows;

  @override
  Future<List<WatchlistEntry>> build() async => rows;
}

void main() {
  Future<void> pumpHome(
    WidgetTester tester, {
    required FakeAnimeRepository repository,
    List<ContinueWatchingItem> continueWatching = const [],
    List<WatchHistoryItem> history = const [],
    List<WatchlistEntry> myList = const [],
    Size size = const Size(420, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeRepositoryProvider.overrideWithValue(repository),
          authRepositoryProvider.overrideWithValue(
            FakeAuthRepository(session: buildSession()),
          ),
          // Nessun gruppo: le sezioni social sono quelle che devono sparire.
          primaryGroupProvider.overrideWithValue(
            const AsyncValue<AnimeGroup?>.data(null),
          ),
          friendActivityProvider.overrideWith(
            (ref) async => const <FriendActivity>[],
          ),
          continueWatchingProvider.overrideWith(
            (ref) async => continueWatching,
          ),
          watchHistoryProvider.overrideWith(() => _StubHistory(history)),
          myListProvider.overrideWith(() => _StubMyList(myList)),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  FakeAnimeRepository populated() => FakeAnimeRepository(
    initial: [
      animeFixture(
        externalId: '1',
        id: 'id-1',
        title: 'Alfa',
        status: AnimeAirStatus.airing,
        popularity: 100,
      ),
      animeFixture(
        externalId: '2',
        id: 'id-2',
        title: 'Beta',
        status: AnimeAirStatus.airing,
        popularity: 50,
      ),
      animeFixture(
        externalId: '3',
        id: 'id-3',
        title: 'Gamma',
        status: AnimeAirStatus.airing,
        popularity: 10,
      ),
    ],
  )..recentEpisodesResult = [animeFixture(externalId: '4', id: 'id-4')];

  testWidgets('mostra le sezioni con dati e zittisce quelle social', (
    tester,
  ) async {
    // Viewport alto di proposito: una `CustomScrollView` costruisce le sliver
    // solo quando entrano nel viewport, e con un telefono normale le sezioni in
    // fondo non esisterebbero ancora nell'albero. Qui si vuole vedere tutta la
    // pagina in una volta, sia per le sezioni che ci devono essere sia per
    // quelle che non ci devono essere.
    await pumpHome(
      tester,
      size: const Size(420, 3600),
      repository: populated(),
      continueWatching: const [
        ContinueWatchingItem(
          animeId: 'c1',
          animeTitle: 'Lasciato a meta',
          episodeId: 'e1',
          episodeNumber: 3,
          currentSeconds: 120,
        ),
      ],
      history: const [
        WatchHistoryItem(
          animeId: 'h1',
          animeTitle: 'Visto ieri',
          episodeId: 'he1',
          episodeNumber: 5,
          currentSeconds: 0,
          completed: true,
        ),
      ],
      myList: const [
        WatchlistEntry(
          id: 'w1',
          animeId: 'm1',
          status: WatchStatus.watching,
        ),
      ],
    );

    // Testata e banner.
    expect(find.text('AnimeRank'), findsOneWidget);
    expect(find.text('IN EVIDENZA'), findsOneWidget);

    // Le sezioni con dati.
    expect(find.text('Continua a guardare'), findsOneWidget);
    expect(find.text('Guardati di recente'), findsOneWidget);
    expect(find.text('Ultime novità'), findsOneWidget);
    expect(find.text('Più popolari'), findsOneWidget);
    expect(find.text('Riprendi dalla Watchlist'), findsOneWidget);
    expect(find.text('Stagione corrente'), findsOneWidget);
    expect(find.text('Anime casuale'), findsOneWidget);

    // Nessun gruppo: la community e gli amici non si inventano.
    expect(find.text('Più votati dalla community'), findsNothing);
    expect(find.text('Attività degli amici'), findsNothing);

    expect(tester.takeException(), isNull);
  });

  testWidgets('senza gruppo i consigli non si spacciano per personali', (
    tester,
  ) async {
    await pumpHome(tester, repository: populated());

    // Nessun genere ricavabile: la sezione resta fuori, non diventa un
    // carosello casuale con un titolo che promette personalizzazione.
    expect(find.text('Consigliati per te'), findsNothing);
  });

  testWidgets('catalogo vuoto: invito alla ricerca, non una pagina rotta', (
    tester,
  ) async {
    await pumpHome(tester, repository: FakeAnimeRepository());

    expect(find.text('Benvenuto su AnimeRank'), findsOneWidget);
    expect(find.text('Cerca un anime'), findsOneWidget);

    // Nessuna sezione vuota con titolo e niente sotto.
    expect(find.text('Continua a guardare'), findsNothing);
    expect(find.text('Più popolari'), findsNothing);

    expect(tester.takeException(), isNull);
  });

  testWidgets('su desktop la pagina non sfora', (tester) async {
    await pumpHome(
      tester,
      repository: populated(),
      size: const Size(1280, 900),
    );

    expect(find.text('AnimeRank'), findsOneWidget);
    expect(find.text('Più popolari'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
