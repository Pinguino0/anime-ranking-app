import 'package:animerank/core/router/app_router.dart';
import 'package:animerank/features/duels/data/duels_repository.dart';
import 'package:animerank/features/duels/domain/duels.dart';
import 'package:animerank/features/duels/presentation/duels_controller.dart';
import 'package:animerank/features/duels/presentation/screens/duels_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'helpers/fake_duels.dart';

void main() {
  group('DuelPair.parse', () {
    test('i due contendenti arrivano gia uniti dalla RPC', () {
      final pair = DuelPair.parse({
        'anime_a_id': 'a1',
        'anime_b_id': 'a2',
        'title_a': 'Cowboy Bebop',
        'title_b': 'Trigun',
        'image_a': 'https://img/bebop.jpg',
        'image_b': null,
      });

      expect(pair.animeAId, 'a1');
      expect(pair.animeBId, 'a2');
      expect(pair.titleOf('a1'), 'Cowboy Bebop');
      expect(pair.titleOf('a2'), 'Trigun');
      expect(pair.imageOf('a1'), 'https://img/bebop.jpg');
      expect(pair.imageOf('a2'), isNull);
      expect(pair.isPlayable, isTrue);
    });

    test('una coppia senza secondi contendente non e giocabile', () {
      // Il fallback di `next_duel_pair` prende i due anime piu' votati: se il
      // gruppo ne ha uno solo, arriva una riga con il secondo id vuoto invece
      // di zero righe. Non e' un errore, ma non e nemmeno un duello.
      final pair = DuelPair.parse({
        'anime_a_id': 'a1',
        'anime_b_id': '',
        'title_a': 'Cowboy Bebop',
        'title_b': 'Senza titolo',
      });

      expect(pair.isPlayable, isFalse);
      expect(pair.validate('a1')?.message, 'Questa coppia non e giocabile.');
    });

    test('due anime uguali non sono una coppia valida', () {
      final pair = buildDuelPair(animeBId: 'a1');

      expect(pair.isPlayable, isFalse);
    });

    test('la scelta deve essere uno dei due contendenti', () {
      final pair = buildDuelPair();

      expect(pair.validate('a1'), isNull);
      expect(pair.validate('a2'), isNull);
      // Replica `duels_selected_in_pair`: inviare un terzo anime farebbe
      // fallire l'inserimento, quindi viene fermato prima.
      expect(pair.validate('a3')?.message, 'Scegli uno dei due anime.');
      expect(pair.validate(null)?.message, 'Scegli uno dei due anime.');
    });
  });

  group('DuelStanding.parse', () {
    test('elo e numero di duelli arrivano come interi', () {
      // Postgres restituisce `numeric` e `bigint` come numeri JSON: senza la
      // conversione esplicita un `1032.0` finirebbe stampato con il decimale.
      final standing = DuelStanding.parse({
        'anime_id': 'a1',
        'title': 'Cowboy Bebop',
        'elo': 1032,
        'duel_count': 7,
      }, position: 1);

      expect(standing.position, 1);
      expect(standing.elo, 1032);
      expect(standing.duelCount, 7);
      expect(standing.eloDelta, 32);
    });

    test('un elo in stringa viene letto lo stesso', () {
      final standing = DuelStanding.parse({
        'anime_id': 'a1',
        'title': 'Trigun',
        'elo': '968',
        'duel_count': '3',
      }, position: 4);

      expect(standing.elo, 968);
      expect(standing.duelCount, 3);
    });

    test('senza dati la riga ha comunque i valori iniziali', () {
      final standing = DuelStanding.parse({'anime_id': 'a1'}, position: 1);

      expect(standing.title, 'Senza titolo');
      // Il default e' il punto di partenza di `duel_elo`: mostrare 0 farebbe
      // sembrare un anime penalizzato invece che uno ancora senza duelli.
      expect(standing.elo, DuelElo.starting);
      expect(standing.duelCount, 0);
    });

    test('la variazione e\' rispetto al valore iniziale', () {
      expect(buildDuelStanding(elo: 1000).eloDelta, 0);
      expect(buildDuelStanding(elo: 1032).eloDelta, 32);
      expect(buildDuelStanding(elo: 968).eloDelta, -32);
    });
  });

  group('controller', () {
    late FakeDuelsRepository repo;
    late ProviderContainer container;

    Future<ProviderContainer> make() async {
      repo = FakeDuelsRepository(pairs: [buildDuelPair()]);
      container = ProviderContainer(
        overrides: [duelsRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('la coppia arriva dal repository', () async {
      final c = await make();

      expect((await c.read(duelPairProvider('g1').future))?.animeAId, 'a1');
      expect(repo.nextPairCalls, 1);
    });

    test('il gruppo vuoto non e un errore', () async {
      repo = FakeDuelsRepository();
      final c = ProviderContainer(
        overrides: [duelsRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(c.dispose);

      // `next_duel_pair` restituisce zero righe quando il gruppo non ha anime
      // votati: e uno stato legittimo della pagina, non un 500.
      expect(await c.read(duelPairProvider('g1').future), isNull);
    });

    test('dopo una scelta si ricarica solo la classifica', () async {
      final c = await make();
      final pair = await c.read(duelPairProvider('g1').future);

      await c.read(duelActionProvider.notifier).play(
            groupId: 'g1',
            pair: pair!,
            selectedAnimeId: 'a1',
          );

      expect(repo.played, ['a1/a2|a1']);

      // La coppia non viene ricaricata da sola: mostrerebbe subito un'altra
      // gara e l utente non vedrebbe il risultato della propria scelta.
      expect(repo.nextPairCalls, 1);
      expect((await c.read(duelStandingsProvider('g1').future)).first.elo, greaterThan(DuelElo.starting));
    });

    test('la coppia successiva esclude quella appena giocata', () async {
      repo = FakeDuelsRepository(pairs: [
        buildDuelPair(),
        buildDuelPair(animeAId: 'a2', animeBId: 'a3', titleA: 'Trigun', titleB: 'Evangelion'),
      ]);
      container = ProviderContainer(
        overrides: [duelsRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
      final c = container;

      final pair = await c.read(duelPairProvider('g1').future);
      await c.read(duelActionProvider.notifier).play(
            groupId: 'g1',
            pair: pair!,
            selectedAnimeId: 'a2',
          );

      await c.read(duelPairProvider('g1').notifier).next();

      final next = await c.read(duelPairProvider('g1').future);
      expect(next?.animeAId, 'a2');
      expect(next?.animeBId, 'a3');
    });

    test('una scelta rifiutata non viene data per registrata', () async {
      final c = await make();
      repo.playFailure = const DuelsFailure('Permessi insufficienti.');
      final pair = await c.read(duelPairProvider('g1').future);

      await expectLater(
        c.read(duelActionProvider.notifier).play(
          groupId: 'g1',
          pair: pair!,
          selectedAnimeId: 'a1',
        ),
        throwsA(isA<DuelsFailure>()),
      );

      // La classifica non viene riletta: mostrerebbe gli stessi numeri come se
      // il duello fosse andato a buon fine.
      expect(repo.standingsCalls, 0);
      expect(c.read(duelActionProvider).hasError, isTrue);
    });

    test('la scelta di un anime fuori coppia non arriva al backend', () async {
      final c = await make();
      final pair = await c.read(duelPairProvider('g1').future);

      await expectLater(
        c.read(duelActionProvider.notifier).play(
          groupId: 'g1',
          pair: pair!,
          selectedAnimeId: 'a9',
        ),
        throwsA(isA<DuelsFailure>()),
      );

      expect(repo.played, isEmpty);
    });
  });

  group('schermata', () {
    late FakeDuelsRepository repo;

    setUp(() => repo = FakeDuelsRepository());

    Future<void> pump(
      WidgetTester tester, {
      FakeDuelsRepository? repository,
      Size size = const Size(500, 900),
    }) async {
      final r = repository ?? repo;

      final router = GoRouter(
        initialLocation: '/duels/g1',
        routes: [
          GoRoute(
            path: '/duels/:groupId',
            builder: (_, state) => DuelsScreen(
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
            overrides: [duelsRepositoryProvider.overrideWithValue(r)],
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('un gruppo senza duelli spiega cosa serve', (tester) async {
      await pump(tester);

      expect(find.text('Non ci sono anime da mettere in duello'), findsOneWidget);
      expect(find.textContaining('classifica'), findsWidgets);
    });

    testWidgets('la coppia mostra i due contendenti', (tester) async {
      repo = FakeDuelsRepository(pairs: [buildDuelPair()]);
      await pump(tester);

      expect(find.text('Cowboy Bebop'), findsOneWidget);
      expect(find.text('Trigun'), findsOneWidget);
      expect(find.text('Prossima coppia'), findsNothing);
    });

    testWidgets('scegliere un anime registra il duello e mostra il risultato', (tester) async {
      repo = FakeDuelsRepository(pairs: [buildDuelPair()]);
      await pump(tester);

      await tester.tap(find.text('Cowboy Bebop'));
      await tester.pumpAndSettle();

      expect(repo.played, ['a1/a2|a1']);
      expect(find.text('Hai scelto Cowboy Bebop'), findsOneWidget);
      expect(find.text('Prossima coppia'), findsOneWidget);
    });

    testWidgets('la stessa coppia non si può votare due volte', (tester) async {
      repo = FakeDuelsRepository(pairs: [buildDuelPair()]);
      await pump(tester);

      await tester.tap(find.text('Cowboy Bebop'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trigun'));
      await tester.pumpAndSettle();

      // `duels` e' append-only e senza vincoli di unicita': un secondo tocco
      // sulla coppia gia' giocata aggiungerebbe un duello falso agli Elo, e
      // dal backend passerebbe senza errori.
      expect(repo.played, ['a1/a2|a1']);
    });

    testWidgets('un errore del backend non lascia la scelta a schermo', (tester) async {
      repo = FakeDuelsRepository(pairs: [buildDuelPair()])
        ..playFailure = const DuelsFailure('Permessi insufficienti.');
      await pump(tester);

      await tester.tap(find.text('Cowboy Bebop'));
      await tester.pumpAndSettle();

      expect(find.text('Permessi insufficienti.'), findsOneWidget);
      expect(find.text('Hai scelto Cowboy Bebop'), findsNothing);
    });

    testWidgets('la coppia successiva azzera il risultato precedente', (tester) async {
      repo = FakeDuelsRepository(pairs: [
        buildDuelPair(),
        buildDuelPair(animeAId: 'a2', animeBId: 'a3', titleA: 'Trigun', titleB: 'Evangelion'),
      ]);
      await pump(tester);

      await tester.tap(find.text('Cowboy Bebop'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Prossima coppia'));
      await tester.pumpAndSettle();

      expect(find.text('Hai scelto Cowboy Bebop'), findsNothing);
      expect(find.text('Evangelion'), findsOneWidget);
    });

    testWidgets('la classifica Elo si aggiorna dopo la scelta', (tester) async {
      repo = FakeDuelsRepository(pairs: [buildDuelPair()]);
      await pump(tester);
      await tester.tap(find.text('Elo'));
      await tester.pumpAndSettle();

      expect(find.text('Classifica Elo vuota'), findsOneWidget);

      await tester.tap(find.text('Sfida'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cowboy Bebop'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Elo'));
      await tester.pumpAndSettle();

      expect(find.text('Cowboy Bebop'), findsOneWidget);
      // Entrambi gli anime hanno giocato una volta, quindi "1 duello" compare
      // due volte: una riga per contendente.
      expect(find.text('1 duello'), findsNWidgets(2));
      // Primo duello fra due anime a 1000: ognuno ne prende meta' dei 32 punti
      // massimi, quindi +16 e non +32. Aspettarsi 32 qui nasconderebbe un
      // errore nella formula, non un arrotondamento.
      expect(find.text('+16'), findsOneWidget);
      expect(find.text('-16'), findsOneWidget);
    });

    testWidgets('su schermo largo gli Elo diventano tabella', (tester) async {
      repo = FakeDuelsRepository(standings: [
        buildDuelStanding(position: 1, animeId: 'a1', title: 'Cowboy Bebop', elo: 1032, duelCount: 7),
        buildDuelStanding(position: 2, animeId: 'a2', title: 'Trigun', elo: 968, duelCount: 7),
      ]);
      await pump(tester, size: const Size(1200, 900));

      await tester.tap(find.text('Elo'));
      await tester.pumpAndSettle();

      expect(find.byType(DataTable), findsOneWidget);
      // "Duelli" e' anche il nome della scheda: l'intestazione va cercata dentro
      // la tabella, altrimenti l'asserzione passerebbe anche senza colonne.
      expect(
        find.descendant(of: find.byType(DataTable), matching: find.text('Duelli')),
        findsOneWidget,
      );
    });

    testWidgets('su telefono gli Elo sono una lista', (tester) async {
      repo = FakeDuelsRepository(standings: [buildDuelStanding()]);
      await pump(tester);

      await tester.tap(find.text('Elo'));
      await tester.pumpAndSettle();

      expect(find.byType(DataTable), findsNothing);
      expect(find.text('0 duelli'), findsOneWidget);
    });

    testWidgets('un errore di caricamento offre il retry', (tester) async {
      repo = FakeDuelsRepository()..nextPairFailure = const DuelsFailure('Coppia non disponibile.');
      await pump(tester);

      expect(find.text('Coppia non disponibile.'), findsOneWidget);

      // Senza toccare il retry il messaggio non cambierebbe mai.
      repo.nextPairFailure = null;
      await tester.tap(find.widgetWithText(FilledButton, 'Riprova'));
      await tester.pumpAndSettle();

      expect(repo.nextPairCalls, 2);
    });

    testWidgets('il ricarica in alto aggiorna entrambe le schede', (tester) async {
      repo = FakeDuelsRepository(pairs: [buildDuelPair()]);
      await pump(tester);

      await tester.tap(find.byTooltip('Ricarica'));
      await tester.pumpAndSettle();

      // Solo la coppia ricaricata sarebbe un refresh a meta': l'utente che
      // torna sulla classifica troverebbe numeri vecchi senza averlo chiesto.
      expect(repo.nextPairCalls, 2);
      expect(repo.standingsCalls, greaterThan(0));
    });
  });

  group('rotta', () {
    test('il gruppo fa parte del percorso', () {
      expect(AppRoutes.duels('g1'), '/duels/g1');
    });
  });

  group('DuelsRepository', () {
    test('il finto rispetta il contratto', () {
      expect(FakeDuelsRepository(), isA<DuelsRepository>());
    });
  });
}
