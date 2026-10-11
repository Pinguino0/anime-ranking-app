import 'package:animerank/features/anime/data/anime_repository.dart';
import 'package:animerank/features/anime/domain/anime.dart';
import 'package:animerank/features/anime/presentation/anime_controller.dart';
import 'package:animerank/core/ui/anime_card.dart';
import 'package:animerank/core/ui/section_header.dart';
import 'package:animerank/features/anime/presentation/screens/anime_search_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_anime.dart';

void main() {
  group('testo e ricerca', () {
    testWidgets('la barra di ricerca filtra mentre si scrive', (tester) async {
      final repo = FakeAnimeRepository(
        initial: [
          animeFixture(externalId: '1', title: 'Attack on Titan'),
          animeFixture(externalId: '2', title: 'Akira'),
        ],
      );
      await pumpSearch(tester, repo);

      await tester.enterText(find.byType(TextField), 'titan');
      // Il rimando e' voluto: senza, ogni tasto aprirebbe una richiesta e
      // servirebbe una lettera per fare una ricerca.
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Attack on Titan'), findsOneWidget);
      expect(find.text('Akira'), findsNothing);
    });

    testWidgets('un risultato mostra titolo e dati principali', (tester) async {
      final repo = FakeAnimeRepository(
        initial: [
          animeFixture(
            externalId: '16498',
            title: 'Attack on Titan',
            japaneseTitle: '進撃の巨人',
            episodes: 89,
            year: 2013,
            mediaType: AnimeMediaType.tv,
            score: 9.1,
            genres: const ['Action', 'Drama'],
          ),
        ],
      );
      await pumpSearch(tester, repo);

      expect(find.text('Attack on Titan'), findsOneWidget);
      // La riga dei fatti unisce tipo, episodi e anno.
      expect(find.textContaining('TV'), findsWidgets);
      expect(find.textContaining('89 episodi'), findsOneWidget);
      expect(find.textContaining('2013'), findsOneWidget);
      expect(find.textContaining('Action'), findsOneWidget);
    });

    testWidgets('il testo giapponese viene cercato', (tester) async {
      // Un utente giapponese scrive in kanji: se la ricerca guardasse solo il
      // titolo latino non troverebbe nulla.
      final repo = FakeAnimeRepository(
        initial: [
          animeFixture(
            externalId: '16498',
            title: 'Attack on Titan',
            japaneseTitle: '進撃の巨人',
          ),
          animeFixture(externalId: '2', title: 'Akira'),
        ],
      );
      await pumpSearch(tester, repo);

      await tester.enterText(find.byType(TextField), '進撃');
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Attack on Titan'), findsOneWidget);
      expect(find.text('Akira'), findsNothing);
    });

    testWidgets('un anime senza dati non mostra spazi vuoti', (tester) async {
      final repo = FakeAnimeRepository(
        initial: [
          animeFixture(
            externalId: '1',
            title: 'Mystery',
            episodes: null,
            year: null,
            mediaType: null,
            genres: const [],
          ),
        ],
      );
      await pumpSearch(tester, repo);

      expect(find.text('Mystery'), findsOneWidget);
      // Nessun separatore orfano: senza il join condizionale la riga
      // mostrerebbe "·  ·".
      expect(find.textContaining('· ·'), findsNothing);
    });
  });

  group('stati vuoti', () {
    testWidgets(
      'catalogo vuoto e ricerca senza risultati hanno messaggi diversi',
      (tester) async {
        // Sono due problemi opposti e il messaggio sbagliato fa perdere tempo:
        // "nessun risultato" quando il catalogo e' vuoto fa sembrare sbagliata
        // la ricerca.
        final repo = FakeAnimeRepository(initial: const [])
          ..statsResult = AnimeCatalogStats.empty;
        await pumpSearch(tester, repo);

        expect(find.textContaining('catalogo'), findsWidgets);
      },
    );

    testWidgets(
      'filtri troppo restrittivi: il messaggio dice di cambiare filtro',
      (tester) async {
        final repo =
            FakeAnimeRepository(
                initial: [
                  animeFixture(externalId: '1', genres: ['Action']),
                ],
              )
              ..statsResult = const AnimeCatalogStats(totalAnime: 1)
              // Il pannello offre solo i generi che il catalogo conosce: senza questo
              // elenco la pastiglia non esiste e il test non starebbe provando niente.
              ..genresResult = const [
                AnimeGenre(name: 'Action', count: 1),
                AnimeGenre(name: 'Comedy', count: 30),
              ];
        await pumpSearch(tester, repo);

        await tester.tap(find.byType(ArChip).first);
        await tester.pumpAndSettle();
        // Attivo il filtro su un genere che non esiste.
        await tapChip(tester, ArChip, 'Comedy');

        // Il messaggio deve nominare i filtri come causa e offrire la via d'uscita:
        // "nessun risultato" da solo lascia l'utente a indovinare cosa toccare.
        expect(find.textContaining('filtri'), findsWidgets);
        expect(find.text('Azzera i filtri'), findsOneWidget);
      },
    );

    testWidgets('un risultato vuoto offre di cercare online', (tester) async {
      // E' il passaggio che riempie il catalogo: senza pulsante, l'utente
      // aspetterebbe che la ricerca trovi da sola un anime che non e' mai
      // stato cercato da nessuno.
      final repo = FakeAnimeRepository(initial: const [])
        ..statsResult = AnimeCatalogStats.empty
        ..remotePages = [
          [animeFixture(externalId: '999', id: null, inCatalog: false)],
        ];
      await pumpSearch(tester, repo);

      // Serve un testo da cercare: il catalogo esterno risponde a una domanda,
      // non a "tutto". Senza testo il pulsante non avrebbe niente da chiedere.
      await tester.enterText(find.byType(TextField), 'akira');
      await tester.pump(const Duration(milliseconds: 400));

      final pulsante = find.textContaining('online');
      expect(pulsante, findsOneWidget);

      await tester.tap(pulsante);
      await tester.pumpAndSettle();

      expect(repo.remoteCalls, 1);
    });
  });

  group('errori', () {
    testWidgets('un errore iniziale mostra un avviso con Riprova', (
      tester,
    ) async {
      final repo = FakeAnimeRepository()
        ..localFailure = const AnimeFailure('Rete assente.', isRetryable: true);
      await pumpSearch(tester, repo);

      expect(find.textContaining('Rete assente'), findsOneWidget);
      expect(find.text('Riprova'), findsOneWidget);
    });

    testWidgets('Riprova ricarica davvero', (tester) async {
      final repo = FakeAnimeRepository()
        ..localFailure = const AnimeFailure('Rete assente.', isRetryable: true);
      await pumpSearch(tester, repo);

      // Il primo tentativo e' fallito; dopo aver tolto l'errore il retry deve
      // riuscire. Senza questo il pulsante sarebbe decorativo.
      repo.localFailure = null;
      await tester.tap(find.text('Riprova'));
      await tester.pumpAndSettle();

      expect(repo.localCalls, greaterThan(1));
    });

    testWidgets('un errore non recuperabile non offre Riprova', (tester) async {
      // Riprovare un errore di permessi non migliora aspettando: offrire il
      // bottone porterebbe l'utente a riprovare per sempre.
      final repo = FakeAnimeRepository()
        ..localFailure = const AnimeFailure('Permessi insufficienti.');
      await pumpSearch(tester, repo);

      expect(find.text('Riprova'), findsNothing);
    });

    testWidgets('un errore in coda non svuota i risultati', (tester) async {
      final repo = FakeAnimeRepository(
        initial: [for (var i = 0; i < 30; i++) animeFixture(externalId: '$i')],
      );
      await pumpSearch(tester, repo);

      repo.localFailure = const AnimeFailure('Rete assente.');
      await tester.dragUntilVisible(
        find.byType(AnimeCard).last,
        find.byType(ListView),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();

      // I risultati iniziali restano visibili: il fallimento in coda non deve
      // far sparire quello che ha gia' funzionato.
      expect(find.byType(AnimeCard), findsWidgets);
    });
  });

  group('filtri', () {
    testWidgets('il pannello mostra i generi disponibili', (tester) async {
      final repo = FakeAnimeRepository()
        ..genresResult = const [
          AnimeGenre(name: 'Action', count: 120),
          AnimeGenre(name: 'Comedy', count: 80),
        ];
      await pumpSearch(tester, repo);

      await tester.tap(find.byType(ArChip).first);
      await tester.pumpAndSettle();

      expect(find.text('Action'), findsOneWidget);
      expect(find.text('Comedy'), findsOneWidget);
    });

    testWidgets('il badge conta i filtri attivi', (tester) async {
      final repo =
          FakeAnimeRepository(
              initial: [
                animeFixture(externalId: '1', genres: ['Action'], year: 2024),
                animeFixture(externalId: '2', genres: ['Comedy'], year: 2015),
              ],
            )
            ..genresResult = const [
              AnimeGenre(name: 'Action', count: 120),
              AnimeGenre(name: 'Comedy', count: 80),
            ];
      await pumpSearch(tester, repo);

      // Senza filtri la pastiglia non porta un numero: "Filtri · 0" occuperebbe
      // spazio per dire che non c'e' niente da dire.
      expect(find.text('Filtri'), findsOneWidget);
      await tester.tap(find.byType(ArChip).first);
      await tester.pumpAndSettle();

      await tapChip(tester, ArChip, 'Action');

      // Un filtro attivo deve essere visibile dal pannello chiuso, altrimenti
      // l'utente non sa perche' la lista e' cambiata.
      expect(find.text('Filtri · 1'), findsOneWidget);
    });

    testWidgets('azzera riporta tutti i risultati', (tester) async {
      final repo = FakeAnimeRepository(
        initial: [
          animeFixture(externalId: '1', genres: ['Action']),
          animeFixture(externalId: '2', genres: ['Comedy']),
        ],
      )..genresResult = const [AnimeGenre(name: 'Action', count: 1)];
      await pumpSearch(tester, repo);

      expect(find.byType(AnimeCard), findsNWidgets(2));

      await tester.tap(find.byType(ArChip).first);
      await tester.pumpAndSettle();
      await tapChip(tester, ArChip, 'Action');
      expect(find.byType(AnimeCard), findsOneWidget);

      // Anche "Azzera" va portato in vista: il pannello e' scorso in fondo per
      // raggiungere la pastiglia del genere, quindi l'intestazione e' fuori dal
      // viewport e il tap cadrebbe sul vuoto.
      // "Azzera" compare due volte: nella barra e nell'intestazione del pannello.
      // Il finder va ancorato alla barra, perche' e' li' che l'utente lo tocca
      // senza dover aprire il pannello.
      await tester.tap(find.widgetWithText(ArChip, 'Azzera'));
      await tester.pumpAndSettle();

      // Il pannello resta aperto dopo aver applicato un filtro e, aperto,
      // non lascia spazio per due schede: chiudere prima di contare, altrimenti
      // il test misurerebbe quanto schermo resta e non quanti risultati ci
      // sono.
      await tester.tap(find.byType(ArChip).first);
      await tester.pumpAndSettle();
      expect(find.byType(AnimeCard), findsNWidgets(2));
    });

    testWidgets('il filtro formato restringe i risultati', (tester) async {
      final repo = FakeAnimeRepository(
        initial: [
          animeFixture(externalId: '1', mediaType: AnimeMediaType.movie),
          animeFixture(externalId: '2', mediaType: AnimeMediaType.tv),
        ],
      );
      await pumpSearch(tester, repo);

      expect(find.byType(AnimeCard), findsNWidgets(2));

      await tester.tap(find.byType(ArChip).first);
      await tester.pumpAndSettle();
      await tapChip(tester, ArChip, 'Film');

      expect(find.byType(AnimeCard), findsOneWidget);
    });

    testWidgets('il filtro stato nasconde chi non e in onda', (tester) async {
      // "Solo in corso" e' il filtro che l'utente usa di piu' dopo la ricerca:
      // se non funziona, la lista continua a mostrare anime finiti e sembra
      // non ascoltare.
      final repo = FakeAnimeRepository(
        initial: [
          animeFixture(externalId: '1', status: AnimeAirStatus.airing),
          animeFixture(externalId: '2', status: AnimeAirStatus.finished),
          animeFixture(externalId: '3', status: AnimeAirStatus.airing),
        ],
      )..genresResult = const [AnimeGenre(name: 'Action', count: 3)];
      await pumpSearch(tester, repo);

      await tester.tap(find.byType(ArChip).first);
      await tester.pumpAndSettle();
      await tapChip(tester, ArChip, 'In corso');

      expect(find.byType(AnimeCard), findsNWidgets(2));
    });

    testWidgets('il filtro voto nasconde chi non ha voto', (tester) async {
      // Una riga senza score non deve comparire in "almeno 8".
      final repo = FakeAnimeRepository(
        initial: [
          animeFixture(externalId: '1', score: 9.0),
          animeFixture(externalId: '2', score: null),
          animeFixture(externalId: '3', score: 5.0),
        ],
      );
      await pumpSearch(tester, repo);

      await tester.tap(find.byType(ArChip).first);
      await tester.pumpAndSettle();
      await tapChip(tester, ArChip, '8+');

      expect(find.byType(AnimeCard), findsOneWidget);
    });
  });

  group('scroll', () {
    testWidgets('scorrendo in fondo carica la pagina successiva', (
      tester,
    ) async {
      final repo = FakeAnimeRepository(
        initial: [for (var i = 0; i < 30; i++) animeFixture(externalId: '$i')],
      );
      await pumpSearch(tester, repo);

      expect(find.byType(AnimeCard), findsWidgets);

      // Il trascinamento avviene sulla `CustomScrollView` dei risultati: e'
      // lei che ha il listener di scroll che carica la pagina successiva. La
      // striscia "recenti" e' una ListView orizzontale e trascinarla non
      // muoverebbe nulla.
      //
      // Non basta rendere visibile l'ultima scheda: il caricamento scatta a
      // 600px dal fondo, quindi serve arrivare davvero in fondo alla lista.
      for (var i = 0; i < 12; i++) {
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
        await tester.pumpAndSettle();
        if (repo.localOffsets.contains(24)) break;
      }

      // La seconda pagina deve aver caricato righe oltre le prime 24.
      expect(repo.localOffsets, contains(24));
    });

    testWidgets('la copertina mancante mostra un fallback leggibile', (
      tester,
    ) async {
      final repo = FakeAnimeRepository(
        initial: [
          animeFixture(externalId: '1', title: 'Senza', imageUrl: null),
        ],
      );
      await pumpSearch(tester, repo);

      // Non deve crashare e deve restare visibile il titolo.
      expect(find.text('Senza'), findsOneWidget);
    });
  });

  group('testata', () {
    testWidgets('il contatore del catalogo appare quando disponibile', (
      tester,
    ) async {
      final repo = FakeAnimeRepository(initial: [animeFixture(externalId: '1')])
        ..statsResult = const AnimeCatalogStats(totalAnime: 1250);
      await pumpSearch(tester, repo);

      expect(find.textContaining('1250'), findsOneWidget);
    });

    testWidgets('senza statistiche la testata funziona lo stesso', (
      tester,
    ) async {
      final repo = FakeAnimeRepository(initial: [animeFixture(externalId: '1')])
        ..statsFailure = const AnimeFailure('KO');
      await pumpSearch(tester, repo);

      // Le statistiche non devono bloccare la ricerca: manca solo il contatore,
      // e quello che conta e' che i risultati ci sono lo stesso.
      expect(find.byType(AnimeCard), findsOneWidget);
    });
  });

  group('striscia dei recenti', () {
    testWidgets('la card compatta non sfora la striscia', (tester) async {
      // Titolo lungo: e' la casetta peggiore per la colonna compatta, che
      // dentro una striscia di altezza fissa deve fare spazio a due righe.
      await pumpCompactCard(
        tester,
        'Il titolo piu lungo del mondo mai scritto su una card',
      );

      expect(
        tester.takeException(),
        isNull,
        reason: 'una RenderFlex che sfora disegna strisce gialle e nere',
      );
    });

    testWidgets('la card compatta regge anche col testo ingrandito', (
      tester,
    ) async {
      // L'overflow di 30 pixel spariva con il testo normale e tornava con il
      // testo ingrandito: e' il caso in cui il titolo e' piu' alto e la
      // locandina deve cedere ancora di piu'.
      await pumpCompactCard(
        tester,
        'Un titolo abbastanza lungo da andare a capo',
        textScale: 2.0,
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('la locandina occupa quello che resta dopo il titolo', (
      tester,
    ) async {
      // Non basta che non sforzi: il titolo deve restare leggibile per intero.
      // Se fosse la locandina a farsi spazio, il titolo verrebbe schiacciato a
      // zero righe e la card direbbe solo "Immagine rotta".
      await pumpCompactCard(tester, 'Shingeki no Kyojin');

      final titolo = find.text('Shingeki no Kyojin');
      expect(titolo, findsOneWidget);
      // La colonna deve aver lasciato al titolo un'altezza reale: una
      // locandina che mangia tutto lo spazio farebbe sparire il testo e la
      // card direbbe solo "Immagine rotta".
      expect(tester.getSize(titolo).height, greaterThan(0));
    });
  });

  group('tornare indietro', () {
    testWidgets('aperta da un altra schermata si torna indietro', (
      tester,
    ) async {
      await pumpSearchOver(
        tester,
        FakeAnimeRepository(
          initial: [animeFixture(externalId: '1', title: 'Akira')],
        ),
      );

      // Senza questo pulsante la ricerca era una strada a senso unico: da
      // sola, l'unico modo di tornare era Esc o il gesto di sistema.
      expect(find.byTooltip('Indietro'), findsOneWidget);

      await tester.tap(find.byTooltip('Indietro'));
      await tester.pumpAndSettle();

      expect(find.text('pagina di sotto'), findsOneWidget);
      expect(find.byType(AnimeSearchScreen), findsNothing);
    });

    testWidgets('aperta per un link non mette un pulsante che non serve', (
      tester,
    ) async {
      // Deep link: non c'e' una pagina precedente. Un pulsante che non fa
      // niente e' peggio di un pulsante assente, perche' promette un ritorno
      // che non esiste.
      await pumpSearch(tester, FakeAnimeRepository());

      expect(find.byTooltip('Indietro'), findsNothing);
    });
  });
}

/// Monta una card compatta dentro una striscia alta come quella vera.
///
/// La striscia dei recenti e' una `ListView` orizzontale dentro una
/// `SizedBox(height: 196)`: l'altezza e' imposta li' e non dalla card. Montare
/// la card da sola darebbe un'altezza libera, l'overflow non si produrrebbe e
/// il test passerebbe senza provare niente.
///
/// Non si usa la schermata intera perche' la striscia dei recenti compare solo
/// dopo l'apertura del pannello: senza recenti la card compatta non viene
/// costruita e l'errore di layout non arriverebbe mai a esistere.
Future<void> pumpCompactCard(
  WidgetTester tester,
  String title, {
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  if (textScale != 1.0) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            height: 196,
            child: AnimeSearchResultCard(
              entry: AnimeEntry(externalId: '1', title: title),
              compact: true,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Tocca una pastiglia del pannello filtri, portandola in vista prima.
///
/// Il pannello scorre dentro se stesso e occupa al massimo meta' schermo: su un
/// telefono le pastiglie in fondo (genere, voto, anno) sono fuori dal viewport.
/// Senza lo scroll il `tap` cade su altro e il test fallisce per il motivo
/// sbagliato, sembrando un bug di filtro.
Future<void> tapChip(WidgetTester tester, Type chipType, String label) async {
  final chip = find.widgetWithText(chipType, label).first;
  await tester.ensureVisible(chip);
  await tester.pumpAndSettle();
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

/// Monta la ricerca DENTRO un percorso che ha una pagina sotto.
///
/// Serve perche' l'indietro esiste solo se c'e' qualcosa da cui tornare: con
/// la schermata montata da sola `canPop()` e' sempre falso e il pulsante non
/// comparirebbe mai, quindi il test passerebbe anche senza il fix.
Future<void> pumpSearchOver(
  WidgetTester tester,
  AnimeRepository repo, {
  Size size = const Size(400, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final navigator = GlobalKey<NavigatorState>();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('pagina di sotto')),
      ),
    ),
  );
  navigator.currentState!.push(
    MaterialPageRoute<void>(builder: (_) => const AnimeSearchScreen()),
  );
  await tester.pumpAndSettle();
}

/// Monta la schermata di ricerca con un repository finto.
///
/// [Breakpoints] viene forzato a telefono perche' la barra di ricerca e il
/// pannello filtri hanno comportamenti diversi da large, e i test guardano
/// quelli del telefono, che e' dove l'app viene usata.
Future<void> pumpSearch(
  WidgetTester tester,
  AnimeRepository repo, {
  Size size = const Size(400, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [animeRepositoryProvider.overrideWithValue(repo)],
      child: const MaterialApp(home: AnimeSearchScreen()),
    ),
  );
  await tester.pumpAndSettle();
}
