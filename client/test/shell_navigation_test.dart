import 'package:animerank/core/router/app_router.dart';
import 'package:animerank/features/auth/presentation/auth_controller.dart';
import 'package:animerank/features/groups/presentation/groups_controller.dart';
import 'package:animerank/features/shell/presentation/shell_screen.dart';
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
/// sezioni, indice 6. Passare 6 a una `NavigationBar` con cinque destinazioni
/// fa scattare l'assertion "0 <= selectedIndex < destinations.length" e
/// chiude l'app nel momento in cui l'utente tocca "Profilo".
///
/// Le rotte qui sono sorelle come in `app_router.dart`: il push infila la
/// pagina profilo sopra la shell, che resta montata ma offstage. Per questo i
/// finder usano `skipOffstage: false`.
void main() {
  Future<GoRouter> pumpPhoneShell(WidgetTester tester) async {
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
        // Sotto i 900px scatta la bottom bar invece della sidebar.
        data: const MediaQueryData(size: Size(420, 880)),
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
  NavigationBar barOf(WidgetTester tester) =>
      tester.widget<NavigationBar>(find.byType(NavigationBar, skipOffstage: false));

  testWidgets('la barra del telefono ha cinque voci', (tester) async {
    await pumpPhoneShell(tester);

    expect(barOf(tester).destinations.length, 5);
    expect(barOf(tester).selectedIndex, inInclusiveRange(0, 4));
  });

  testWidgets('toccare Profilo non chiude l app', (tester) async {
    await pumpPhoneShell(tester);

    await tester.tap(find.text('Profilo'));
    await tester.pumpAndSettle();

    // Nessuna eccezione: qui il test fallirebbe con l'assertion della barra.
    // Prima della correzione l'indice era 6 su cinque destinazioni.
    expect(barOf(tester).selectedIndex, 4);
  });

  testWidgets('tornare su una sezione con voce ripristina l indice', (tester) async {
    final router = await pumpPhoneShell(tester);

    await tester.tap(find.text('Profilo'));
    await tester.pumpAndSettle();
    expect(barOf(tester).selectedIndex, 4);

    router.pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Gruppi'));
    await tester.pumpAndSettle();

    expect(barOf(tester).selectedIndex, 1);
  });
}