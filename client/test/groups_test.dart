import 'package:animerank/core/error/app_failure.dart';
import 'package:animerank/core/error/app_retry.dart';
import 'package:animerank/features/groups/data/groups_repository.dart';
import 'package:animerank/features/groups/domain/group.dart';
import 'package:animerank/features/groups/presentation/screens/create_group_screen.dart';
import 'package:animerank/features/groups/presentation/screens/group_detail_screen.dart';
import 'package:animerank/features/groups/presentation/screens/groups_list_screen.dart';
import 'package:animerank/features/groups/presentation/screens/join_group_screen.dart';
import 'package:animerank/features/groups/presentation/groups_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'helpers/fake_groups.dart';

void main() {
  group('appRetry', () {
    test('un errore non ripetibile non viene ritentato', () {
      // Senza questo controllo Riverpod riproverebbe "permessi insufficienti"
      // con backoff e l utente vedrebbe uno spinner al posto dell errore.
      expect(appRetry(0, const GroupsFailure('Permessi insufficienti.')), isNull);
    });

    test('un errore ripetibile viene ritentato con attese crescenti', () {
      expect(appRetry(0, const GroupsFailure('Riprova.', isRetryable: true)), isNotNull);
      expect(
        appRetry(1, const GroupsFailure('Riprova.', isRetryable: true)),
        greaterThan(appRetry(0, const GroupsFailure('Riprova.', isRetryable: true))!),
      );
    });

    test('i tentativi sono limitati', () {
      expect(appRetry(3, const GroupsFailure('Riprova.', isRetryable: true)), isNull);
    });

    test('un errore non tipizzato non viene ritentato', () {
      expect(appRetry(0, StateError('boom')), isNull);
    });
  });

  group('GroupRole', () {
    test('l ordine dei ruoli e crescente', () {
      expect(GroupRole.member.rank, lessThan(GroupRole.admin.rank));
      expect(GroupRole.admin.rank, lessThan(GroupRole.owner.rank));
    });

    test('solo owner e admin possono amministrare', () {
      expect(GroupRole.member.canManage, isFalse);
      expect(GroupRole.admin.canManage, isTrue);
      expect(GroupRole.owner.canManage, isTrue);
    });

    test('solo l owner assegna i ruoli', () {
      // Il backend limita set_member_role al solo owner: mostrarne il
      // controllo agli admin insegnerebbe all utente un azione che il server
      // rifiuta.
      expect(GroupRole.admin.canAssignRoles, isFalse);
      expect(GroupRole.owner.canAssignRoles, isTrue);
    });

    test('un ruolo sconosciuto vale come membro', () {
      // Permessi minimi: meglio una riga con meno opzioni che un crash.
      expect(GroupRole.fromName('qualcosa'), GroupRole.member);
      expect(GroupRole.fromName(null), GroupRole.member);
      expect(GroupRole.fromName('owner'), GroupRole.owner);
    });
  });

  group('AnimeGroup.parse', () {
    test('legge il ruolo dalla join su group_members', () {
      final group = AnimeGroup.parse({
        'id': 'g1',
        'name': 'Sala pausa',
        'description': 'Si pausa insieme',
        'invite_code': 'ANIME-000001',
        'owner_id': 'u1',
        'created_at': '2026-01-02T10:00:00Z',
        'group_members': [
          {'role': 'admin', 'user_id': 'me'},
        ],
      });

      expect(group.myRole, GroupRole.admin);
      expect(group.canSeeInviteCode, isTrue);
      expect(group.createdAt.toUtc(), DateTime.utc(2026, 1, 2, 10));
    });

    test('una risposta incompleta non fa esplodere la lista', () {
      // Campi mancanti o di tipo diverso non devono far cadere tutta la
      // schermata: peggio un gruppo con pochi dati che nessun gruppo.
      final group = AnimeGroup.parse({'id': 'g2', 'group_members': const <dynamic>[]});

      expect(group.name, 'Senza nome');
      expect(group.myRole, GroupRole.member);
      expect(group.inviteCode, '');
    });

    test('senza descrizione il sottotitolo mostra il ruolo', () {
      final group = buildGroup(description: '', role: GroupRole.admin);

      expect(group.description, isEmpty);
      expect(group.subtitle, 'Admin');
    });

    test('due righe dello stesso gruppo non sonoduplicate', () {
      expect(buildGroup(id: 'g1'), buildGroup(id: 'g1'));
      expect(buildGroup(id: 'g1'), isNot(buildGroup(id: 'g2')));
    });
  });

  group('GroupValidators', () {
    test('il nome vuoto non va bene', () {
      expect(GroupValidators.nameError(''), isNotNull);
      expect(GroupValidators.nameError('   '), isNotNull);
    });

    test('il nome entro 60 caratteri va bene', () {
      expect(GroupValidators.nameError('a'), isNull);
      expect(GroupValidators.nameError('x' * 60), isNull);
      expect(GroupValidators.nameError('x' * 61), isNotNull);
    });

test('il nome viene contato senza spazi', () {
      // Il backend fa trim: uno spazio finale non deve far scartare un nome
      // che l utente considera valido.
      expect(GroupValidators.nameError('  ${'x' * 60}  '), isNull);
    });

    test('la descrizione e opzionale ma limitata', () {
      expect(GroupValidators.descriptionError(null), isNull);
      expect(GroupValidators.descriptionError(''), isNull);
      expect(GroupValidators.descriptionError('y' * 281), isNotNull);
    });
  });

  group('GroupsListController', () {
    late FakeGroupsRepository repo;

    setUp(() => repo = FakeGroupsRepository());

    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [groupsRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('il primo caricamento chiede i gruppi al repository', () async {
      repo = FakeGroupsRepository(initial: [buildGroup()]);
      final c = container();

      final groups = await c.read(groupsListProvider.future);

      expect(repo.listCalls, 1);
      expect(groups, hasLength(1));
    });

    test('un errore resta visibile e il retry riprova', () async {
      repo.listFailure = const GroupsFailure('Gruppi non disponibili. Riprova.');
      final c = container();

      await expectLater(c.read(groupsListProvider.future), throwsA(isA<GroupsFailure>()));
      expect(c.read(groupsListProvider).hasError, isTrue);

      repo.listFailure = null;
      await c.read(groupsListProvider.notifier).refresh();

      expect(c.read(groupsListProvider).hasError, isFalse);
      expect(repo.listCalls, greaterThan(1));
    });

    test('la creazione mette il gruppo in cima senza ricaricare', () async {
      repo = FakeGroupsRepository(initial: [buildGroup(id: 'vecchio', name: 'Vecchio')]);
      final c = container();
      await c.read(groupsListProvider.future);

      final created = await c.read(groupsListProvider.notifier).create(name: 'Nuovo');

      // Un reload qui costerebbe una seconda richiesta e, se fallisse,
      // farebbe comparire e sparire il gruppo appena creato.
      expect(repo.listCalls, 1);
      expect(c.read(groupsListProvider).value!.first.id, created.id);
      expect(created.myRole, GroupRole.owner);
    });

    test('l ingresso non duplica un gruppo gia presente', () async {
      repo = FakeGroupsRepository(initial: [buildGroup(id: 'g1')]);
      final c = container();
      await c.read(groupsListProvider.future);

      await c.read(groupsListProvider.notifier).join('ANIME-000001');

      // Il backend non crea una seconda riga di appartenenza: la lista
      // mostrerebbe comunque due voci identiche se non si deduplicasse.
      expect(c.read(groupsListProvider).value!.where((g) => g.id == 'g1'), hasLength(1));
    });

    test('l uscita toglie il gruppo dalla lista', () async {
      repo = FakeGroupsRepository(initial: [buildGroup(id: 'g1'), buildGroup(id: 'g2')]);
      final c = container();
      await c.read(groupsListProvider.future);

      await c.read(groupsListProvider.notifier).leave('g1');

      expect(repo.leaveCalls, 1);
      expect(c.read(groupsListProvider).value!.map((g) => g.id), ['g2']);
    });

    test('il codice rigenerato aggiorna subito la lista', () async {
      repo = FakeGroupsRepository(initial: [buildGroup(id: 'g1')]);
      final c = container();
      await c.read(groupsListProvider.future);

      final code = await c.read(groupsListProvider.notifier).regenerateInviteCode('g1');

      // Il codice e' il dato che l utente sta per condividere: non puo'
      // aspettare un ricaricamento per vederlo.
      expect(c.read(groupsListProvider).value!.first.inviteCode, code);
    });
  });

  group('schermate', () {
    late FakeGroupsRepository repo;

    setUp(() => repo = FakeGroupsRepository());

    /// Monta una schermata dentro un router vero.
    ///
    /// Le schermate di gruppo chiamano `context.go` dopo un'azione riuscita:
    /// senza un GoRouter sotto, la navigazione fallirebbe e il test
    /// misurerebbe un errore di montaggio invece del comportamento della
    /// schermata.
    Future<void> pumpScreen(
      WidgetTester tester,
      Widget child, {
      FakeGroupsRepository? repository,
    }) async {
      final r = repository ?? repo;

      final router = GoRouter(
        initialLocation: '/groups',
        routes: [
          GoRoute(path: '/groups', builder: (_, _) => child),
          GoRoute(path: '/groups/create', builder: (_, _) => const SizedBox.shrink()),
          GoRoute(path: '/groups/join', builder: (_, _) => const SizedBox.shrink()),
          GoRoute(path: '/groups/:id', builder: (_, _) => const SizedBox.shrink()),
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

    testWidgets('la lista vuota spiega cosa fare', (tester) async {
      await pumpScreen(tester, const GroupsListScreen());

      expect(find.text('Non fai parte di nessun gruppo'), findsOneWidget);
      expect(find.text('Crea un gruppo'), findsOneWidget);
      expect(find.text('Ho un codice invito'), findsOneWidget);
    });

    testWidgets('la lista mostra i gruppi', (tester) async {
      await pumpScreen(
        tester,
        const GroupsListScreen(),
        repository: FakeGroupsRepository(initial: [
          buildGroup(id: 'g1', name: 'Sala pausa'),
          buildGroup(id: 'g2', name: 'Stanza uno', role: GroupRole.member),
        ]),
      );

      expect(find.text('Sala pausa'), findsOneWidget);
      expect(find.text('Stanza uno'), findsOneWidget);
      // Un membro semplice non deve vedere il codice invito: non puo'
      // usarlo e non deve scoprire il gruppo a chi non deve.
      expect(find.text('ANIME-000001'), findsNothing);
    });

    testWidgets('un errore di caricamento offre il retry', (tester) async {
      final failing = FakeGroupsRepository()..listFailure = const GroupsFailure('Server assente.');
      await pumpScreen(tester, const GroupsListScreen(), repository: failing);

      expect(find.text('Server assente.'), findsOneWidget);

      failing.listFailure = null;
      await tester.tap(find.text('Riprova'));
      await tester.pumpAndSettle();

      expect(failing.listCalls, 2);
      expect(find.text('Non fai parte di nessun gruppo'), findsOneWidget);
    });

    testWidgets('la creazione rifiuta un nome vuoto', (tester) async {
      await pumpScreen(tester, const CreateGroupScreen());

      await tester.tap(find.widgetWithText(FilledButton, 'Crea il gruppo'));
      await tester.pumpAndSettle();

      expect(find.text('Dai un nome al gruppo.'), findsOneWidget);
      expect(repo.createCalls, 0);
    });

    testWidgets('la creazione mostra l errore del server', (tester) async {
      final failing = FakeGroupsRepository()..createFailure = const GroupsFailure('Nome gia usato.');
      await pumpScreen(tester, const CreateGroupScreen(), repository: failing);

      await tester.enterText(find.byType(TextFormField).first, 'Sala pausa');
      await tester.tap(find.widgetWithText(FilledButton, 'Crea il gruppo'));
      await tester.pumpAndSettle();

      expect(find.text('Nome gia usato.'), findsOneWidget);
      expect(find.text('Crea il gruppo'), findsOneWidget);
    });

    testWidgets('il codice invito viene ripulito e mandato in maiuscolo', (tester) async {
      await pumpScreen(tester, const JoinGroupScreen());

      await tester.enterText(find.byType(TextFormField), 'anime 000001');
      await tester.tap(find.widgetWithText(FilledButton, 'Entra'));
      await tester.pumpAndSettle();

      // Spazi e minuscole vengono dal copia-incolla di un link condiviso:
      // non devono sembrare un errore dell utente.
      expect(repo.joinedCodes, ['ANIME000001']);
    });

    testWidgets('l ingresso mostra l errore del server', (tester) async {
      final failing = FakeGroupsRepository()..joinFailure = const GroupsFailure('Codice non valido.');
      await pumpScreen(tester, const JoinGroupScreen(), repository: failing);

      await tester.enterText(find.byType(TextFormField), 'ANIME-000001');
      await tester.tap(find.widgetWithText(FilledButton, 'Entra'));
      await tester.pumpAndSettle();

      expect(find.text('Codice non valido.'), findsOneWidget);
    });

    testWidgets('il dettaglio di un gruppo non membro dice subito cosa fare', (tester) async {
      await pumpScreen(
        tester,
        const GroupDetailScreen(groupId: 'g1'),
        repository: FakeGroupsRepository(initial: [buildGroup(id: 'altro')]),
      );

      expect(find.text('Non sei membro di questo gruppo.'), findsOneWidget);
    });

    testWidgets('l owner vede il codice e non puo uscire', (tester) async {
      await pumpScreen(
        tester,
        const GroupDetailScreen(groupId: 'g1'),
        repository: FakeGroupsRepository(initial: [buildGroup(role: GroupRole.owner)]),
      );

      expect(find.text('ANIME-000001'), findsOneWidget);
      expect(find.text('Esci dal gruppo'), findsNothing);

      // Come sopra: i controlli del gruppo stanno in fondo, dopo le card delle
      // sezioni, quindi senza scorrere il testo non sarebbe costruito.
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();

      expect(find.textContaining('Sei l owner'), findsOneWidget);
    });

    testWidgets('un membro semplice vede il pulsante di uscita e nessun codice',
        (tester) async {
      await pumpScreen(
        tester,
        const GroupDetailScreen(groupId: 'g1'),
        repository: FakeGroupsRepository(initial: [buildGroup(role: GroupRole.member)]),
      );

      expect(find.text('ANIME-000001'), findsNothing);

      // Le card di classifica, watchlist, duelli e tornei stanno sopra i
      // controlli del gruppo: senza scorrere il bottante di uscita non e'
      // costruito e il test passerebbe anche se il testo fosse sparito.
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();

      expect(find.text('Esci dal gruppo'), findsOneWidget);
    });
  });

  group('GroupMember', () {
    test('legge i campi della riga', () {
      final member = GroupMember.parse({
        'user_id': 'u2',
        'username': 'asuka',
        'avatar_url': 'https://img/a.png',
        'role': 'admin',
        'joined_at': '2026-03-01T10:00:00Z',
      });

      expect(member.userId, 'u2');
      expect(member.username, 'asuka');
      expect(member.role, GroupRole.admin);
      expect(member.joinedAt.year, 2026);
    });

    test('senza username mostra l id, cosi il nome resta leggibile', () {
      // Il backend garantisce l'username, ma un fallback vuoto mostrerebbe una
      // riga senza nome: due voci identiche e non distinguibili.
      final member = GroupMember.parse({'user_id': 'u2'});

      expect(member.label, 'u2');
    });

    test('l owner attuale non puo ricevere la proprieta', () {
      final owner = GroupMember(
        userId: 'u1',
        username: 'me',
        role: GroupRole.owner,
        joinedAt: DateTime(2026),
      );
      final admin = GroupMember(
        userId: 'u2',
        username: 'asuka',
        role: GroupRole.admin,
        joinedAt: DateTime(2026),
      );

      // Il backend rifiuta di cedere la proprieta' a se' stessi: proporre la
      // scelta significa proporre un errore.
      expect(owner.canReceiveOwnership, isFalse);
      expect(admin.canReceiveOwnership, isTrue);
    });
  });

  group('trasferimento della proprieta\'', () {
    late FakeGroupsRepository repo;

    ProviderContainer container() {
      final c = ProviderContainer(overrides: [groupsRepositoryProvider.overrideWithValue(repo)]);
      addTearDown(c.dispose);
      return c;
    }

    test('dopo la cessione chi cede diventa admin', () async {
      repo = FakeGroupsRepository(initial: [buildGroup(role: GroupRole.owner)]);
      final c = container();
      await c.read(groupsListProvider.future);

      await c
          .read(groupsListProvider.notifier)
          .transferOwnership(groupId: 'g1', newOwnerId: 'u2');

      final group = c.read(groupsListProvider).value!.first;
      // Senza questo aggiornamento la schermata direbbe ancora "Sei l owner" e
      // riproporrebbe il pulsante, che il backend rifiuterebbe.
      expect(group.myRole, GroupRole.admin);
      expect(group.ownerId, 'u2');
    });

    test('il gruppo esce con il ruolo giusto senza rileggerlo dal server', () async {
      repo = FakeGroupsRepository(initial: [buildGroup(role: GroupRole.owner)]);
      final c = container();
      await c.read(groupsListProvider.future);
      repo.listCalls = 0;

      await c
          .read(groupsListProvider.notifier)
          .transferOwnership(groupId: 'g1', newOwnerId: 'u2');

      // Il backend aggiorna i ruoli in una transizione sola: rileggere la lista
      // aggiungerebbe una richiesta e mostrerebbe comunque lo stesso risultato.
      expect(repo.transferCalls, 1);
      expect(repo.transfers, ['g1|u2']);
    });

    test('un errore lascia il ruolo com era', () async {
      repo = FakeGroupsRepository(initial: [buildGroup(role: GroupRole.owner)])
        ..transferFailure = const GroupsFailure('Solo il owner puo cedere la proprieta\'');
      final c = container();
      await c.read(groupsListProvider.future);

      await expectLater(
        () => c
            .read(groupsListProvider.notifier)
            .transferOwnership(groupId: 'g1', newOwnerId: 'u2'),
        throwsA(isA<GroupsFailure>()),
      );

      // Senza questo, la schermata mostrerebbe "Sei l owner" anche se la
      // cessione e' fallita, e l'utente proverebbe di nuovo senza sapere perche'.
      expect(c.read(groupsListProvider).value!.first.myRole, GroupRole.owner);
    });

    test('gli altri gruppi non vengono toccati', () async {
      repo = FakeGroupsRepository(initial: [
        buildGroup(id: 'g1', role: GroupRole.owner),
        buildGroup(id: 'g2', name: 'Stanza uno', role: GroupRole.member),
      ]);
      final c = container();
      await c.read(groupsListProvider.future);

      await c
          .read(groupsListProvider.notifier)
          .transferOwnership(groupId: 'g1', newOwnerId: 'u2');

      expect(c.read(groupsListProvider).value![1].myRole, GroupRole.member);
    });
  });

  group('selettore del nuovo owner', () {
    late FakeGroupsRepository repo;

    Future<void> pumpDetail(WidgetTester tester, FakeGroupsRepository r) async {
      final router = GoRouter(
        initialLocation: '/groups/g1',
        routes: [
          GoRoute(path: '/groups/g1', builder: (_, _) => const GroupDetailScreen(groupId: 'g1')),
          GoRoute(path: '/groups', builder: (_, _) => const SizedBox.shrink()),
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

      // I controlli del gruppo stanno in fondo alla lista: senza scorrere il
      // pulsante di cessione non verrebbe costruito.
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
    }

    setUp(() => repo = FakeGroupsRepository(initial: [buildGroup(role: GroupRole.owner)]));

    testWidgets('scegliere un membro chiede la cessione', (tester) async {
      repo.members = [
        GroupMember(
          userId: 'me',
          username: 'me_stesso',
          role: GroupRole.owner,
          joinedAt: DateTime(2026),
        ),
        GroupMember(
          userId: 'u2',
          username: 'asuka',
          role: GroupRole.member,
          joinedAt: DateTime(2026),
        ),
      ];
      await pumpDetail(tester, repo);

      await tester.tap(find.text('Cedi la proprieta'));
      await tester.pumpAndSettle();

      // L'owner attuale non va offerto: il backend lo rifiuterebbe.
      expect(find.text('me_stesso'), findsNothing);
      expect(find.text('asuka'), findsOneWidget);

      await tester.tap(find.text('asuka'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cedi'));
      await tester.pumpAndSettle();

      expect(repo.transfers, ['g1|u2']);
    });

    testWidgets('un gruppo con un solo membro spiega che non c e nessuno', (tester) async {
      repo.members = [
        GroupMember(
          userId: 'me',
          username: 'me_stesso',
          role: GroupRole.owner,
          joinedAt: DateTime(2026),
        ),
      ];
      await pumpDetail(tester, repo);

      await tester.tap(find.text('Cedi la proprieta'));
      await tester.pumpAndSettle();

      expect(find.textContaining("unico membro"), findsOneWidget);
      expect(repo.transferCalls, 0);
    });

    testWidgets('un errore nel caricare i membri offre il retry', (tester) async {
      repo.membersFailure = const GroupsFailure('Membri non disponibili.');
      await pumpDetail(tester, repo);

      await tester.tap(find.text('Cedi la proprieta'));
      await tester.pumpAndSettle();

      expect(find.text('Membri non disponibili.'), findsOneWidget);

      repo.membersFailure = null;
      await tester.tap(find.text('Riprova'));
      await tester.pumpAndSettle();

      expect(find.text('asuka'), findsOneWidget);
    });

    testWidgets('annullare la conferma non cambia nulla', (tester) async {
      await pumpDetail(tester, repo);

      await tester.tap(find.text('Cedi la proprieta'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('asuka'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Annulla'));
      await tester.pumpAndSettle();

      // Una conferma annullata non deve arrivare al backend: l'owner deve
      // restare tale finche' non lo decide.
      expect(repo.transferCalls, 0);
      expect(find.textContaining('Sei l owner'), findsOneWidget);
    });
  });
}