import 'package:animerank/core/theme/app_theme.dart';
import 'package:animerank/features/anime/domain/anime.dart';
import 'package:animerank/features/anime/presentation/anime_controller.dart';
import 'package:animerank/features/anime/presentation/screens/anime_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_anime.dart';

/// Schermata della scheda anime.
///
/// I test qui non verificano l'aspetto — quello non si puo' controllare con un
/// matcher di testo. Verificano che la pagina mostri i dati che ha e che non
/// mostri azioni che non puo' eseguire: una scheda con un pulsante "vota" che
/// poi fallisce e' peggio di una scheda che dice perche' non puo' votare.
///
/// La larghezza passa da [MediaQuery] e non da un `SizedBox`: la scheda sceglie
/// il layout leggendo il `MediaQuery`, quindi un contenitore stretto dentro uno
/// schermo largo la farebbe disporre come se fosse desktop e il poster
/// occuperebbe 220px invece di 132, sbordando.
Widget _host(
  AnimeEntry entry, {
  Size size = const Size(400, 800),
  FakeAnimeRepository? repository,
}) {
  return ProviderScope(
    overrides: [
      // La scheda legge le opere correlate (sequel/prequel) da qui: senza il
      // repository il provider esplode e la pagina non si disegna.
      animeRepositoryProvider.overrideWithValue(
        repository ?? FakeAnimeRepository(),
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.dark,
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: Scaffold(
          body: AnimeDetailScreen(entry: entry),
        ),
      ),
    ),
  );
}

