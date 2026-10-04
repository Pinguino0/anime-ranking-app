import 'package:animerank/core/theme/app_theme.dart';
import 'package:animerank/features/episodes/data/episodes_repository.dart';
import 'package:animerank/features/episodes/domain/episode.dart';
import 'package:animerank/features/episodes/presentation/episodes_controller.dart';
import 'package:animerank/features/episodes/presentation/screens/episode_screen.dart';
import 'package:animerank/features/episodes/presentation/widgets/episode_rating_bar.dart';
import 'package:animerank/features/episodes/presentation/widgets/episode_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_episodes.dart';

/// Schermata di visione con il repository finto.
///
/// Il player vero non parte in un test: `video_player` chiama un plugin che
/// nei test non e' registrato, quindi [EpisodePlayer] cade sulla sua scheda di
/// errore. Va bene perche' quello che qui si verifica e' tutto il resto della
/// pagina — titolo, elenco, voto — e il player ha gia' i suoi test.
Widget _host(FakeEpisodesRepository repository, {String? episodeId}) {
  return ProviderScope(
    overrides: [episodesRepositoryProvider.overrideWithValue(repository)],
    child: MaterialApp(
      theme: AppTheme.dark,
      home: MediaQuery(
        data: const MediaQueryData(size: Size(400, 900)),
        child: EpisodeScreen(animeId: 'anime-1', episodeId: episodeId),
      ),
    ),
  );
}

/// Schermata con il finto su uno schermo largo, dove l'elenco sta a lato.
Widget _hostWide(FakeEpisodesRepository repository) {
  return ProviderScope(
    overrides: [episodesRepositoryProvider.overrideWithValue(repository)],
    child: MaterialApp(
      theme: AppTheme.dark,
      home: MediaQuery(
        data: const MediaQueryData(size: Size(1400, 900)),
        child: EpisodeScreen(animeId: 'anime-1'),
      ),
    ),
  );
}

