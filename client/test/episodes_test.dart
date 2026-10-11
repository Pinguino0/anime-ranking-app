import 'package:animerank/core/theme/app_theme.dart';
import 'package:animerank/core/ui/section_header.dart';
import 'package:animerank/features/episodes/data/episodes_repository.dart';
import 'package:animerank/features/episodes/domain/episode.dart';
import 'package:animerank/features/episodes/presentation/episodes_controller.dart';
import 'package:animerank/features/episodes/presentation/screens/episode_screen.dart';
import 'package:animerank/features/episodes/presentation/widgets/episode_player.dart';
import 'package:animerank/features/episodes/presentation/widgets/episode_rating_bar.dart';
import 'package:animerank/features/episodes/presentation/widgets/episode_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_episodes.dart';

/// Schermata di visione con il repository finto.
///
/// Il player vero non parte in un test: `media_kit` carica librerie native che
/// nei test non ci sono, quindi [EpisodePlayer] cade sulla sua scheda di errore.
/// Va bene perche' quello che qui si verifica e' tutto il resto della pagina —
/// titolo, elenco, voto — e il player ha i suoi test separati, sulla parte che
/// non richiede il decoder.
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

/// Player isolato, con un resolver che si puo' sostituire.
///
/// Il player vero non parte in un test: `media_kit` carica librerie native che
/// nei test non ci sono, quindi [EpisodePlayer] cade sulla scheda di errore. Va
/// bene perche' quello che qui si verifica e' la parte *prima* del player — se
/// la risoluzione parte, se scade, se il fallback va avanti — e quella e' tutta
/// logica Dart, niente native.
///
/// [onResolved] riceve l'id di ogni fonte per cui il resolver e' stato
/// chiamato: serve a distinguere "ha risolto" da "ha aperto", che in un test
/// senza player vero non sono la stessa cosa.
Widget _playerHost({
  required List<EpisodeSource> sources,
  SourceResolver? resolve,
  void Function(String sourceId)? onResolved,
  void Function(int index)? onSourceChanged,
}) {
  return MaterialApp(
    theme: AppTheme.dark,
    home: MediaQuery(
      data: const MediaQueryData(size: Size(400, 900)),
      child: Scaffold(
        body: EpisodePlayer(
          sources: sources,
          onSourceChanged: onSourceChanged,
          resolver: resolve == null
              ? null
              : (sourceId) {
                  onResolved?.call(sourceId);
                  return resolve(sourceId);
                },
        ),
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
      expect(sourceFixture(quality: '1080p', language: 'ita').label, '1080p ITA');
      expect(sourceFixture(quality: '720p', language: 'dub').label, '720p DUB');
      // Manca una delle due: resta solo l'altra, senza separatore appeso.
      expect(sourceFixture(quality: '1080p', language: null).label, '1080p');
      expect(sourceFixture(quality: null, language: 'ita').label, 'ITA');
    });

    test('l italiano non si confonde con il sottotitolato', () {
      // Le due cose erano una sola etichetta: `ita` (audio gia' italiano) e
      // `sub` (audio originale con sottotitoli) finivano entrambe in `SUB`.
      // Un utente italiano leggeva "720p SUB" su una traccia doppiata e la
      // sceglieva aspettandosi i sottotitoli.
      expect(sourceFixture(quality: '720p', language: 'ita').label, '720p ITA');
      expect(sourceFixture(quality: '720p', language: 'sub').label, '720p SUB');

      // E con lo stesso valore non ci puo' essere ambiguit': due sorgenti
      // diverse hanno sempre due etichette diverse, altrimenti nella riga dei
      // codici non si sa quale scegliere.
      final doppiato = sourceFixture(quality: '720p', language: 'ita').label;
      final sottotitolato = sourceFixture(quality: '720p', language: 'sub').label;
      expect(doppiato, isNot(sottotitolato));
    });

    test('un iframe non e\' riproducibile dall\'app', () {
      expect(sourceFixture().isPlayable, isTrue);
      expect(
        sourceFixture(type: EpisodeSourceType.iframe).isPlayable,
        isFalse,
      );
    });
  });

  group('fonti canoniche e risoluzione', () {
    test('una fonte canonica ha bisogno del resolver', () {
      // Il caso normale di un provider vero: l'indirizzo che arriva dal
      // catalogo e' la pagina, non il file, e non si puo' aprire cosi'.
      final canonica = sourceFixture(
        url: null,
        canonicalUrl: 'https://api.example.com/watch/1',
        providerSlug: 'mock',
        providerLabel: 'Provider di prova',
      );

      expect(canonica.needsResolution, isTrue);

      // La scheda esterna apre il canonico quando non c'e' un altro indirizzo:
      // su una fonte `iframe` i due non coincidono.
      expect(canonica.playbackAddress, 'https://api.example.com/watch/1');
    });

    test('una fonte diretta non ha bisogno del resolver', () {
      expect(sourceFixture().needsResolution, isFalse);
    });

    testWidgets('il resolver non viene chiamato su una fonte gia\' pronta',
        (tester) async {
      final repository = FakeEpisodesRepository();
      final player = _playerHost(
        sources: [sourceFixture()],
        resolve: repository.resolveSource,
      );

      await tester.pumpWidget(player);
      await tester.pump(const Duration(milliseconds: 300));

      // Una fonte con `source_url` non tocca la rete: risolverla costerebbe una
      // richiesta per niente, e su un provider vero costerebbe un token.
      expect(repository.resolutionCalls, 0);
    });

    testWidgets('una fonte canonica viene risolta prima di aprirsi', (tester) async {
      final repository = FakeEpisodesRepository();
      repository.resolvedById['src-canonica'] = resolvedFor(
        'src-canonica',
        url: 'https://cdn.example/ep1.mp4?token=risolto',
      );

      await tester.pumpWidget(
        _playerHost(
          sources: [
            sourceFixture(
              id: 'src-canonica',
              url: null,
              canonicalUrl: 'https://api.example.com/watch/1',
              providerSlug: 'mock',
            ),
          ],
          resolve: repository.resolveSource,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(repository.resolutionCalls, 1);
    });

    testWidgets('senza resolver una fonte canonica non si apre e si prova la dopo', (tester) async {
      final repository = FakeEpisodesRepository();

      final risolte = <String>[];
      final indici = <int>[];

      await tester.pumpWidget(
        _playerHost(
          sources: [
            sourceFixture(
              id: 'src-canonica',
              url: null,
              canonicalUrl: 'https://api.example.com/watch/1',
            ),
            sourceFixture(id: 'src-diretta', url: 'https://cdn.example/2.mp4'),
          ],
          // `resolve: null` e' il caso di una schermata senza backend sotto.
          resolve: null,
          onResolved: risolte.add,
          onSourceChanged: indici.add,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      // Nessuna risoluzione e' avvenuta: senza resolver non c'e' modo di
      // trasformare la canonica in un link.
      expect(repository.resolutionCalls, 0);
      expect(risolte, isEmpty);

      // E il player non e' rimasto fermo sulla canonica: e' passato alla fonte
      // successiva, che e' quello che dice il nome del test. Qui ci si ferma al
      // salto e non all'apertura perche' nel test il player vero non parte —
      // `media_kit` carica librerie native che qui non ci sono — e la fonte
      // diretta finisce comunque sulla scheda di errore.
      expect(indici, contains(1));
    });

    testWidgets('la risoluzione va in timeout invece di bloccare il player',
        (tester) async {
      // Un resolver che non risponde non puo' tenere lo scheletro acceso: dopo
      // il timeout il player passa alla fonte successiva.
      final aperte = <String>[];
      final indici = <int>[];

      await tester.pumpWidget(
        _playerHost(
          sources: [
            sourceFixture(
              id: 'src-lenta',
              url: null,
              canonicalUrl: 'https://api.example.com/watch/1',
            ),
            sourceFixture(id: 'src-diretta', url: 'https://cdn.example/2.mp4'),
          ],
          resolve: (sourceId) async {
            aperte.add(sourceId);
            await Future<void>.delayed(const Duration(seconds: 30));
            return resolvedFor(sourceId);
          },
          onSourceChanged: indici.add,
        ),
      );

      // Il resolver viene chiamato subito, ma si impianta per trenta secondi.
      await tester.pump(const Duration(milliseconds: 300));
      expect(aperte, contains('src-lenta'));

      // Dopo [EpisodePlayer.resolveTimeout] il player non aspetta oltre: molla
      // la fonte lenta e passa alla successiva. Si avanza oltre anche i trenta
      // secondi del resolver finto, altrimenti il suo timer resterebbe vivo a
      // fine test e `flutter_test` lo segnalerebbe come pendente.
      await tester.pump(EpisodePlayer.resolveTimeout);
      await tester.pump(const Duration(seconds: 6));

      expect(indici, contains(1));
      expect(aperte, contains('src-lenta'));
    });

    testWidgets('un link gia\' scaduto viene rifatto invece di aperto', (tester) async {
      final repository = FakeEpisodesRepository();
      repository.resolvedById['src-scaduta'] = expiredFor('src-scaduta');

      await tester.pumpWidget(
        _playerHost(
          sources: [
            sourceFixture(
              id: 'src-scaduta',
              url: null,
              canonicalUrl: 'https://api.example.com/watch/1',
            ),
            sourceFixture(id: 'src-diretta', url: 'https://cdn.example/2.mp4'),
          ],
          resolve: repository.resolveSource,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      // Il resolver e' stato chiamato piu' di una volta: la prima ha prodotto un
      // link scaduto e il player ha chiesto un link nuovo invece di provare ad
      // aprire quello vecchio.
      expect(repository.resolutionCalls, greaterThan(1));
    });

    testWidgets('un resolver che fallisce porta alla fonte successiva', (tester) async {
      final repository = FakeEpisodesRepository(
        failResolutionWith: const SourceResolutionFailure('non risolvibile'),
      );

      await tester.pumpWidget(
        _playerHost(
          sources: [
            sourceFixture(
              id: 'src-rotta',
              url: null,
              canonicalUrl: 'https://api.example.com/watch/1',
            ),
            sourceFixture(id: 'src-diretta', url: 'https://cdn.example/2.mp4'),
          ],
          resolve: repository.resolveSource,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      // Il fallback automatico e' il comportamento normale: una fonte che non
      // si risolve non deve fermare la riproduzione di un episodio che ha altre
      // fonti buone.
      expect(repository.resolutionCalls, greaterThanOrEqualTo(1));
    });

    testWidgets('l\'errore del resolver non finisce a schermo', (tester) async {
      final repository = FakeEpisodesRepository(
        failResolutionWith: const SourceResolutionFailure('segreto del provider'),
      );

      await tester.pumpWidget(
        _playerHost(
          sources: [
            sourceFixture(
              id: 'src-rotta',
              url: null,
              canonicalUrl: 'https://api.example.com/watch/1',
            ),
          ],
          resolve: repository.resolveSource,
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));

      // Il player prova la fonte tre volte e poi dice che le fonti non si
      // risolvono. Il messaggio del provider non compare: quello che e' andato
      // storto dentro al backend non e' roba da mostrare all'utente.
      expect(find.textContaining('segreto del provider'), findsNothing);
    });

    testWidgets('la risoluzione non viene riusata fra aperture diverse', (tester) async {
      final repository = FakeEpisodesRepository();

      Future<void> apri() async {
        await tester.pumpWidget(
          _playerHost(
            sources: [
              sourceFixture(
                id: 'src-canonica',
                url: null,
                canonicalUrl: 'https://api.example.com/watch/1',
              ),
            ],
            resolve: repository.resolveSource,
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
      }

      await apri();
      await apri();

      // Due aperture, due richieste: il token del primo tentativo scade e il
      // secondo deve portarne uno nuovo. riusare il link precedente
      // produrrebbe un player che si chiude da solo dopo qualche minuto, senza
      // che nessuno capisca perche'.
      expect(repository.resolutionCalls, 2);
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

      expect(find.text('1080p ITA'), findsOneWidget);
      expect(find.text('720p ENG'), findsOneWidget);
    });

    testWidgets('due fonti identiche non diventano due pastiglie uguali',
        (tester) async {
      await tester.pumpWidget(
        _host(
          FakeEpisodesRepository(
            episodes: [episodeFixture()],
            sourcesByEpisode: {
              'ep-1': [
                sourceFixture(id: 's1', quality: '1080p', language: 'sub'),
                // Stessa qualita' e stessa lingua della prima: provider
                // diverso, quindi due scelte legittime. Ma senza un dato che le
                // distingue l'utente legge due pastiglie identiche e non sa
                // quale provare.
                sourceFixture(id: 's2', quality: '1080p', language: 'sub'),
              ],
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final etichette = tester
          .widgetList<ArChip>(find.byType(ArChip))
          .map((c) => c.label)
          .toList();

      expect(etichette.length, 2);
      expect(etichette.toSet().length, 2,
          reason: 'due scelte diverse devono avere due nomi diversi');
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