/// Porta in vista un elemento che sta sotto la piega.
///
/// La scheda e' una `CustomScrollView`, quindi gli sliver sotto il bordo
/// inferiore non sono costruiti finche' non arrivano li'. Un test che li cerca
/// senza prima scorrere fallirebbe anche se il testo ci fosse: e' il test che
/// deve fare quello che fa l'utente.
Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  group('scheda anime', () {
    testWidgets('mostra titolo, titolo giapponese e metadati', (tester) async {
      await tester.pumpWidget(_host(
        animeFixture(
          title: 'Cowboy Bebop',
          japaneseTitle: 'カウボーイビバップ',
          studio: 'Sunrise',
          episodes: 26,
          year: 1998,
        ),
      ));
      await tester.pump();

      expect(find.text('Cowboy Bebop'), findsOneWidget);
      expect(find.text('カウボーイビバップ'), findsOneWidget);
      expect(find.text('TV · 26 ep · 1998 · 24 min'), findsOneWidget);
    });

    testWidgets('mostra il voto con il separatore delle migliaia', (tester) async {
      await tester.pumpWidget(_host(
        animeFixture(score: 8.56, scoredBy: 812345),
      ));
      await tester.pump();

      expect(find.text('8.56'), findsOneWidget);
      // 812345 con i punti: senza, il numero si legge come un codice.
      expect(find.text('su 812.345 voti'), findsOneWidget);
    });

    testWidgets('un anime in catalogo offre la votazione', (tester) async {
      await tester.pumpWidget(_host(animeFixture(inCatalog: true)));
      await tester.pump();

      expect(find.text('Vota in un gruppo'), findsOneWidget);
      expect(
        find.textContaining('non è ancora in catalogo'),
        findsNothing,
      );
    });

    testWidgets('unanime fuori catalogo spiega perché non si vota', (tester) async {
      // `inCatalog: false` con `id` presente è il caso che la UI non deve
      // confondere: l'id c'è ma la riga non è ancora scrivibile.
      await tester.pumpWidget(_host(
        animeFixture(inCatalog: false, id: null),
      ));
      await tester.pump();

      expect(find.text('Vota in un gruppo'), findsNothing);
      expect(
        find.textContaining('non è ancora in catalogo'),
        findsOneWidget,
      );
    });

    testWidgets('mostra i generi come pastiglie', (tester) async {
      await tester.pumpWidget(_host(
        animeFixture(genres: ['Action', 'Sci-Fi', 'Space']),
      ));
      await tester.pump();

      await _scrollTo(tester, find.text('GENERI'));

      expect(find.text('Action'), findsOneWidget);
      expect(find.text('Sci-Fi'), findsOneWidget);
      expect(find.text('Space'), findsOneWidget);
      expect(find.text('GENERI'), findsOneWidget);
    });

    testWidgets('la trama perde la nota di MAL Rewrite', (tester) async {
      // La traccia ufficiale di MyAnimeList finisce quasi sempre con quel
      // tag: mostrato com'e', l'ultima riga della pagina e' una nota del sito
      // e non dell'opera.
      await tester.pumpWidget(_host(
        animeFixture(
          synopsis: 'Un gruppo di cacciatori di taglie. [Written by MAL Rewrite]',
        ),
      ));
      await tester.pump();

      await _scrollTo(tester, find.text('TRAMA'));

      expect(find.textContaining('cacciatori di taglie'), findsOneWidget);
      expect(find.textContaining('MAL Rewrite'), findsNothing);
    });

    testWidgets('una parentesi nella trama non viene tagliata', (tester) async {
      // La pulizia non deve fare "prendi tutto fino all'ultima parentesi": una
      // trama che cita "[seconda stagione]" parla dell'opera, e toglierla
      // amputerebbe la pagina di un pezzo che le appartiene.
      await tester.pumpWidget(_host(
        animeFixture(
          synopsis: 'Il seguito di Cowboy Bebop [seconda stagione].',
        ),
      ));
      await tester.pump();

      await _scrollTo(tester, find.text('TRAMA'));

      expect(find.textContaining('seconda stagione'), findsOneWidget);
    });

    testWidgets('senza dati mostra solo quello che c\'è', (tester) async {
      await tester.pumpWidget(_host(
        AnimeEntry(externalId: '9', title: 'Senza dati'),
      ));
      await tester.pump();

      expect(find.text('Senza dati'), findsOneWidget);
      // Le sezioni vuote non lasciano un'etichetta senza contenuto.
      expect(find.text('GENERI'), findsNothing);
      expect(find.text('DETTAGLI'), findsNothing);
      expect(find.text('TRAMA'), findsNothing);
    });

    testWidgets('il bottone indietro chiude la pagina', (tester) async {
      var chiusa = false;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            animeRepositoryProvider.overrideWithValue(FakeAnimeRepository()),
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => AnimeDetailScreen(
                          entry: animeFixture(),
                          heroTag: 'x',
                        ),
                      ),
                    ),
                    child: const Text('apri'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('apri'));
      await tester.pumpAndSettle();
      expect(find.text('Anime di prova'), findsOneWidget);

      await tester.tap(find.byTooltip('Indietro'));
      await tester.pumpAndSettle();

      chiusa = find.text('apri').evaluate().isNotEmpty;
      expect(chiusa, isTrue, reason: 'la pagina precedente deve riapparire');
    });

    testWidgets('con una saga mostra "Da dove iniziare" con la prima opera', (
      tester,
    ) async {
      final repository = FakeAnimeRepository()
        ..watchOrderResult = [
          WatchOrderItem(
            position: 1,
            isStart: true,
            entry: animeFixture(externalId: '10', title: 'Prima stagione'),
          ),
          WatchOrderItem(
            position: 2,
            isStart: false,
            entry: animeFixture(externalId: '11', title: 'Seconda stagione'),
          ),
          WatchOrderItem(
            position: 3,
            isStart: false,
            entry: animeFixture(externalId: '12', title: 'Terza stagione'),
          ),
        ];

      await tester.pumpWidget(
        _host(
          animeFixture(synopsis: 'Una saga lunga.', title: 'La saga'),
          repository: repository,
        ),
      );
      await tester.pump();
      await tester.pump();

      await _scrollTo(tester, find.text('DA DOVE INIZIARE'));

      expect(repository.watchOrderCalls, 1);
      expect(find.text('DA DOVE INIZIARE'), findsOneWidget);
      expect(find.text('Ordine di visione consigliato'), findsOneWidget);
      // Il badge sta solo sulla prima: e' quella da cui cominciare.
      expect(find.text('Inizia da qui'), findsOneWidget);
      expect(find.text('Prima stagione'), findsOneWidget);
      expect(find.text('Seconda stagione'), findsOneWidget);
      expect(find.text('Terza stagione'), findsOneWidget);
    });

    testWidgets('senza una catena la sezione non compare', (tester) async {
      // Una voce sola non e' un ordine: mostrarla ripeterebbe il titolo che e'
      // gia' in cima alla scheda.
      final repository = FakeAnimeRepository()
        ..watchOrderResult = [
          WatchOrderItem(
            position: 1,
            isStart: true,
            entry: animeFixture(externalId: '10', title: 'Unica opera'),
          ),
        ];

      await tester.pumpWidget(
        _host(
          animeFixture(synopsis: 'Nessuna saga.', title: 'Opera singola'),
          repository: repository,
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('DA DOVE INIZIARE'), findsNothing);
      expect(find.text('Inizia da qui'), findsNothing);
    });
  });

  group('tag dell hero', () {
    test('deriva dall id esterno, cosi due opere omonime non si confondono', () {
      // Due anime con lo stesso titolo ma id diversi: i tag devono essere
      // diversi, altrimenti l'immagine volerebbe dalla card sbagliata.
      final a = animeFixture(externalId: '1', title: 'Steins;Gate');
      final b = animeFixture(externalId: '2', title: 'Steins;Gate');

      expect(a.heroTag, isNot(b.heroTag));
    });

    test('e\' stabile fra due copie della stessa opera', () {
      // La stessa opera ricomparsa in due pagine deve avere lo stesso tag: se
      // cambiasse, l'hero non troverebbe la sua destinazione.
      final a = animeFixture(externalId: '7', title: 'Vinland Saga');
      final b = animeFixture(externalId: '7', title: 'Vinland Saga');

      expect(a.heroTag, b.heroTag);
    });

    test('senza id esterno usa il titolo', () {
      final entry = AnimeEntry(externalId: '', title: 'Senza id');
      expect(entry.heroTag, contains('Senza id'));
    });
  });
}
