import 'package:animerank/core/router/app_router.dart';
import 'package:animerank/features/ranking/domain/ranking.dart';
import 'package:animerank/features/ranking/presentation/ranking_controller.dart';
import 'package:animerank/features/tournaments/data/tournaments_repository.dart';
import 'package:animerank/features/tournaments/domain/tournaments.dart';
import 'package:animerank/features/tournaments/presentation/screens/tournament_detail_screen.dart';
import 'package:animerank/features/tournaments/presentation/screens/tournaments_screen.dart';
import 'package:animerank/features/tournaments/presentation/tournaments_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'helpers/fake_ranking.dart';
import 'helpers/fake_tournaments.dart';

void main() {
  group('Tournament', () {
    test('i dati arrivano con autore e campione uniti', () {
      final tournament = Tournament.parse({
        'id': 't1',
        'group_id': 'g1',
        'name': 'Coppa del venerdi',
        'status': 'completed',
        'bracket_size': 8,
        'created_by': 'u1',
        'champion_anime_id': 'a1',
        'created_at': '2026-01-02T03:04:05Z',
        'completed_at': '2026-01-03T03:04:05Z',
        'creator': {'username': 'marco'},
        'champion': {'title': 'Cowboy Bebop', 'image_url': 'https://img/bebop.jpg'},
      });

      expect(tournament.name, 'Coppa del venerdi');
      expect(tournament.status, TournamentStatus.completed);
      expect(tournament.isCompleted, isTrue);
      expect(tournament.creatorName, 'marco');
      expect(tournament.championTitle, 'Cowboy Bebop');
      expect(tournament.createdAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
    });

    test('il campione mostra il titolo italiano quando c e', () {
      final withIt = Tournament.parse({
        'id': 't1',
        'group_id': 'g1',
        'name': 'Coppa',
        'status': 'completed',
        'bracket_size': 4,
        'champion_anime_id': 'a1',
        'champion': {'title': 'Shingeki no Kyojin', 'title_it': "L'attacco dei giganti"},
      });
      expect(withIt.championTitleIt, "L'attacco dei giganti");
      expect(withIt.championDisplayTitle, "L'attacco dei giganti");

      final noIt = Tournament.parse({
        'id': 't1',
        'group_id': 'g1',
        'name': 'Coppa',
        'status': 'completed',
        'bracket_size': 4,
        'champion_anime_id': 'a1',
        'champion': {'title': 'Cowboy Bebop'},
      });
      expect(noIt.championTitleIt, isNull);
      expect(noIt.championDisplayTitle, 'Cowboy Bebop');
    });

    test('senza campione il torneo non e concluso', () {
      final tournament = Tournament.parse({
        'id': 't1',
        'group_id': 'g1',
        'name': 'Coppa',
        'status': 'ongoing',
        'bracket_size': 4,
        'champion_anime_id': null,
        'champion': null,
      });

      expect(tournament.isCompleted, isFalse);
      expect(tournament.championTitle, isNull);
      expect(tournament.creatorName, isNull);
    });

    test('uno stato sconosciuto non blocca la schermata', () {
      // Una versione futura del backend potrebbe aggiungere uno stato: senza il
      // fallback la lista mostrerebbe "In corso" per qualcosa di diverso, che e'
      // meglio che far crashare la pagina.
      expect(TournamentStatus.fromWire('qualcosa'), TournamentStatus.ongoing);
      expect(TournamentStatus.fromWire(null), TournamentStatus.ongoing);
      expect(TournamentStatus.fromWire('setup'), TournamentStatus.setup);
    });

    test('i turni sono il log2 della taglia', () {
      // Un bracket da 8 ha 3 turni, da 16 ne ha 4: e' la formula di
      // `create_tournament`, quindi il numero non si deduce leggendo le righe.
      expect(buildTournament(bracketSize: 2).rounds, 1);
      expect(buildTournament(bracketSize: 4).rounds, 2);
      expect(buildTournament(bracketSize: 8).rounds, 3);
      expect(buildTournament(bracketSize: 16).rounds, 4);
    });
  });

  group('TournamentBracket.parse', () {
    test('le partite si raggruppano per turno e si ordinano', () {
      final bracket = TournamentBracket.parse(
        tournament: buildTournament(bracketSize: 4),
        matchRows: [
          {
            'id': 'm3',
            'round_number': 2,
            'match_number': 1,
            'status': 'pending',
          },
          {
            'id': 'm1',
            'round_number': 1,
            'match_number': 2,
            'status': 'pending',
            'anime_a_id': 'a3',
            'anime_b_id': 'a4',
          },
          {
            'id': 'm2',
            'round_number': 1,
            'match_number': 1,
            'status': 'pending',
            'anime_a_id': 'a1',
            'anime_b_id': 'a2',
          },
        ],
      );

      expect(bracket.rounds.map((r) => r.number), [1, 2]);
      expect(bracket.rounds.first.matches.map((m) => m.id), ['m2', 'm1']);
      expect(bracket.matchesCount, 3);
      // Solo il primo turno ha i contendenti: gli altri sono generati vuoti e
      // non si possono votare.
      expect(bracket.openMatches, 2);
    });

    test('i contendenti mostrano il titolo italiano quando c e', () {
      final match = TournamentMatch.parse({
        'id': 'm1',
        'round_number': 1,
        'match_number': 1,
        'status': 'pending',
        'anime_a_id': 'a1',
        'anime_b_id': 'a2',
        'anime_a': {'title': 'Shingeki no Kyojin', 'title_it': "L'attacco dei giganti"},
        'anime_b': {'title': 'Trigun'},
      });

      expect(match.animeADisplayTitle, "L'attacco dei giganti");
      expect(match.animeBDisplayTitle, 'Trigun');
    });

    test('il nome del turno usa la posizione nel bracket', () {
      final bracket = TournamentBracket.parse(
        tournament: buildTournament(bracketSize: 8),
        matchRows: [
          {'id': 'm4', 'round_number': 1, 'match_number': 1, 'status': 'pending'},
          {'id': 'm2', 'round_number': 2, 'match_number': 1, 'status': 'pending'},
          {'id': 'm1', 'round_number': 3, 'match_number': 1, 'status': 'pending'},
        ],
      );

      expect(bracket.rounds.map((r) => r.label), ['Turno 1', 'Semifinali', 'Finale']);
    });

    test('in un bracket da 4 il primo turno e gia la semifinale', () {
      final bracket = TournamentBracket.parse(
        tournament: buildTournament(bracketSize: 4),
        matchRows: [
          {'id': 'm2', 'round_number': 1, 'match_number': 1, 'status': 'pending'},
          {'id': 'm1', 'round_number': 2, 'match_number': 1, 'status': 'pending'},
        ],
      );

      // Quattro anime sono due semifinali e una finale: chiamare il primo turno
      // "Turno 1" sarebbe solo un nome generico.
      expect(bracket.rounds.map((r) => r.label), ['Semifinali', 'Finale']);
    });

    test('gli scontri senza contendenti non sono votabili', () {
      // Il bracket viene generato tutto all'inizio: dal secondo turno le
      // partite esistono ma sono vuote, e votare per un posto libero non
      // avrebbe senso.
      final match = TournamentMatch.parse({
        'id': 'm1',
        'round_number': 2,
        'match_number': 1,
        'status': 'pending',
        'anime_a_id': 'a1',
      });

      expect(match.isVotable, isFalse);
      expect(match.hasContender('a1'), isTrue);
      expect(match.hasContender('a9'), isFalse);
      expect(match.hasContender(null), isFalse);
    });

    test('uno scontro finito non e votabile e ha un vincitore', () {
      final match = TournamentMatch.parse({
        'id': 'm1',
        'round_number': 1,
        'match_number': 1,
        'status': 'finished',
        'anime_a_id': 'a1',
        'anime_b_id': 'a2',
        'winner_anime_id': 'a2',
      });

      expect(match.isFinished, isTrue);
      expect(match.isVotable, isFalse);
      expect(match.isWinner('a2'), isTrue);
      expect(match.isWinner('a1'), isFalse);
    });

    test('il tabellone sa se c e un campione', () {
      final bracket = TournamentBracket.parse(
        tournament: buildTournament(
          status: TournamentStatus.completed,
          championAnimeId: 'a1',
          championTitle: 'Cowboy Bebop',
        ),
        matchRows: const [],
      );

      expect(bracket.hasChampion, isTrue);
    });
  });

  group('tallyMatches', () {
    final match = buildMatch(id: 'm1', animeAId: 'a1', animeBId: 'a2');
    final other = buildMatch(id: 'm2', roundNumber: 2, matchNumber: 1, animeAId: null, animeBId: null);

    test('i voti si contano a schiera, non per id', () {
      final tallies = tallyMatches(
        matches: [match],
        votes: [
          buildVote(matchId: 'm1', userId: 'u1', animeId: 'a2'),
          buildVote(matchId: 'm1', userId: 'u2', animeId: 'a2'),
          buildVote(matchId: 'm1', userId: 'u3', animeId: 'a1'),
        ],
        currentUserId: 'u1',
      );

      expect(tallies['m1']!.votesA, 1);
      expect(tallies['m1']!.votesB, 2);
      expect(tallies['m1']!.total, 3);
      expect(tallies['m1']!.votesFor(match, 'a2'), 2);
      expect(tallies['m1']!.votesFor(match, 'a9'), 0);
      expect(tallies['m1']!.votesFor(match, null), 0);
    });

    test('il proprio voto e distinto dagli altri', () {
      final tallies = tallyMatches(
        matches: [match],
        votes: [
          buildVote(matchId: 'm1', userId: 'u2', animeId: 'a2'),
          buildVote(matchId: 'm1', userId: 'u1', animeId: 'a1'),
        ],
        currentUserId: 'u1',
      );

      expect(tallies['m1']!.myAnimeId, 'a1');
      expect(tallies['m1']!.isMine('a1'), isTrue);
      expect(tallies['m1']!.isMine('a2'), isFalse);
    });

    test('chi non ha votato non ha un voto proprio', () {
      final tallies = tallyMatches(
        matches: [match],
        votes: [buildVote(matchId: 'm1', userId: 'u2', animeId: 'a1')],
        currentUserId: 'u1',
      );

      expect(tallies['m1']!.myAnimeId, isNull);
      expect(tallies['m1']!.votesA, 1);
    });

    test('un voto su un anime fuori scontro viene scartato', () {
      // Il CHECK del database lo impedisce, ma un voto rimasto indietro dopo
      // un cambio del bracket non deve comparire come voto per il posto libero.
      final tallies = tallyMatches(
        matches: [match, other],
        votes: [buildVote(matchId: 'm1', userId: 'u1', animeId: 'a9')],
        currentUserId: 'u1',
      );

      expect(tallies['m1']!.total, 0);
      expect(tallies['m1']!.myAnimeId, isNull);
      // Ogni scontro ha una voce anche senza voti: la schermata non deve
      // distinguere "nessun voto" da "scontro assente".
      expect(tallies['m2']!.total, 0);
    });
  });

  group('TournamentValidators', () {
    test('il nome vuoto o troppo lungo viene respinto', () {
      expect(TournamentValidators.nameError(''), isNotNull);
      expect(TournamentValidators.nameError('   '), isNotNull);
      expect(TournamentValidators.nameError('a' * 61), isNotNull);
      expect(TournamentValidators.nameError('Coppa'), isNull);
      // Il trim non conta: `tournaments_name_length` guarda il nome pulito.
      expect(TournamentValidators.nameError('  Coppa  '), isNull);
    });

    test('la lista deve essere una potenza di due ammessa', () {
      expect(TournamentValidators.participantsError(['a1', 'a2']), isNull);
      expect(TournamentValidators.participantsError(['a1', 'a2', 'a3', 'a4']), isNull);
      // Con 3 anime il bracket non si chiuderebbe: `create_tournament` lo
      // rifiuta con "deve essere 2, 4, 8 o 16".
      expect(TournamentValidators.participantsError(['a1', 'a2', 'a3']), isNotNull);
      expect(TournamentValidators.participantsError(['a1']), isNotNull);
    });

    test('gli anime ripetuti vengono respinti', () {
      expect(
        TournamentValidators.participantsError(['a1', 'a1']),
        'Nella lista ci sono anime duplicati.',
      );
    });

    test('la taglia piu vicina sceglie senza far decidere a mano', () {
      expect(TournamentValidators.nearestBracketSize(1), 2);
      expect(TournamentValidators.nearestBracketSize(3), 4);
      // A parita' si sale: 3 scelte vanno a 4 e 6 a 8, perche' aggiungere un anime
      // scelto col dito e' meno distrutivo che scartarne uno.
      expect(TournamentValidators.nearestBracketSize(3), 4);
      expect(TournamentValidators.nearestBracketSize(6), 8);
      expect(TournamentValidators.nearestBracketSize(10), 8);
      expect(TournamentValidators.nearestBracketSize(14), 16);
      expect(TournamentValidators.nearestBracketSize(0), 2);
    });
  });

  group('TournamentStanding.parse', () {
    test('le cifre arrivano come interi', () {
      final standing = TournamentStanding.parse({
        'anime_id': 'a1',
        'title': 'Cowboy Bebop',
        'is_out': true,
        'matches_won': 3,
        'votes_received': 12,
        'image_url': 'https://img/bebop.jpg',
      });

      expect(standing.isOut, isTrue);
      expect(standing.matchesWon, 3);
      expect(standing.votesReceived, 12);
      expect(standing.imageUrl, 'https://img/bebop.jpg');
    });

    test('senza dati la riga ha valori sensati', () {
      final standing = TournamentStanding.parse({'anime_id': 'a1'});

      expect(standing.title, 'Senza titolo');
      expect(standing.isOut, isFalse);
      expect(standing.matchesWon, 0);
    });

    test('displayTitle preferisce title_it', () {
      final withIt = TournamentStanding.parse({
        'anime_id': 'a1',
        'title': 'Shingeki no Kyojin',
        'title_it': "L'attacco dei giganti",
      });
      expect(withIt.italianTitle, "L'attacco dei giganti");
      expect(withIt.displayTitle, "L'attacco dei giganti");

      final noIt = TournamentStanding.parse({'anime_id': 'a1', 'title': 'Trigun'});
      expect(noIt.displayTitle, 'Trigun');
    });
  });

  group('controller', () {
    late FakeTournamentsRepository repo;
    late ProviderContainer container;

    ProviderContainer make() {
      repo = FakeTournamentsRepository(
        tournaments: [buildTournament()],
        matches: [buildMatch()],
        standings: [buildStanding()],
      );
      container = ProviderContainer(
        overrides: [tournamentsRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('i tornei arrivano dal repository', () async {
      final c = make();

      expect((await c.read(tournamentsProvider('g1').future)).length, 1);
      expect(repo.listCalls, 1);
    });

    test('il tabellone porta con se i propri voti', () async {
      repo = FakeTournamentsRepository(
        tournaments: [buildTournament()],
        matches: [buildMatch(id: 'm1')],
        votes: [
          buildVote(matchId: 'm1', userId: 'u1', animeId: 'a2'),
          buildVote(matchId: 'm1', userId: 'u2', animeId: 'a1'),
        ],
      );
      final c = ProviderContainer(
        overrides: [tournamentsRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(c.dispose);

      final tallies = await c.read(tournamentVotesProvider('t1').future);

      expect(tallies['m1']!.total, 2);
      expect(tallies['m1']!.myAnimeId, 'a2');
      // I voti hanno bisogno degli id degli scontri: senza il tabellone non si
      // sa cosa chiedere al server.
      expect(repo.bracketCalls, greaterThan(0));
    });

    test('un voto chiuso rillega tabellone e classifica', () async {
      final c = make();
      repo.memberCount = 1;

      final closed = await c.read(tournamentActionProvider.notifier).vote(
            tournamentId: 't1',
            matchId: 'm1',
            animeId: 'a1',
          );

      expect(closed, isTrue);
      expect(repo.castVotes, ['m1|a1']);

      await c.read(tournamentBracketProvider('t1').future);
      await c.read(tournamentVotesProvider('t1').future);
      // Va letta dopo il voto: invalidare un provider non letto non chiede
      // niente al server, quindi il conteggio delle chiamate deve cambiare qui
      // per provare che la invalidazione c'e' stata.
      final standings = await c.read(tournamentStandingsProvider('t1').future);

      expect(standings.single.title, 'Cowboy Bebop');
      expect(repo.standingsCalls, 1);
    });

    test('un voto che non chiude lo scontro non tocca la classifica', () async {
      final c = make();
      repo.memberCount = 3;

      final closed = await c.read(tournamentActionProvider.notifier).vote(
            tournamentId: 't1',
            matchId: 'm1',
            animeId: 'a1',
          );

      expect(closed, isFalse);

      await c.read(tournamentBracketProvider('t1').future);
      await c.read(tournamentVotesProvider('t1').future);

      expect(repo.standingsCalls, 0);
    });

    test('un voto rifiutato non viene dato per registrato', () async {
      final c = make();
      repo.voteFailure = const TournamentsFailure('Questo scontro e gia finito');

      await expectLater(
        c.read(tournamentActionProvider.notifier).vote(
          tournamentId: 't1',
          matchId: 'm1',
          animeId: 'a1',
        ),
        throwsA(isA<TournamentsFailure>()),
      );

      expect(repo.castVotes, isEmpty);
      expect(c.read(tournamentActionProvider).hasError, isTrue);
    });

    test('creare un torneo genera le partite del primo turno', () async {
      final c = make();

      final tournament = await c.read(tournamentActionProvider.notifier).create(
            groupId: 'g1',
            name: 'Coppa',
            animeIds: const ['a1', 'a2', 'a3', 'a4'],
          );

      expect(repo.created, ['Coppa|4']);
      expect(tournament.bracketSize, 4);

      final bracket = await c.read(tournamentBracketProvider(tournament.id).future);
      expect(bracket.matchesCount, 2);
      expect(bracket.rounds.first.matches.first.animeAId, 'a1');
      // La lista del gruppo cambia: senza invalidarla il torneo nuovo non
      // comparirebbe fino al ricaricamento manuale.
      expect((await c.read(tournamentsProvider('g1').future)).length, 2);
    });

    test('una lista non valida non arriva al backend', () async {
      final c = make();

      await expectLater(
        c.read(tournamentActionProvider.notifier).create(
          groupId: 'g1',
          name: 'Coppa',
          animeIds: const ['a1', 'a2', 'a3'],
        ),
        throwsA(isA<TournamentsFailure>()),
      );

      expect(repo.created, isEmpty);
    });

    test('eliminare un torneo lo toglie anche dalla lista', () async {
      final c = make();

      await c.read(tournamentActionProvider.notifier).delete(
            groupId: 'g1',
            tournamentId: 't1',
          );

      expect(repo.deleted, ['t1']);
      expect(await c.read(tournamentsProvider('g1').future), isEmpty);
    });
  });

  group('schermata lista', () {
    late FakeTournamentsRepository repo;

    setUp(() => repo = FakeTournamentsRepository());

    Future<void> pump(
      WidgetTester tester, {
      FakeTournamentsRepository? repository,
      FakeRankingRepository? ranking,
      Size size = const Size(500, 900),
    }) async {
      final r = repository ?? repo;

      final router = GoRouter(
        initialLocation: '/tournaments/g1',
        routes: [
          GoRoute(
            path: '/tournaments/:groupId',
            builder: (_, state) => TournamentsScreen(
              groupId: state.pathParameters['groupId']!,
              groupName: state.extra as String?,
            ),
            routes: [
              GoRoute(
                path: ':tournamentId',
                builder: (_, state) => TournamentDetailScreen(
                  tournamentId: state.pathParameters['tournamentId']!,
                  groupId: state.pathParameters['groupId']!,
                  canDelete: state.extra as bool? ?? false,
                ),
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size),
          child: ProviderScope(
            overrides: [
              tournamentsRepositoryProvider.overrideWithValue(r),
              // Serve al foglio di creazione: senza l'override il provider
              // vero lancerebbe appena il foglio si apre.
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

    testWidgets('un gruppo senza tornei spiega come lanciarne uno', (tester) async {
      await pump(tester);

      expect(find.text('Nessun torneo in questo gruppo'), findsOneWidget);
      expect(find.textContaining('eliminazione diretta'), findsOneWidget);
      expect(find.widgetWithText(FloatingActionButton, 'Nuovo torneo'), findsOneWidget);
    });

    testWidgets('la lista mostra stato, taglia e autore', (tester) async {
      repo = FakeTournamentsRepository(
        tournaments: [buildTournament(name: 'Coppa estiva', bracketSize: 16)],
      );
      await pump(tester);

      expect(find.text('Coppa estiva'), findsOneWidget);
      expect(find.text('16 anime · 4 turni · di marco'), findsOneWidget);
      expect(find.text('In corso'), findsOneWidget);
    });

    testWidgets('un torneo concluso mostra il campione', (tester) async {
      repo = FakeTournamentsRepository(
        tournaments: [
          buildTournament(
            status: TournamentStatus.completed,
            championAnimeId: 'a1',
            championTitle: 'Cowboy Bebop',
          ),
        ],
      );
      await pump(tester);

      expect(find.text('Concluso'), findsOneWidget);
      expect(find.text('Campione: Cowboy Bebop'), findsOneWidget);
    });

    testWidgets('un errore di caricamento offre il retry', (tester) async {
      repo = FakeTournamentsRepository()
        ..listFailure = const TournamentsFailure('Tornei non disponibili. Riprova.');
      await pump(tester);

      expect(find.text('Tornei non disponibili. Riprova.'), findsOneWidget);

      repo.listFailure = null;
      await tester.tap(find.widgetWithText(FilledButton, 'Riprova'));
      await tester.pumpAndSettle();

      expect(repo.listCalls, 2);
    });

    testWidgets('il foglio di creazione chiede un numero valido di anime', (tester) async {
      await pump(tester, ranking: FakeRankingRepository(initial: [
        buildRankingEntry(animeId: 'a1', title: 'Cowboy Bebop'),
        buildRankingEntry(animeId: 'a2', title: 'Trigun'),
        buildRankingEntry(animeId: 'a3', title: 'Evangelion'),
      ]));

      await tester.tap(find.widgetWithText(FloatingActionButton, 'Nuovo torneo'));
      await tester.pumpAndSettle();

      expect(find.text('Anime scelti: 0'), findsOneWidget);
      // Con zero scelte non c'e' ancora nulla da segnalare: l'errore mostrerebbe
      // "potenza di due" per una lista che l'utente non ha ancora scritto.
      expect(find.textContaining('potenza di due'), findsNothing);

      for (final title in ['Cowboy Bebop', 'Trigun', 'Evangelion']) {
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
      }

      expect(find.text('Anime scelti: 3'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Lancia')).onPressed,
        isNull,
      );
    });

    testWidgets('senza scelte il foglio spiega cosa manca', (tester) async {
      await pump(tester, ranking: FakeRankingRepository(initial: [
        buildRankingEntry(animeId: 'a1', title: 'Cowboy Bebop'),
      ]));

      await tester.tap(find.widgetWithText(FloatingActionButton, 'Nuovo torneo'));
      await tester.pumpAndSettle();

      // Con un solo anime votato il gruppo non puo' ospitare un torneo: senza
      // questo messaggio il pulsante "Lancia" sembrerebbe semplicemente rotto.
      expect(find.text('Anime scelti: 0'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Lancia')).onPressed,
        isNull,
      );
    });

    testWidgets('un gruppo senza anime votati spiega il motivo', (tester) async {
      await pump(tester);

      await tester.tap(find.widgetWithText(FloatingActionButton, 'Nuovo torneo'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Il gruppo non ha anime votati'), findsOneWidget);
    });

    testWidgets('lanciare un torneo apre subito il tabellone', (tester) async {
      repo = FakeTournamentsRepository();
      await pump(
        tester,
        ranking: FakeRankingRepository(initial: [
          buildRankingEntry(animeId: 'a1', title: 'Cowboy Bebop'),
          buildRankingEntry(animeId: 'a2', title: 'Trigun'),
        ]),
      );

      await tester.tap(find.widgetWithText(FloatingActionButton, 'Nuovo torneo'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Coppa del venerdi');
      await tester.tap(find.text('Cowboy Bebop'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trigun'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Lancia'));
      await tester.pumpAndSettle();

      expect(repo.created, ['Coppa del venerdi|2']);
    });
  });

  group('schermata tabellone', () {
    late FakeTournamentsRepository repo;

    setUp(() => repo = FakeTournamentsRepository());

    Future<void> pump(
      WidgetTester tester, {
      FakeTournamentsRepository? repository,
      FakeRankingRepository? ranking,
      Size size = const Size(500, 900),
    }) async {
      final r = repository ?? repo;

      final router = GoRouter(
        initialLocation: '/tournaments/g1/t1',
        routes: [
          GoRoute(
            path: '/tournaments/:groupId/:tournamentId',
            builder: (_, state) => TournamentDetailScreen(
              tournamentId: state.pathParameters['tournamentId']!,
              groupId: state.pathParameters['groupId']!,
              canDelete: state.extra as bool? ?? false,
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
              tournamentsRepositoryProvider.overrideWithValue(r),
              // Il numero di membri arriva dal repository della classifica: senza
              // l'override il tabellone crasherebbe appena aperto.
              rankingRepositoryProvider.overrideWithValue(
                ranking ?? FakeRankingRepository()..statsResult = const GroupStats(memberCount: 3),
              ),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('il tabellone mostra i turni con i loro nomi', (tester) async {
      repo = FakeTournamentsRepository(
        tournaments: [buildTournament(bracketSize: 4)],
        matches: [
          buildMatch(id: 'm1', roundNumber: 1, matchNumber: 1),
          buildMatch(id: 'm2', roundNumber: 1, matchNumber: 2,
              animeAId: 'a3', animeBId: 'a4', animeATitle: 'Evangelion', animeBTitle: 'Berserk'),
          buildMatch(id: 'm3', roundNumber: 2, matchNumber: 1,
              animeAId: null, animeBId: null, animeATitle: null, animeBTitle: null),
        ],
      );
      await pump(tester);

      expect(find.text('Semifinali'), findsOneWidget);
      expect(find.text('Finale'), findsOneWidget);
      expect(find.text('Cowboy Bebop'), findsOneWidget);
      expect(find.text('Berserk'), findsOneWidget);
      // Le partite dei turni successivi esistono ma non hanno contendenti.
      expect(find.text('Da decidere'), findsNWidgets(2));
      expect(find.text('In attesa dei vincitori'), findsOneWidget);
    });

    testWidgets('i voti mancanti vengono mostrati', (tester) async {
      repo = FakeTournamentsRepository(
        tournaments: [buildTournament()],
        matches: [buildMatch(id: 'm1')],
        votes: [buildVote(matchId: 'm1', userId: 'u2', animeId: 'a2')],
      );
      await pump(tester);

      // 3 membri, un voto: la partita non puo' chiudersi e l'utente deve
      // vedere quanto manca, altrimenti crede che il suo voto basti.
      expect(find.text('Vota per chi preferisci · 1/3'), findsOneWidget);
    });

    testWidgets('votare registra il voto e avvisa che mancano gli altri', (tester) async {
      repo = FakeTournamentsRepository(
        tournaments: [buildTournament()],
        matches: [buildMatch(id: 'm1')],
      )..memberCount = 3;
      await pump(tester);

      await tester.tap(find.text('Cowboy Bebop'));
      await tester.pumpAndSettle();

      expect(repo.castVotes, ['m1|a1']);
      expect(
        find.text('Voto registrato. Manca il voto degli altri membri.'),
        findsOneWidget,
      );
      expect(find.text('Hai votato · 1/3'), findsOneWidget);
    });

    testWidgets('l ultimo voto annuncia lo scontro chiuso', (tester) async {
      repo = FakeTournamentsRepository(
        tournaments: [buildTournament()],
        matches: [buildMatch(id: 'm1')],
      )..memberCount = 1;
      await pump(tester);

      await tester.tap(find.text('Trigun'));
      await tester.pumpAndSettle();

      expect(
        find.text('Ultimo voto: scontro chiuso e vincente nel turno dopo.'),
        findsOneWidget,
      );
    });

    testWidgets('un voto rifiutato non lascia il segno di votazione', (tester) async {
      repo = FakeTournamentsRepository(
        tournaments: [buildTournament()],
        matches: [buildMatch(id: 'm1')],
      )..voteFailure = const TournamentsFailure('Questo scontro e gia finito');
      await pump(tester);

      await tester.tap(find.text('Cowboy Bebop'));
      await tester.pumpAndSettle();

      expect(find.text('Questo scontro e gia finito'), findsOneWidget);
      expect(find.textContaining('Hai votato'), findsNothing);
    });

    testWidgets('un scontro gia finito non si vota', (tester) async {
      repo = FakeTournamentsRepository(
        tournaments: [buildTournament()],
        matches: [
          buildMatch(
            id: 'm1',
            status: TournamentMatchStatus.finished,
            winnerAnimeId: 'a1',
          ),
        ],
      );
      await pump(tester);

      await tester.tap(find.text('Cowboy Bebop'));
      await tester.pumpAndSettle();

      expect(repo.castVotes, isEmpty);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('il torneo concluso mostra il campione', (tester) async {
      repo = FakeTournamentsRepository(
        tournaments: [
          buildTournament(
            status: TournamentStatus.completed,
            championAnimeId: 'a1',
            championTitle: 'Cowboy Bebop',
          ),
        ],
        matches: [buildMatch(id: 'm1')],
      );
      await pump(tester);

      // Maiuscolo per via di `MetricLabel`: le etichette di sezione vanno in
      // maiuscolo e con spaziatura fra le lettere, e' quello che le distingue
      // dal testo solo piu' piccolo.
      expect(find.text('TORNEO CONCLUSO'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Elimina'), findsNothing);
    });

    testWidgets('la classifica finale si vede nella seconda scheda', (tester) async {
      repo = FakeTournamentsRepository(
        tournaments: [buildTournament()],
        matches: [buildMatch(id: 'm1')],
        standings: [
          buildStanding(animeId: 'a1', title: 'Cowboy Bebop', matchesWon: 2, votesReceived: 9),
          buildStanding(animeId: 'a2', title: 'Trigun', isOut: true, matchesWon: 0),
        ],
      );
      await pump(tester);

      await tester.tap(find.text('Classifica'));
      await tester.pumpAndSettle();

      expect(find.text('Cowboy Bebop'), findsOneWidget);
      expect(find.text('2 vinte · 9 voti ricevuti'), findsOneWidget);
      expect(find.text('Eliminato'), findsOneWidget);
    });

    testWidgets('su schermo largo i turni sono colonne', (tester) async {
      repo = FakeTournamentsRepository(
        tournaments: [buildTournament(bracketSize: 4)],
        matches: [
          buildMatch(id: 'm1', roundNumber: 1, matchNumber: 1),
          buildMatch(id: 'm2', roundNumber: 1, matchNumber: 2),
          buildMatch(id: 'm3', roundNumber: 2, matchNumber: 1),
        ],
      );
      await pump(tester, size: const Size(1200, 900));

      expect(find.text('Semifinali'), findsOneWidget);
      expect(find.text('Finale'), findsOneWidget);
    });

    testWidgets('un errore offre il retry', (tester) async {
      // Il torneo deve esistere: altrimenti il retry fallirebbe di nuovo con
      // "non trovato" e il test passerebbe per un motivo sbagliato.
      repo = FakeTournamentsRepository(
        tournaments: [buildTournament()],
        matches: [buildMatch(id: 'm1')],
      )..bracketFailure = const TournamentsFailure('Tabellone non disponibile. Riprova.');
      await pump(tester);

      expect(find.text('Tabellone non disponibile. Riprova.'), findsOneWidget);

      repo.bracketFailure = null;
      await tester.tap(find.widgetWithText(FilledButton, 'Riprova'));
      await tester.pumpAndSettle();

      expect(repo.bracketCalls, 2);
      expect(find.text('Tabellone non disponibile. Riprova.'), findsNothing);
      expect(find.text('Cowboy Bebop'), findsOneWidget);
    });

    testWidgets('senza permessi il menu di eliminazione non c\' e', (tester) async {
      await pump(tester);

      expect(find.byTooltip('Elimina torneo'), findsNothing);
    });
  });

  group('rotta', () {
    test('gruppo e torneo stanno nel percorso', () {
      expect(AppRoutes.tournaments('g1'), '/tournaments/g1');
      expect(AppRoutes.tournamentDetail('g1', 't1'), '/tournaments/g1/t1');
    });
  });

  group('TournamentsRepository', () {
    test('il finto rispetta il contratto', () {
      expect(FakeTournamentsRepository(), isA<TournamentsRepository>());
    });
  });
}