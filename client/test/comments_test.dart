import 'package:animerank/core/theme/app_theme.dart';
import 'package:animerank/features/comments/domain/comment.dart';
import 'package:animerank/features/comments/presentation/comments_controller.dart';
import 'package:animerank/features/comments/presentation/widgets/discussion_section.dart';
import 'package:animerank/features/groups/presentation/groups_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_comments.dart';
import 'helpers/fake_groups.dart';

void main() {
  ProviderContainer container(FakeCommentsRepository repo) {
    final c = ProviderContainer(
      overrides: [commentsRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> pumpSection(
    WidgetTester tester, {
    required FakeCommentsRepository comments,
    required FakeGroupsRepository groups,
    String animeId = 'a1',
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          commentsRepositoryProvider.overrideWithValue(comments),
          groupsRepositoryProvider.overrideWithValue(groups),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: SingleChildScrollView(
              child: DiscussionSection(animeId: animeId),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('Comment', () {
    test('parse legge il profilo incastonato', () {
      final comment = Comment.parse({
        'id': 'c1',
        'group_id': 'g1',
        'anime_id': 'a1',
        'user_id': 'u1',
        'parent_id': null,
        'content': 'Ciao',
        'is_spoiler': true,
        'created_at': '2026-05-01T10:00:00Z',
        'updated_at': '2026-05-01T10:00:00Z',
        'profiles': {'username': 'asuka', 'avatar_url': null},
      });

      expect(comment.authorName, 'asuka');
      expect(comment.isSpoiler, isTrue);
      expect(comment.isRoot, isTrue);
      expect(comment.isEdited, isFalse);
    });

    test('authorLabel fa da fallback quando il nome manca', () {
      expect(buildComment(authorName: '').authorLabel, 'Utente');
    });

    test('isEdited e vero solo se updated_at si allontana da created_at', () {
      final base = DateTime(2026, 5, 1, 10);
      expect(buildComment(createdAt: base, updatedAt: base).isEdited, isFalse);
      expect(
        buildComment(
          createdAt: base,
          updatedAt: base.add(const Duration(minutes: 5)),
        ).isEdited,
        isTrue,
      );
    });
  });

  group('CommentValidators', () {
    test('rifiuta il vuoto e i soli spazi', () {
      expect(CommentValidators.contentError(''), isNotNull);
      expect(CommentValidators.contentError('   '), isNotNull);
    });

    test('rifiuta oltre il limite', () {
      final tooLong = 'a' * (CommentValidators.maxLength + 1);
      expect(CommentValidators.contentError(tooLong), isNotNull);
    });

    test('accetta un testo normale, anche con spazi ai bordi', () {
      expect(CommentValidators.contentError('  bello  '), isNull);
    });
  });

  group('CommentsController', () {
    test('carica i commenti della discussione', () async {
      final repo = FakeCommentsRepository(comments: [buildComment()]);
      final c = container(repo);

      final values =
          await c.read(commentsProvider((groupId: 'g1', animeId: 'a1')).future);

      expect(values, hasLength(1));
      expect(repo.loadCalls, 1);
    });

    test('post pubblica e rilegge', () async {
      final repo = FakeCommentsRepository();
      final c = container(repo);
      final provider = commentsProvider((groupId: 'g1', animeId: 'a1'));

      await c.read(provider.future);
      await c.read(provider.notifier).post(content: 'Ciao', spoiler: false);

      expect(repo.addCalls, 1);
      expect(repo.lastAdd?.content, 'Ciao');

      final values = await c.read(provider.future);
      expect(values, hasLength(1));
      expect(repo.loadCalls, 2);
    });

    test('remove elimina e rilegge', () async {
      final repo = FakeCommentsRepository(comments: [buildComment()]);
      final c = container(repo);
      final provider = commentsProvider((groupId: 'g1', animeId: 'a1'));

      await c.read(provider.future);
      await c.read(provider.notifier).remove('c1');

      expect(repo.deleteCalls, 1);
      final values = await c.read(provider.future);
      expect(values, isEmpty);
    });
  });

  group('sezione discussione', () {
    testWidgets('senza gruppi spiega che serve un gruppo', (tester) async {
      await pumpSection(
        tester,
        comments: FakeCommentsRepository(),
        groups: FakeGroupsRepository(),
      );

      expect(find.textContaining('Entra in un gruppo'), findsOneWidget);
      expect(find.text('Pubblica'), findsNothing);
    });

    testWidgets('pubblica un commento e lo mostra', (tester) async {
      final repo = FakeCommentsRepository();
      await pumpSection(
        tester,
        comments: repo,
        groups: FakeGroupsRepository(initial: [buildGroup()]),
      );

      expect(find.text('Ancora nessun commento. Inizia tu.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Bello questo anime');
      await tester.tap(find.text('Pubblica'));
      await tester.pumpAndSettle();

      expect(repo.addCalls, 1);
      expect(repo.lastAdd?.content, 'Bello questo anime');
      expect(find.text('Bello questo anime'), findsOneWidget);
    });

    testWidgets('nasconde lo spoiler finche non lo si scopre', (tester) async {
      final repo = FakeCommentsRepository(
        comments: [buildComment(content: 'Muore a meta', isSpoiler: true)],
      );
      await pumpSection(
        tester,
        comments: repo,
        groups: FakeGroupsRepository(initial: [buildGroup()]),
      );

      expect(find.text('Muore a meta'), findsNothing);

      await tester.tap(find.text('Mostra spoiler'));
      await tester.pumpAndSettle();

      expect(find.text('Muore a meta'), findsOneWidget);
    });

    testWidgets('risponde a un commento', (tester) async {
      final repo = FakeCommentsRepository(
        comments: [buildComment(id: 'root', authorName: 'asuka')],
      );
      await pumpSection(
        tester,
        comments: repo,
        groups: FakeGroupsRepository(initial: [buildGroup()]),
      );

      await tester.tap(find.text('Rispondi'));
      await tester.pumpAndSettle();
      expect(find.text('Rispondi a asuka'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Concordo');
      await tester.tap(find.text('Pubblica'));
      await tester.pumpAndSettle();

      expect(repo.lastAdd?.parentId, 'root');
    });

    testWidgets('permette di eliminare un proprio commento', (tester) async {
      final repo = FakeCommentsRepository(
        currentUserId: 'me',
        comments: [buildComment(userId: 'me', authorName: 'me')],
      );
      await pumpSection(
        tester,
        comments: repo,
        groups: FakeGroupsRepository(initial: [buildGroup()]),
      );

      await tester.tap(find.widgetWithText(TextButton, 'Elimina'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Elimina'));
      await tester.pumpAndSettle();

      expect(repo.deleteCalls, 1);
      expect(find.text('Bello!'), findsNothing);
    });

    testWidgets('un commento altrui non si puo eliminare', (tester) async {
      final repo = FakeCommentsRepository(
        currentUserId: 'me',
        comments: [buildComment(userId: 'altro')],
      );
      await pumpSection(
        tester,
        comments: repo,
        groups: FakeGroupsRepository(initial: [buildGroup()]),
      );

      expect(find.text('Elimina'), findsNothing);
    });

    testWidgets('con piu gruppi il selettore cambia discussione',
        (tester) async {
      final repo = FakeCommentsRepository(
        comments: [buildComment(groupId: 'g2', content: 'Nel secondo')],
      );
      await pumpSection(
        tester,
        comments: repo,
        groups: FakeGroupsRepository(
          initial: [
            buildGroup(id: 'g1', name: 'Primo'),
            buildGroup(id: 'g2', name: 'Secondo'),
          ],
        ),
      );

      // La prima e' vuota; il commento vive nel secondo gruppo.
      expect(find.text('Nel secondo'), findsNothing);

      await tester.tap(find.text('Secondo'));
      await tester.pumpAndSettle();

      expect(find.text('Nel secondo'), findsOneWidget);
    });

    testWidgets('un errore di caricamento offre il retry', (tester) async {
      final repo = FakeCommentsRepository()
        ..loadFailure = const CommentsFailure('Commenti non disponibili. Riprova.');
      await pumpSection(
        tester,
        comments: repo,
        groups: FakeGroupsRepository(initial: [buildGroup()]),
      );

      expect(find.text('Commenti non disponibili. Riprova.'), findsOneWidget);

      repo.loadFailure = null;
      await tester.tap(find.text('Riprova'));
      await tester.pumpAndSettle();

      expect(find.text('Ancora nessun commento. Inizia tu.'), findsOneWidget);
    });
  });
}
