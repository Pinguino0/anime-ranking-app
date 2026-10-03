import 'package:animerank/core/error/app_failure.dart';
import 'package:animerank/core/router/app_router.dart';
import 'package:animerank/features/groups/domain/group.dart';
import 'package:animerank/features/groups/presentation/screens/group_picker_screen.dart';
import 'package:animerank/features/groups/presentation/groups_controller.dart';
import 'package:animerank/features/auth/presentation/auth_controller.dart';
import 'package:animerank/features/shell/presentation/shell_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'helpers/fake_auth.dart';
import 'helpers/fake_groups.dart';

/// Schermata finta che dichiara dove si e' arrivati.
class _Landed extends StatelessWidget {
  const _Landed({required this.section, required this.groupId, this.name});

  final String section;
  final String groupId;
  final String? name;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(name ?? section)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [Text(section), Text(groupId)],
        ),
      ),
    );
  }
}

void main() {
  late FakeGroupsRepository repo;

  setUp(() => repo = FakeGroupsRepository());

  /// Monta il selettore dentro un router vero, con tutte le destinazioni che
  /// puo' raggiungere.
  ///
  /// Serve una rotta vera per ogni gruppo: il selettore usa `pushReplacement`,
  /// quindi senza una destinazione registrata la prova misurerebbe un errore di
  /// navigazione invece della scelta del gruppo.
  Future<void> pumpPicker(
    WidgetTester tester,
    GroupSection section, {
    FakeGroupsRepository? repository,
  }) async {
    final r = repository ?? repo;

    final router = GoRouter(
      initialLocation: section.pickerRoute,
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('shell')),
        ),
        GoRoute(
          path: AppRoutes.rankingPicker,
          builder: (_, _) =>
              const GroupPickerScreen(section: GroupSection.ranking),
        ),
        GoRoute(
          path: AppRoutes.watchlistPicker,
          builder: (_, _) =>
              const GroupPickerScreen(section: GroupSection.watchlist),
        ),
        GoRoute(
          path: AppRoutes.duelsPicker,
          builder: (_, _) =>
              const GroupPickerScreen(section: GroupSection.duels),
        ),
        GoRoute(
          path: AppRoutes.tournamentsPicker,
          builder: (_, _) =>
              const GroupPickerScreen(section: GroupSection.tournaments),
        ),
        // Destinazioni finte che dichiarano dove si e' finiti: montare le
        // schermate vere richiederebbe anche i loro repository, e un errore di
        // provider nasconderebbe proprio la navigazione che il test controlla.
        GoRoute(
          path: '/ranking/:groupId',
          builder: (_, state) => _Landed(
            section: 'classifica',
            groupId: state.pathParameters['groupId']!,
            name: state.extra as String?,
          ),
        ),
        GoRoute(
          path: '/watchlist/:groupId',
          builder: (_, _) => const SizedBox.shrink(),
        ),
        GoRoute(
          path: '/duels/:groupId',
          builder: (_, _) => const SizedBox.shrink(),
        ),
        GoRoute(
          path: '/tournaments/:groupId',
          builder: (_, _) => const SizedBox.shrink(),
        ),
        GoRoute(
          path: AppRoutes.createGroup,
          builder: (_, _) => const SizedBox.shrink(),
        ),
        GoRoute(
          path: AppRoutes.joinGroup,
          builder: (_, _) => const SizedBox.shrink(),
        ),
        GoRoute(
          path: AppRoutes.groups,
          builder: (_, _) => const SizedBox.shrink(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [groupsRepositoryProvider.overrideWithValue(r)],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('GroupSection', () {
    test('ogni sezione ha una rotta propria senza gruppo', () {
      // Le quattro sezioni stanno su percorsi diversi: `/ranking` non puo'
      // rispondere anche per i duelli, o la scelta del gruppo si perderebbe.
      final pickers = GroupSection.values.map((s) => s.pickerRoute).toSet();
      expect(pickers.length, 4);
      expect(pickers, {'/ranking', '/watchlist', '/duels', '/tournaments'});
    });

    test('il percorso col gruppo e quello senza', () {
      expect(GroupSection.ranking.route('g1'), '/ranking/g1');
      expect(GroupSection.watchlist.route('g1'), '/watchlist/g1');
      expect(GroupSection.duels.route('g1'), '/duels/g1');
      expect(GroupSection.tournaments.route('g1'), '/tournaments/g1');
    });
  });

  group('selettore', () {
    testWidgets('con piu\' gruppi chiede quale aprire', (tester) async {
      repo = FakeGroupsRepository(
        initial: [
          buildGroup(id: 'g1', name: 'Sala pausa'),
          buildGroup(
            id: 'g2',
            name: 'Amici del sabato',
            description: 'Guardiamo insieme',
          ),
        ],
      );

      await pumpPicker(tester, GroupSection.ranking);

      expect(find.text('Sala pausa'), findsOneWidget);
      expect(find.text('Amici del sabato'), findsOneWidget);
      // Il titolo dice quale sezione si sta scegliendo: la stessa lista serve
      // per quattro sezioni diverse.
      expect(find.text('Classifica'), findsOneWidget);
    });

    testWidgets('scegliere un gruppo apre quella sezione', (tester) async {
      repo = FakeGroupsRepository(
        initial: [
          buildGroup(id: 'g1', name: 'Sala pausa'),
          buildGroup(id: 'g2', name: 'Amici del sabato'),
        ],
      );

      await pumpPicker(tester, GroupSection.ranking);
      await tester.tap(find.text('Sala pausa'));
      await tester.pumpAndSettle();

      // Il selettore sparisce e resta la sezione: premere "indietro" non deve
      // riportare alla scelta, altrimenti serve un doppio indietro per uscire.
      expect(find.byType(GroupPickerScreen), findsNothing);
      expect(find.text('classifica'), findsOneWidget);
      expect(find.text('g1'), findsOneWidget);
      // Il nome del gruppo viaggia in `extra` e finisce nell'app bar: senza,
      // la sezione mostrerebbe un titolo generico e sembrerebbe che il gruppo
      // non sia stato scelto.
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Sala pausa'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('con un solo gruppo va diretto alla sezione', (tester) async {
      repo = FakeGroupsRepository(
        initial: [buildGroup(id: 'g1', name: 'Sala pausa')],
      );

      await pumpPicker(tester, GroupSection.ranking);

      // Con un solo gruppo la scelta e' implicita: la lista comparirebbe e
      // l'utente dovrebbe comunque confermare l'unica opzione.
      expect(find.byType(ListTile), findsNothing);
      expect(find.text('classifica'), findsOneWidget);
    });

    testWidgets('senza gruppi spiega come crearne uno', (tester) async {
      await pumpPicker(tester, GroupSection.duels);

      expect(find.text('Duelli per gruppo'), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, 'Crea un gruppo'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(OutlinedButton, 'Ho un codice invito'),
        findsOneWidget,
      );
    });

    testWidgets('un errore offre il retry', (tester) async {
      repo = FakeGroupsRepository()
        ..listFailure = const GroupsFailure(
          'Rete assente.',
          isRetryable: false,
        );
      await pumpPicker(tester, GroupSection.watchlist);

      expect(find.textContaining('Rete assente.'), findsOneWidget);

      repo.listFailure = null;
      await tester.tap(find.widgetWithText(FilledButton, 'Riprova'));
      await tester.pumpAndSettle();

      expect(repo.listCalls, 2);
    });
  });

  group('shell', () {
    Future<void> pumpShell(
      WidgetTester tester, {
      List<AnimeGroup>? groups,
    }) async {
      final r = FakeGroupsRepository(initial: groups);

      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, _) => const ShellScreen()),
          GoRoute(
            path: AppRoutes.groups,
            builder: (_, _) => const SizedBox.shrink(),
          ),
          GoRoute(
            path: AppRoutes.profile,
            builder: (_, _) => const SizedBox.shrink(),
          ),
          GoRoute(
            path: AppRoutes.rankingPicker,
            builder: (_, _) =>
                const GroupPickerScreen(section: GroupSection.ranking),
          ),
          GoRoute(
            path: AppRoutes.duelsPicker,
            builder: (_, _) =>
                const GroupPickerScreen(section: GroupSection.duels),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(1200, 900)),
          child: ProviderScope(
            overrides: [
              groupsRepositoryProvider.overrideWithValue(r),
              // La shell legge l'email per confermare la sessione: senza il
              // finto, il provider solleverebbe e la schermata non si
              // costruirebbe.
              authRepositoryProvider.overrideWithValue(FakeAuthRepository()),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('le sezioni non sono piu segnaposto', (tester) async {
      await pumpShell(tester);

      // Con la nuova shell, se non ci sono gruppi viene mostrato il messaggio
      // di benvenuto invece della vecchia landing con le sezioni.
      expect(find.text('Benvenuto'), findsOneWidget);
      expect(
        find.textContaining('non sono ancora state scritte'),
        findsNothing,
      );
      expect(
        find.textContaining('Ogni sezione appartiene a un gruppo'),
        findsNothing,
      );
    });

    testWidgets('la voce Duelli porta al selettore', (tester) async {
      await pumpShell(tester);

      await tester.tap(find.text('Duelli').first);
      await tester.pumpAndSettle();

      expect(find.text('Duelli per gruppo'), findsOneWidget);
    });

    testWidgets('la voce Classifica porta al selettore', (tester) async {
      await pumpShell(tester);

      await tester.tap(find.text('Classifica').first);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Non fai parte di nessun gruppo'),
        findsOneWidget,
      );
    });
  });
}
