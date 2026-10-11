import 'package:animerank/core/theme/app_theme.dart';
import 'package:animerank/features/anime/presentation/anime_controller.dart';
import 'package:animerank/features/anime/presentation/screens/anime_detail_screen.dart';
import 'package:animerank/features/groups/domain/group.dart';
import 'package:animerank/features/groups/presentation/groups_controller.dart';
import 'package:animerank/features/ranking/presentation/ranking_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_anime.dart';
import 'helpers/fake_groups.dart';
import 'helpers/fake_ranking.dart';

/// Voto dalla scheda anime.
///
/// La scheda sa *cosa* votare ma non *dove*: prima mostrava un avviso che
/// rimandava alla classifica, lasciando l'utente davanti a un pulsante che non
/// lo faceva votare. Questi test verificano che il tocco porti davvero al
/// salvataggio, con il gruppo giusto.
Widget _host({
  required List<AnimeGroup> groups,
  required FakeRankingRepository ranking,
}) {
  return ProviderScope(
    overrides: [
      animeRepositoryProvider.overrideWithValue(FakeAnimeRepository()),
      groupsRepositoryProvider.overrideWithValue(
        FakeGroupsRepository(initial: groups),
      ),
      rankingRepositoryProvider.overrideWithValue(ranking),
    ],
    child: MaterialApp(
      theme: AppTheme.dark,
      home: MediaQuery(
        data: const MediaQueryData(size: Size(400, 1400)),
        child: Scaffold(
          body: AnimeDetailScreen(entry: animeFixture(title: 'Cowboy Bebop')),
        ),
      ),
    ),
  );
}

Future<void> _tapVote(WidgetTester tester) async {
  final button = find.text('Vota in un gruppo');
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('con un solo gruppo apre subito il foglio e salva', (tester) async {
    final ranking = FakeRankingRepository();
    await tester.pumpWidget(_host(groups: [buildGroup()], ranking: ranking));
    await tester.pump();

    await _tapVote(tester);

    expect(find.text('Vota'), findsOneWidget, reason: 'il foglio deve aprirsi');
    await tester.tap(find.text('Vota'));
    await tester.pumpAndSettle();

    expect(ranking.votes, ['g1|id-1|7.0']);
    expect(find.textContaining('salvato in Sala pausa'), findsOneWidget);
  });

  testWidgets('con piu\' gruppi chiede dove contare il voto', (tester) async {
    final ranking = FakeRankingRepository();
    await tester.pumpWidget(
      _host(
        groups: [
          buildGroup(id: 'g1', name: 'Primo'),
          buildGroup(id: 'g2', name: 'Secondo'),
        ],
        ranking: ranking,
      ),
    );
    await tester.pump();

    await _tapVote(tester);

    expect(find.text('Dove contare il voto?'), findsOneWidget);
    await tester.tap(find.text('Secondo'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Vota'));
    await tester.pumpAndSettle();

    expect(ranking.votes, ['g2|id-1|7.0']);
  });

  testWidgets('senza gruppi non apre il voto e lo spiega', (tester) async {
    final ranking = FakeRankingRepository();
    await tester.pumpWidget(_host(groups: const [], ranking: ranking));
    await tester.pump();

    await _tapVote(tester);

    expect(find.text('Vota'), findsNothing);
    expect(
      find.textContaining('Non fai parte di nessun gruppo'),
      findsOneWidget,
    );
    expect(ranking.votes, isEmpty);
  });
}
