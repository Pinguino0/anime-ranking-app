import 'package:animerank/core/router/app_router.dart';
import 'package:animerank/features/auth/presentation/auth_controller.dart';
import 'package:animerank/features/groups/presentation/groups_controller.dart';
import 'package:animerank/features/shell/presentation/shell_screen.dart';
import 'package:animerank/features/shell/presentation/widgets/shell_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'helpers/fake_auth.dart';
import 'helpers/fake_groups.dart';

/// Navigazione della shell da telefono.
///
/// Il crash che questi test coprono: la barra in basso ha quattro sezioni piu'
/// il profilo, quindi cinque voci. Il profilo pero' e' l'ultima delle sette
/// sezioni, indice 6. Passare 6 a una barra con cinque destinazioni
/// fa scattare l'assertion "0 <= selectedIndex < destinations.length" e
/// chiude l'app nel momento in cui l'utente tocca "Profilo".
///
/// La barra non e' piu' quella di Material: e' [ArBottomBar], disegnata a mano
/// con lo stesso contratto. I test ne controllano l'indice, quindi valgono per
/// entrambe le versioni.
///
/// Le rotte qui sono sorelle come in `app_router.dart`: il push infila la
/// pagina profilo sopra la shell, che resta montata ma offstage. Per questo i
/// finder usano `skipOffstage: false`.
void main() {
  /// Monta la shell alla larghezza richiesta.
  ///
  /// Sotto i 900px scatta la barra in basso, da 900px in su la colonna
  /// laterale: e' la stessa soglia di `Breakpoints`, quindi i test possono
  /// scegliere il formato senza sapere come e' fatto lo scheletro.
  Future<GoRouter> pumpShell(
    WidgetTester tester, {
    Size size = const Size(420, 880),
  }) async {
    Widget leaf(String route) => Scaffold(body: Text('foglia $route'));

    final router = GoRouter(
      initialLocation: AppRoutes.home,
      routes: [
        GoRoute(path: AppRoutes.home, builder: (_, _) => const ShellScreen()),
        for (final route in [
          AppRoutes.groups,
          AppRoutes.animeSearch,
          AppRoutes.rankingPicker,
          AppRoutes.watchlistPicker,
          AppRoutes.profile,
        ])
          GoRoute(path: route, builder: (_, _) => leaf(route)),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: size),
        child: ProviderScope(
          overrides: [
            groupsRepositoryProvider.overrideWithValue(FakeGroupsRepository()),
            authRepositoryProvider.overrideWithValue(FakeAuthRepository()),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  /// La barra del telefono, anche quando coperta dal push.
  ArBottomBar barOf(WidgetTester tester) =>
      tester.widget<ArBottomBar>(find.byType(ArBottomBar, skipOffstage: false));

  testWidgets('la barra del telefono ha cinque voci', (tester) async {
    await pumpShell(tester);

    expect(barOf(tester).destinations.length, 5);
    expect(barOf(tester).selectedIndex, inInclusiveRange(0, 4));
  });

  testWidgets('toccare Profilo non chiude l app', (tester) async {
    await pumpShell(tester);

    await tester.tap(find.text('Profilo'));
    await tester.pumpAndSettle();

    // Nessuna eccezione: qui il test fallirebbe con l'assertion della barra.
    // Prima della correzione l'indice era 6 su cinque destinazioni.
    expect(barOf(tester).selectedIndex, 4);
  });

  testWidgets('tornare su una sezione con voce ripristina l indice', (tester) async {
    final router = await pumpShell(tester);

    await tester.tap(find.text('Profilo'));
    await tester.pumpAndSettle();
    expect(barOf(tester).selectedIndex, 4);

    router.pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Gruppi'));
    await tester.pumpAndSettle();

    expect(barOf(tester).selectedIndex, 1);
  });

  group('colonna laterale', () {
    /// La colonna laterale, anche quando la copre il push.
    ArNavRail railOf(WidgetTester tester) =>
        tester.widget<ArNavRail>(find.byType(ArNavRail, skipOffstage: false));

    testWidgets('da desktop mostra tutte le sette sezioni', (tester) async {
      // Sette e non cinque: la colonna laterale ha spazio per tutte le voci,
      // e toglierne due perche' "c'era anche nella barra" lascerebbe Duelli e
      // Tornei senza un modo per aprirli da desktop.
      await pumpShell(tester, size: const Size(1200, 900));

      expect(railOf(tester).destinations.length, 7);
      // Tutte le ricerche sono ancorate alla colonna e non a "qualunque
      // ListView": quando l'utente non ha ancora un gruppo, il contenuto
      // centrale mostra la schermata di benvenuto, che ha una lista sua e il
      // segno dell'app. Senza questo filtro una voce come "Anime" — che e'
      // anche la prima parola del segno — verrebbe contata due volte.
      // Tre livelli di vincolo — colonna, lista delle voci, testo — perche' il
      // segno dell'app e' dentro la colonna e "Anime" e' anche una voce: con il
      // solo vincolo sulla colonna la parola verrebbe contata due volte.
      final voci = find.descendant(
        of: find.byType(ArNavRail),
        matching: find.byType(ListView),
      );
      for (final label in [
        'Anime',
        'Gruppi',
        'Classifica',
        'Watchlist',
        'Duelli',
        'Tornei',
        'Profilo',
      ]) {
        expect(
          find.descendant(of: voci, matching: find.text(label)),
          findsOneWidget,
          reason: 'manca $label',
        );
      }
    });

    testWidgets('il nome dell app sta nella colonna', (tester) async {
      // Il segno era testo semplice: senza un richiamo visivo la colonna e'
      // solo un elenco di icone e non si sa piu' di che app si tratta.
      await pumpShell(tester, size: const Size(1200, 900));

      final mark = find.descendant(of: find.byType(ArNavRail), matching: find.byType(BrandMark));
      expect(mark, findsOneWidget);
      expect(find.descendant(of: mark, matching: find.text('Anime')), findsOneWidget);
      expect(find.descendant(of: mark, matching: find.text('Rank')), findsOneWidget);
    });

    testWidgets('toccare una voce la segna come attiva', (tester) async {
      await pumpShell(tester, size: const Size(1200, 900));

      expect(railOf(tester).selectedIndex, 0);

      await tester.tap(find.text('Watchlist'));
      await tester.pumpAndSettle();

      expect(railOf(tester).selectedIndex, 3);
    });

    testWidgets('su finestra bassa le voci restano raggiungibili', (tester) async {
      // Sette voci piu' il segno non ci starebbero in una colonna fissa: senza
      // scorrimento, l'ultima voce — quella del profilo — verrebbe tagliata via
      // e la sezione aperta sparirebbe dalla navigazione proprio mentre la si
      // sta leggendo.
      await pumpShell(tester, size: const Size(920, 420));

      expect(tester.takeException(), isNull);
      expect(
        find.descendant(of: find.byType(ArNavRail), matching: find.byType(BrandMark)),
        findsOneWidget,
      );

      // La lista da trascinare e' quella dentro la colonna: il contenuto
      // centrale ne ha una sua, e senza il vincolo il trascinamento finirebbe
      // sulla prima incontrata.
      final voci = find.descendant(of: find.byType(ArNavRail), matching: find.byType(ListView));
      await tester.drag(voci, const Offset(0, -400));
      await tester.pumpAndSettle();

      expect(find.text('Profilo'), findsOneWidget);
    });
  });
}