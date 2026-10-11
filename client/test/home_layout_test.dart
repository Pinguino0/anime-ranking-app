import 'package:animerank/core/ui/content_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// La geometria delle locandine.
///
/// Sono test piccoli su una cosa sola, ma la cosa e' quella che si vede: il
/// titolo sta SOPRA la locandina e non sotto, quindi la card e' alta esattamente
/// 2:3. Quando il titolo era sotto, il carosello aggiungeva 52px per il blocco
/// testo; spostato il titolo sull'immagine quei 52px sono rimasti e ogni
/// locandina si e' portata dietro mezzo palmo di spazio morto.
///
/// Le misure sono prese sulla lista, non sulla card: la card ha un'animazione
/// d'ingresso che la ingrandisce dell'1.5% e non si riporta a 1 durante il
/// test, quindi `getSize` su di lei direbbe una larghezza gonfiata.
void main() {
  group('carosello', () {
    Future<void> pumpRow(
      WidgetTester tester, {
      required double itemWidth,
      int count = 6,
      Size size = const Size(900, 900),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContentRow(
              title: 'In corso',
              itemCount: count,
              itemWidth: itemWidth,
              itemBuilder: (_, _) => const Placeholder(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Size listHeight(WidgetTester tester) => tester.getSize(
          find.descendant(
            of: find.byType(ContentRow),
            matching: find.byType(Scrollable),
          ),
        );

    testWidgets('la lista e alta quanto la locandina e non un pezzo di piu',
        (tester) async {
      await pumpRow(tester, itemWidth: 120);

      // 52px sono la firma del bug: senza, la lista finisce a 180 e la
      // locandina occupa tutta la riga.
      expect(listHeight(tester).height, 180);
    });

    testWidgets('l altezza segue la larghezza della card', (tester) async {
      await pumpRow(tester, itemWidth: 160);

      expect(listHeight(tester).height, 240);
    });

    testWidgets('la freccia sta al centro della locandina', (tester) async {
      await pumpRow(tester, itemWidth: 120);

      // Era ancorata a 52px dal fondo per non coprire il blocco testo che non
      // c'e' piu': restare li' la faceva galleggiare sopra le card invece di
      // starci dentro.
      final arrow = find.byIcon(Icons.chevron_right);
      expect(arrow, findsOneWidget);

      final list = tester.getRect(
        find.descendant(
          of: find.byType(ContentRow),
          matching: find.byType(Scrollable),
        ),
      );
      expect((tester.getCenter(arrow).dy - list.center.dy).abs(), lessThan(2));
    });

    testWidgets('fra una riga e l altra non c e un vuoto', (tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      Widget row(String title) => ContentRow(
            title: title,
            itemCount: 6,
            itemWidth: 120,
            itemBuilder: (_, _) => const Placeholder(),
          );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            // `shrinkWrap` non serve: due righe in colonna sono gia' alte
            // meno dello schermo, e senza il parent che si espande si
            // misurerebbe l'altezza del viewport invece di quella delle righe.
            body: Column(
              mainAxisSize: MainAxisSize.min,
              children: [row('In corso'), row('Piu votati')],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Il vuoto che si vede e' quello fra la fine di una fila di locandine e
      // l'inizio della successiva, cioe' i due padding sommati piu' l'altezza
      // delle due intestazioni. Il padding da solo e' meta' di quel vuoto: con
      // 24 sopra e 24 sotto diventava 48px proprio dove l'occhio attraversa le
      // sezioni.
      final primo = tester.getRect(
        find.descendant(of: find.byType(ContentRow).first,
            matching: find.byType(Scrollable)),
      );
      final secondo = tester.getRect(
        find.descendant(of: find.byType(ContentRow).last,
            matching: find.byType(Scrollable)),
      );

      expect(secondo.top - primo.bottom, lessThan(120));
    });
  });

  group('scheletro della griglia', () {
    testWidgets('la cella promette la stessa altezza della card vera',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PosterGridSkeleton(columns: 4, itemWidth: 100),
          ),
        ),
      );
      // `pumpAndSettle` non va: lo scheletro pulsa per sempre e non si assesta
      // mai. Un solo frame basta a misurare.
      await tester.pump();

      // L'altezza viene dal chiamante (`itemWidth` per 3/2), non dalla larghezza
      // reale della cella: il padding laterale della griglia se ne mangia un
      // pezzo. Quello che conta e' che l'altezza sia quella promisesa dal
      // chiamante — altrimenti la pagina cresce di un colpo quando i dati
      // arrivano.
      expect(tester.getSize(find.byType(SkeletonBox).first).height, 150);
    });
  });
}