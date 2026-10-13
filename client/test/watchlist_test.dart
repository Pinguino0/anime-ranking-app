import 'package:animerank/core/router/app_router.dart';
import 'package:animerank/core/ui/section_header.dart';
import 'package:animerank/features/ranking/presentation/ranking_controller.dart';
import 'package:animerank/features/watchlist/data/watchlist_repository.dart';
import 'package:animerank/features/watchlist/domain/watchlist.dart';
import 'package:animerank/features/watchlist/presentation/screens/watchlist_screen.dart';
import 'package:animerank/features/watchlist/presentation/watchlist_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'helpers/fake_ranking.dart';
import 'helpers/fake_watchlist.dart';

void main() {
  group('WatchStatus', () {
    test('dal valore del backend si riconosce lo stato', () {
      expect(WatchStatus.fromWire('completed'), WatchStatus.completed);
      expect(WatchStatus.fromWire('dropped'), WatchStatus.dropped);
    });

    test('uno stato sconosciuto non lascia la riga senza etichetta', () {
      // Il backend accetterebbe la riga solo con un valore dell enum, ma una
      // versione futura del client puo' leggere dati scritti da una successiva:
      // meglio "da iniziare" che uno spazio vuoto nella lista.
      expect(WatchStatus.fromWire('qualcosa_di_nuovo'), WatchStatus.planned);
      expect(WatchStatus.fromWire(null), WatchStatus.planned);
    });

    test('in alto compare prima quello che si sta guardando', () {
      expect(WatchStatus.displayOrder.first, WatchStatus.watching);
      expect(
        WatchStatus.displayOrder.indexOf(WatchStatus.completed),
        greaterThan(WatchStatus.displayOrder.indexOf(WatchStatus.watching)),
      );
    });
  });

  group('WatchlistEntry.parse', () {
    test('i dati dell anime arrivano dal join', () {
      final entry = WatchlistEntry.parse({
        'id': 'w1',
        'group_id': 'g1',
        'user_id': 'u1',
        'anime_id': 'a1',
        'status': 'watching',
        'current_episode': 5,
        'is_favorite': true,
        'updated_at': '2026-01-02T03:04:05Z',
        'anime': {
          'title': 'Trigun',
          'image_url': 'https://img/trigun.jpg',
          'episodes': 26,
          'year': 1998,
          'genres': ['Action', 'Space'],
          'status': 'finished_airing',
        },
      });

      expect(entry.animeId, 'a1');
      expect(entry.title, 'Trigun');
      expect(entry.status, WatchStatus.watching);
      expect(entry.isFavorite, isTrue);
      expect(entry.episodeLabel, '5 / 26');
      expect(entry.progress, closeTo(5 / 26, 0.001));
      // Senza "in corso" perche' il catalogo dice finished_airing.
      expect(entry.meta, '1998 · 26 episodi');
      expect(entry.updatedAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
    });

    test('senza anime la riga ha comunque un titolo', () {
      final entry = WatchlistEntry.parse({
        'id': 'w1',
        'group_id': 'g1',
        'anime_id': 'a1',
      });

      expect(entry.title, 'Senza titolo');
      expect(entry.status, WatchStatus.planned);
      expect(entry.currentEpisode, 0);
      expect(entry.episodeLabel, '0');
    });

    test('un anime in corso non ha un progresso da mostrare', () {
      // episodes null e il caso normale per un anime ancora in trasmissione:
      // inventare una percentuale su un totale ignoto mostrerebbe una barra
      // piena o vuota senza motivo.
      final entry = WatchlistEntry.parse({
        'id': 'w1',
        'group_id': 'g1',
        'anime_id': 'a1',
        'current_episode': 8,
        'anime': {'title': 'One Piece', 'status': 'currently_airing'},
      });

      expect(entry.progress, isNull);
      expect(entry.episodeLabel, '8');
      expect(entry.airing, isTrue);
      expect(entry.meta, 'in corso');
    });

    test('il join letto come lista di un elemento funziona uguale', () {
      final entry = WatchlistEntry.parse({
        'id': 'w1',
        'group_id': 'g1',
        'anime_id': 'a1',
        'anime': [
          {'title': 'Nadia', 'episodes': 39},
        ],
      });

      expect(entry.title, 'Nadia');
      expect(entry.episodes, 39);
    });

    test('displayTitle preferisce il titolo italiano del join', () {
      final withIt = WatchlistEntry.parse({
        'id': 'w1',
        'group_id': 'g1',
        'anime_id': 'a1',
        'anime': {'title': 'Shingeki no Kyojin', 'title_it': "L'attacco dei giganti"},
      });
      expect(withIt.italianTitle, "L'attacco dei giganti");
      expect(withIt.displayTitle, "L'attacco dei giganti");

      final noIt = WatchlistEntry.parse({
        'id': 'w1',
        'group_id': 'g1',
        'anime_id': 'a1',
        'anime': {'title': 'Trigun'},
      });
      expect(noIt.italianTitle, isNull);
      expect(noIt.displayTitle, 'Trigun');
    });

    test('il progresso non supera l uno', () {
      final entry = WatchlistEntry.parse({
        'id': 'w1',
        'group_id': 'g1',
        'anime_id': 'a1',
        'current_episode': 30,
        'anime': {'title': 'Berserk', 'episodes': 12},
      });

      expect(entry.progress, 1);
    });

    test('unwatchedEpisodes segnala solo le puntate oltre il segnaposto', () {
      // Il caso che accende la pastiglia: ha iniziato e il catalogo e' andato
      // avanti.
      expect(
        buildWatchlistEntry(currentEpisode: 5, episodes: 12).unwatchedEpisodes,
        7,
      );
    });

    test('unwatchedEpisodes tace se non c\'e\' niente da segnalare', () {
      // Mai iniziato: non e' "un episodio nuovo" di qualcosa che non si e'
      // aperto.
      expect(
        buildWatchlistEntry(currentEpisode: 0, episodes: 12).unwatchedEpisodes,
        isNull,
      );
      // Gia' in pari.
      expect(
        buildWatchlistEntry(currentEpisode: 12, episodes: 12).unwatchedEpisodes,
        isNull,
      );
      // Totale ignoto.
      expect(
        buildWatchlistEntry(currentEpisode: 5, episodes: null).unwatchedEpisodes,
        isNull,
      );
    });
  });

  group('WatchlistTotals.parse', () {
    test('le cifre vengono da personal_stats', () {
      final totals = WatchlistTotals.parse({
        'rated_count': 12,
        'mean_score': 7.5,
        'watched_count': 8,
        'watching': 3,
        'completed': 4,
        'dropped': 1,
        'favorites': 5,
        'episodes_watched': 96,
        'estimated_hours': 72.0,
        'top_genre': 'Action',
        'top_studio': 'Bones',
      });

      expect(totals.rated, 12);
      expect(totals.meanScore, 7.5);
      expect(totals.entries, 8);
      expect(totals.watching, 3);
      expect(totals.completed, 4);
      expect(totals.favorites, 5);
      expect(totals.episodes, 96);
      expect(totals.hours, 72);
      expect(totals.topGenre, 'Action');
      expect(totals.topStudio, 'Bones');
    });

    test('una risposta vuota vale come cifre a zero', () {
      final totals = WatchlistTotals.parse(const {});

      expect(totals.entries, 0);
      expect(totals, const WatchlistTotals());
    });
  });

  group('WatchlistValidators', () {
    test('un episodio oltre il totale viene rifiutato con il messaggio del server', () {
      final error = WatchlistValidators.episodeError(episode: 30, total: 12);

      // Stesso testo del trigger check_watchlist_episode: l'utente non deve
      // vedere due parole diverse per lo stesso errore a seconda di dove e'
      // stato scoperto.
      expect(error, 'Episodio 30 superiore ai 12 episodi disponibili');
    });

    test('il totale ignoto non mette un tetto', () {
      expect(WatchlistValidators.episodeError(episode: 500, total: null), isNull);
    });

    test('un numero negativo non passa', () {
      expect(WatchlistValidators.episodeError(episode: -1, total: 12), isNotNull);
    });

    test('il totale esatto e valido', () {
      expect(WatchlistValidators.episodeError(episode: 12, total: 12), isNull);
    });
  });

  group('controller', () {
    late FakeWatchlistRepository repo;

    setUp(() => repo = FakeWatchlistRepository());

    ProviderContainer container([FakeWatchlistRepository? r]) {
      final c = ProviderContainer(
        overrides: [watchlistRepositoryProvider.overrideWithValue(r ?? repo)],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('il primo caricamento chiede la watchlist del gruppo', () async {
      repo = FakeWatchlistRepository(initial: [buildWatchlistEntry()]);
      final c = container();

      final entries = await c.read(watchlistProvider('g1').future);

      expect(entries, hasLength(1));
      expect(repo.entriesCalls, 1);
    });

    test('due gruppi hanno due elenchi separati', () async {
      repo = FakeWatchlistRepository(initial: [
        buildWatchlistEntry(animeId: 'a1', groupId: 'g1'),
        buildWatchlistEntry(animeId: 'a2', groupId: 'g2', title: 'Trigun'),
      ]);
      final c = container();

      await c.read(watchlistProvider('g1').future);
      await c.read(watchlistProvider('g2').future);

      // Senza il gruppo nella chiave il secondo gruppo mostrerebbe la watchlist
      // del primo: il titolo del gruppo e' nel titolo della schermata, quindi
      // l'errore sarebbe silenzioso e convincente.
      expect((await c.read(watchlistProvider('g1').future)).single.animeId, 'a1');
      expect((await c.read(watchlistProvider('g2').future)).single.animeId, 'a2');
    });

    test('dopo un cambio di stato la lista e i totali vengono riletti', () async {
      repo = FakeWatchlistRepository(initial: [buildWatchlistEntry()]);
      final c = container();

      // Con un ascoltatore, non solo una lettura: `invalidate` e pigro, quindi
      // senza qualcosa che osserva i provider il repository non verrebbe
      // chiamato una seconda volta e il test passerebbe anche senza la
      // rilettura.
      final entries = c.listen(watchlistProvider('g1'), (_, _) {});
      final totals = c.listen(watchlistTotalsProvider('g1'), (_, _) {});
      addTearDown(entries.close);
      addTearDown(totals.close);

      await c.read(watchlistProvider('g1').future);
      await c.read(watchlistTotalsProvider('g1').future);

      await c.read(watchlistActionProvider.notifier).setStatus(
            groupId: 'g1',
            animeId: 'a1',
            status: WatchStatus.completed,
          );
      await c.read(watchlistProvider('g1').future);
      await c.read(watchlistTotalsProvider('g1').future);

      expect(repo.statusChanges, ['a1|completed']);
      expect(repo.entriesCalls, 2);
      // Anche i totali: un anime che passa in completato cambia il conteggio
      // delle voci in visione, e cifre e elenco che non tornano insieme sono
      // peggio di un secondo di caricamento.
      expect(repo.totalsCalls, 2);
    });

    test('un salvataggio non riuscito non riletta e rilancia l errore', () async {
      repo = FakeWatchlistRepository(initial: [buildWatchlistEntry()])
        ..writeFailure = const WatchlistFailure('Permessi insufficienti.');
      final c = container();
      await c.read(watchlistProvider('g1').future);
      final before = repo.entriesCalls;

      await expectLater(
        c.read(watchlistActionProvider.notifier)
            .setStatus(groupId: 'g1', animeId: 'a1', status: WatchStatus.dropped),
        throwsA(isA<WatchlistFailure>()),
      );

      // Ricaricare dopo un errore mostrerebbe gli stessi dati come se il
      // salvataggio fosse andato a buon fine.
      expect(repo.entriesCalls, before);
      expect(c.read(watchlistActionProvider).hasError, isTrue);
    });
  });

  group('schermata', () {
    late FakeWatchlistRepository repo;

    setUp(() => repo = FakeWatchlistRepository());

    /// Monta la watchlist dentro un router vero.
    Future<void> pump(
      WidgetTester tester, {
      FakeWatchlistRepository? repository,
      FakeRankingRepository? ranking,
      Size size = const Size(500, 900),
    }) async {
      final r = repository ?? repo;

      final router = GoRouter(
        initialLocation: '/watchlist/g1',
        routes: [
          GoRoute(
            path: '/watchlist/:groupId',
            builder: (_, state) => WatchlistScreen(
              groupId: state.pathParameters['groupId']!,
              groupName: state.extra as String?,
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size),
          child: ProviderScope(
            overrides: [
              watchlistRepositoryProvider.overrideWithValue(r),
              // Serve solo al foglio "aggiungi dalla classifica", ma senza
              // l'override il provider vero lancerebbe appena il foglio si
              // apre e il test crasherebbe per un motivo fuori dal suo caso.
              rankingRepositoryProvider.overrideWithValue(
                ranking ?? FakeRankingRepository(),
              ),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('una watchlist vuota spiega come riempirla', (tester) async {
      await pump(tester);

      expect(find.text('La watchlist e vuota.'), findsOneWidget);
      expect(find.textContaining('classifica'), findsWidgets);
    });

    testWidgets('le voci sono raggruppate per stato', (tester) async {
      repo = FakeWatchlistRepository(initial: [
        buildWatchlistEntry(animeId: 'a1', title: 'Cowboy Bebop'),
        buildWatchlistEntry(
          animeId: 'a2',
          title: 'Trigun',
          status: WatchStatus.completed,
        ),
      ]);

      await pump(tester);

      // L'ordine segue [WatchStatus.displayOrder]: quello che si sta guardando
      // prima di quello che e' finito. Con un elenco unico l'utente dovrebbe
      // scorrere per trovare gli anime da riprendere.
      final watching = tester.getTopLeft(find.text('Cowboy Bebop')).dy;
      final completed = tester.getTopLeft(find.text('Trigun')).dy;

      expect(watching, lessThan(completed));
    });

    testWidgets('il filtro per stato nasconde le altre voci', (tester) async {
      repo = FakeWatchlistRepository(initial: [
        buildWatchlistEntry(animeId: 'a1', title: 'Cowboy Bebop'),
        buildWatchlistEntry(
          animeId: 'a2',
          title: 'Trigun',
          status: WatchStatus.completed,
        ),
      ]);

      await pump(tester);
      // Il finder segue il componente: i filtri sono le `ArChip` del design
      // system, non i chip di Material. La verifica resta la stessa — il
      // filtro scelto mostra solo le voci in visione e nasconde le altre.
      await tester.tap(find.widgetWithText(ArChip, 'In visione'));
      await tester.pumpAndSettle();

      expect(find.text('Cowboy Bebop'), findsOneWidget);
      expect(find.text('Trigun'), findsNothing);
    });

    testWidgets('il filtro dei preferiti mostra solo i con la stella', (tester) async {
      repo = FakeWatchlistRepository(initial: [
        buildWatchlistEntry(animeId: 'a1', title: 'Cowboy Bebop'),
        buildWatchlistEntry(
          animeId: 'a2',
          title: 'Trigun',
          status: WatchStatus.completed,
          isFavorite: true,
        ),
      ]);

      await pump(tester);
      await tester.tap(find.widgetWithText(ArChip, 'Preferiti'));
      await tester.pumpAndSettle();

      expect(find.text('Trigun'), findsOneWidget);
      expect(find.text('Cowboy Bebop'), findsNothing);
    });

    testWidgets('mettersi tra i preferiti chiama il repository', (tester) async {
      repo = FakeWatchlistRepository(initial: [buildWatchlistEntry()]);
      await pump(tester);

      await tester.tap(find.byTooltip('Metti tra i preferiti'));
      await tester.pumpAndSettle();

      expect(repo.favoriteChanges, ['a1|true']);
    });

    testWidgets('cambiare stato passa dal menu', (tester) async {
      repo = FakeWatchlistRepository(initial: [buildWatchlistEntry()]);
      await pump(tester);

      await tester.tap(find.byTooltip('Altre azioni'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Completato').last);
      await tester.pumpAndSettle();

      expect(repo.statusChanges, ['a1|completed']);
    });

    testWidgets('il foglio episodi salva il numero scelto', (tester) async {
      repo = FakeWatchlistRepository(initial: [buildWatchlistEntry()]);
      await pump(tester);

      await tester.tap(find.text('5 / 12'));
      await tester.pumpAndSettle();

      expect(find.text('Episodi guardati'), findsOneWidget);
      await tester.tap(find.byTooltip('Un episodio in piu'));
      await tester.pumpAndSettle();

      expect(find.text('6 / 12'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Salva'));
      await tester.pumpAndSettle();

      expect(repo.episodeChanges, ['a1|6']);
    });

    testWidgets('annullare il foglio episodi non salva nulla', (tester) async {
      repo = FakeWatchlistRepository(initial: [buildWatchlistEntry()]);
      await pump(tester);

      await tester.tap(find.text('5 / 12'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Annulla'));
      await tester.pumpAndSettle();

      expect(repo.episodeChanges, isEmpty);
    });

    testWidgets('all ultimo episodio il pulsante avanti si blocca', (tester) async {
      repo = FakeWatchlistRepository(initial: [
        buildWatchlistEntry(currentEpisode: 12),
      ]);

      await pump(tester);
      await tester.tap(find.text('12 / 12'));
      await tester.pumpAndSettle();

      // Il totale e' il tetto del trigger del backend: oltre, la richiesta
      // verrebbe rifiutata, quindi il pulsante smette di funzionare invece di
      // lasciare scegliere un numero che non puo' essere salvato.
      final plus = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('Un episodio in piu'),
          matching: find.byType(IconButton),
        ),
      );
      expect(plus.onPressed, isNull);
    });

    testWidgets('rimuovere chiede conferma e poi cancella', (tester) async {
      repo = FakeWatchlistRepository(initial: [buildWatchlistEntry()]);
      await pump(tester);

      await tester.tap(find.byTooltip('Altre azioni'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rimuovi dalla watchlist'));
      await tester.pumpAndSettle();

      expect(find.text('Rimuovere dalla watchlist?'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Rimuovi'));
      await tester.pumpAndSettle();

      expect(repo.removed, ['a1']);
    });

    testWidgets('le cifre in alto arrivano dai totali', (tester) async {
      repo = FakeWatchlistRepository(initial: [buildWatchlistEntry()])
        ..totalsResult = const WatchlistTotals(
          entries: 3,
          watching: 2,
          completed: 1,
          episodes: 40,
        );

      await pump(tester);

      expect(find.text('In watchlist'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('40'), findsOneWidget);
    });

    testWidgets('un errore di caricamento offre il retry', (tester) async {
      repo = FakeWatchlistRepository()
        ..entriesFailure = const WatchlistFailure('Watchlist non disponibile.');
      await pump(tester);

      expect(find.text('Watchlist non disponibile.'), findsOneWidget);

      // Senza toccare il retry il messaggio non cambierebbe mai: l utente
      // rimarrebbe con lo stesso errore anche dopo che la rete e tornata.
      repo.entriesFailure = null;
      await tester.tap(find.widgetWithText(FilledButton, 'Riprova'));
      await tester.pumpAndSettle();

      expect(repo.entriesCalls, 2);
    });

    testWidgets('su schermo largo la watchlist diventa tabella', (tester) async {
      repo = FakeWatchlistRepository(initial: [buildWatchlistEntry()]);
      await pump(tester, size: const Size(1200, 900));

      expect(find.byType(DataTable), findsOneWidget);
      expect(find.text('Episodi'), findsOneWidget);
      expect(find.text('Preferito'), findsOneWidget);
    });

    testWidgets('su telefono la watchlist non e una tabella', (tester) async {
      repo = FakeWatchlistRepository(initial: [buildWatchlistEntry()]);
      await pump(tester);

      expect(find.byType(DataTable), findsNothing);
      expect(find.byTooltip('Altre azioni'), findsOneWidget);
    });

    testWidgets('aggiungere dalla classifica mette in visione', (tester) async {
      repo = FakeWatchlistRepository();
      final ranking = FakeRankingRepository(initial: [
        buildRankingEntry(animeId: 'a1', title: 'Cowboy Bebop'),
      ]);

      await pump(tester, ranking: ranking);
      await tester.tap(find.widgetWithText(FloatingActionButton, 'Aggiungi'));
      await tester.pumpAndSettle();

      expect(find.text('Aggiungi dalla classifica'), findsOneWidget);

      await tester.tap(find.byTooltip('Aggiungi Cowboy Bebop'));
      await tester.pumpAndSettle();

      expect(repo.statusChanges, ['a1|watching']);
      // Il pallino di fatto compare subito, senza aspettare che la watchlist
      // venga riletta dal server.
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });
  });

  group('rotta', () {
    test('il gruppo fa parte del percorso', () {
      // Il gruppo non puo' stare in `extra`: la schermata si aprirebbe anche da
      // un collegamento diretto, dove non c'e' nessun extra.
      expect(AppRoutes.watchlist('g1'), '/watchlist/g1');
    });
  });

  group('WatchlistRepository', () {
    test('il finto rispetta il contratto', () {
      expect(FakeWatchlistRepository(), isA<WatchlistRepository>());
    });
  });
}