void main() {
  group('dominio episodi', () {
    test('legge i numeri che Postgres manda come stringhe', () {
      // `bigint` e `numeric` arrivano in JSON come stringhe per non perdere
      // precisione: senza la conversione, un conteggio mostrerebbe "3.0".
      final episode = Episode.parse({
        'id': 'ep-1',
        'episode_num': '12',
        'source_count': '2',
        'progress_time': '730',
        'community_avg': '8.25',
        'community_count': '17',
      });

      expect(episode.number, 12);
      expect(episode.sourceCount, 2);
      expect(episode.progressTime, 730);
      expect(episode.communityAverage, 8.25);
      expect(episode.communityCount, 17);
    });

    test('il titolo unisce numero e nome quando ci sono entrambi', () {
      expect(episodeFixture().titleLabel, 'Episodio 1');
      expect(
        episodeFixture(number: 7, title: 'Ricordi').titleLabel,
        'Episodio 7 · Ricordi',
      );
    });

    test('la barra di progresso non inventa una percentuale', () {
      const total = Duration(minutes: 24);

      expect(episodeFixture(progressTime: 720).progressFraction(total), 0.5);
      // Oltre la fine si ferma a uno: una barra piu' lunga del video non
      // esiste, e sforare significa che il progresso e' vecchio.
      expect(episodeFixture(progressTime: 5000).progressFraction(total), 1);
      // Senza durata non si disegna niente: il database conosce il tempo
      // guardato ma non quanto dura l'episodio.
      expect(episodeFixture(progressTime: 720).progressFraction(null), isNull);
    });

    test('un episodio finito e\' al completo anche senza durata nota', () {
      expect(episodeFixture(isCompleted: true).progressFraction(null), 1);
    });

    test('la pastiglia della fonte unisce qualita\' e lingua', () {
      expect(sourceFixture(quality: '1080p', language: 'ita').label, '1080p SUB');
      expect(sourceFixture(quality: '720p', language: 'dub').label, '720p DUB');
      // Manca una delle due: resta solo l'altra, senza separatore appeso.
      expect(sourceFixture(quality: '1080p', language: null).label, '1080p');
      expect(sourceFixture(quality: null, language: 'ita').label, 'SUB');
    });

    test('un iframe non e\' riproducibile dall\'app', () {
      expect(sourceFixture().isPlayable, isTrue);
      expect(
        sourceFixture(type: EpisodeSourceType.iframe).isPlayable,
        isFalse,
      );
    });
  });

  group('salvataggio del progresso', () {
    late FakeEpisodesRepository repository;
    late WatchProgressSaver saver;

    setUp(() {
      repository = FakeEpisodesRepository();
      saver = WatchProgressSaver(repository);
    });

    test('il primo salvataggio parte subito', () async {
      await saver.maybeSave('ep-1', const Duration(seconds: 4));

      expect(repository.progressWrites, 1);
      expect(repository.savedSeconds['ep-1'], 4);
    });

    test('dentro i dieci secondi non scrive niente', () async {
      await saver.maybeSave('ep-1', const Duration(seconds: 4));
      await saver.maybeSave('ep-1', const Duration(seconds: 9));

      expect(repository.progressWrites, 1);
    });

    test('passati dieci secondi di video scrive ancora', () async {
      await saver.maybeSave('ep-1', const Duration(seconds: 4));
      await saver.maybeSave('ep-1', const Duration(seconds: 15));

      expect(repository.progressWrites, 2);
      expect(repository.savedSeconds['ep-1'], 15);
    });

    test('tornare indietro conta come cambiamento', () async {
      // E' il caso del rewatch: senza questa riga un utente che riguarda
      // un episodio non aggiornerebbe mai niente.
      await saver.maybeSave('ep-1', const Duration(seconds: 40));
      await saver.maybeSave('ep-1', const Duration(seconds: 12));

      expect(repository.progressWrites, 2);
      expect(repository.savedSeconds['ep-1'], 12);
    });

    test('salvare in uscita scrive subito, ignorando l\'intervallo', () async {
      await saver.maybeSave('ep-1', const Duration(seconds: 40));
      await saver.flush('ep-1', const Duration(seconds: 43));

      expect(repository.progressWrites, 2);
      expect(repository.savedSeconds['ep-1'], 43);
    });

    test('finire l\'episodio scrive anche il flag', () async {
      await saver.markCompleted('ep-1', const Duration(minutes: 24));

      expect(repository.completed, contains('ep-1'));
      expect(repository.savedSeconds['ep-1'], 1440);
    });

    test('i salvataggi periodici non scrivono il flag', () async {
      // `completed` si scrive solo quando e' noto: mandare `false` a ogni
      // salvataggio periodico azzererebbe un episodio gia' finito.
      await saver.maybeSave('ep-1', const Duration(seconds: 30));

      expect(repository.completed, isEmpty);
    });
  });

  group('riga episodio', () {
    testWidgets('un episodio finito e\' segnato come visto', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: EpisodeTile(
              episode: episodeFixture(isCompleted: true),
              onTap: () {},
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(find.text('Visto'), findsOneWidget);
    });

    testWidgets('un episodio iniziato mostra il punto di ripresa',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: EpisodeTile(
              episode: episodeFixture(progressTime: 754),
              duration: const Duration(minutes: 24),
              onTap: () {},
            ),
          ),
        ),
      );

      expect(find.text('Riprendi da 12:34'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('senza fonti la riga non e\' cliccabile', (tester) async {
      var taps = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: EpisodeTile(
              episode: episodeFixture(sourceCount: 0),
              onTap: () => taps++,
            ),
          ),
        ),
      );

      expect(find.text('Non disponibile'), findsOneWidget);

      await tester.tap(find.byType(EpisodeTile));
      await tester.pump();

      expect(taps, 0);
    });

    testWidgets('il voto personale compare in riga', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: EpisodeTile(
              episode: episodeFixture(myScore: 7.5),
              onTap: () {},
            ),
          ),
        ),
      );

      expect(find.text('7.5'), findsOneWidget);
    });
  });

  group('voto su un episodio', () {
    testWidgets('la scala arriva a 10 con il passo di mezzo', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: SingleChildScrollView(
              child: EpisodeRatingBar(value: null, onSave: (_) async {}),
            ),
          ),
        ),
      );

      expect(EpisodeRatingBar.scoreAt(0), 1.0);
      expect(EpisodeRatingBar.scoreAt(18), 10.0);
      expect(find.text('10.0'), findsOneWidget);
      // Senza voto non c'e' modo di cancellarlo: non ce n'e' nessuno.
      expect(find.text('Togli il voto'), findsNothing);
    });

    testWidgets('con un voto compare il modo per toglierlo', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: SingleChildScrollView(
              child: EpisodeRatingBar(value: 8, onSave: (_) async {}),
            ),
          ),
        ),
      );

      expect(find.text('Togli il voto'), findsOneWidget);
    });
  });

  group('schermata episodio', () {
    testWidgets('senza episodi lo dice', (tester) async {
      await tester.pumpWidget(_host(FakeEpisodesRepository()));
      await tester.pumpAndSettle();

      expect(find.text('Nessun episodio'), findsOneWidget);
    });

    testWidgets('un errore di caricamento offre il retry', (tester) async {
      await tester.pumpWidget(
        _host(
          FakeEpisodesRepository(
            failWith: const EpisodesFailure('Episodi non raggiungibili.'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Episodi non raggiungibili.'), findsOneWidget);
      expect(find.text('Riprova'), findsOneWidget);
    });

    testWidgets('mostra il titolo e la media della community', (tester) async {
      await tester.pumpWidget(
        _host(
          FakeEpisodesRepository(
            episodes: [
              episodeFixture(
                title: 'Una mano per tutti',
                communityAverage: 8.4,
                communityCount: 23,
              ),
            ],
            sourcesByEpisode: {
              'ep-1': [sourceFixture()],
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Il titolo compare due volte: una come intestazione della pagina, una
      // nella barra in fondo che apre l'elenco. E' voluto — la barra e' il
      // punto su cui il pollice cade, e senza il titolo li' non si sa cosa si
      // sta navigando.
      expect(find.text('Episodio 1 · Una mano per tutti'), findsWidgets);
      expect(find.text('da 23 utenti'), findsOneWidget);
    });

    testWidgets('il numero e\' al singolare quando vota una persona',
        (tester) async {
      await tester.pumpWidget(
        _host(
          FakeEpisodesRepository(
            episodes: [
              episodeFixture(communityAverage: 7, communityCount: 1),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('da 1 utente'), findsOneWidget);
    });

    testWidgets('il voto viene scritto nel repository', (tester) async {
      final repository = FakeEpisodesRepository(
        episodes: [episodeFixture()],
        sourcesByEpisode: {
          'ep-1': [sourceFixture()],
        },
      );

      await tester.pumpWidget(_host(repository));
      await tester.pumpAndSettle();

      // Il voto sta sotto al player, quindi va portato in vista come fa
      // l'utente: premere un numero senza vederlo proverebbe solo che
      // esiste un punto esatto, non che il numero e' quello giusto.
      await tester.scrollUntilVisible(
        find.text('9.0'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('9.0'));
      await tester.pumpAndSettle();

      expect(repository.ratings['ep-1'], 9.0);
    });

    testWidgets('su schermo largo l\'elenco sta a lato', (tester) async {
      final repository = FakeEpisodesRepository(
        episodes: [
          episodeFixture(id: 'ep-1', number: 1),
          episodeFixture(id: 'ep-2', number: 2),
          episodeFixture(id: 'ep-3', number: 3),
        ],
      );

      await tester.pumpWidget(_hostWide(repository));
      await tester.pumpAndSettle();

      // L'elenco e' la colonna destra: e' costruito tutto, quindi tutti e tre
      // gli episodi sono in albero senza dover aprire il foglio.
      expect(find.text('Episodio 3'), findsOneWidget);
    });

    testWidgets('con piu\' fonti il selettore le mette in fila', (tester) async {
      await tester.pumpWidget(
        _host(
          FakeEpisodesRepository(
            episodes: [episodeFixture()],
            sourcesByEpisode: {
              'ep-1': [
                sourceFixture(id: 's1', quality: '1080p', language: 'ita'),
                sourceFixture(id: 's2', quality: '720p', language: 'eng'),
              ],
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('1080p SUB'), findsOneWidget);
      expect(find.text('720p ENG'), findsOneWidget);
    });
  });

  group('contratto del repository', () {
    test('il finto rispetta l\'interfaccia', () {
      // Serve a intercettare i cambi di firma: se l'interfaccia cresce senza
      // che il finto la implementi, il fallimento arriva qui e non in un test
      // di schermata, che direbbe solo "qualcosa non funziona".
      expect(FakeEpisodesRepository(), isA<EpisodesRepository>());
    });
  });
}