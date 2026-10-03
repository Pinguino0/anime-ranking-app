import 'package:animerank/core/error/app_failure.dart';
import 'package:animerank/features/groups/domain/group.dart';
import 'package:animerank/features/groups/presentation/groups_controller.dart';
import 'package:animerank/features/groups/presentation/screens/group_members_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_groups.dart';

void main() {
  late FakeGroupsRepository repo;

  setUp(() => repo = FakeGroupsRepository());

  /// Monta l'elenco membri di un gruppo di cui l'utente ha [role].
  ///
  /// Il ruolo arriva dalla lista gruppi, non da una richiesta per la schermata,
  /// quindi il finto va inizializzato con un gruppo che abbia quel ruolo: senza
  /// la schermata non saprebbe chi e' l'utente e mostrerebbe la lista senza
  /// azioni, facendo passare per giusto un test che in realta' e' rotto.
  Future<void> pumpMembers(
    WidgetTester tester, {
    GroupRole role = GroupRole.owner,
    List<GroupMember>? members,
  }) async {
    if (members != null) repo.members = members;

    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    repo.groups.add(buildGroup(role: role));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [groupsRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: GroupMembersScreen(groupId: 'g1')),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Membro di comodo.
  GroupMember member(
    String id, {
    GroupRole role = GroupRole.member,
    String? username,
  }) => GroupMember(
    userId: id,
    username: username ?? id,
    role: role,
    joinedAt: DateTime(2026, 1, 1),
  );

  /// Apre il menu azioni del membro [userId].
  Future<void> openMenu(WidgetTester tester, String userId) async {
    await tester.tap(find.byKey(ValueKey('azioni-$userId')));
    await tester.pumpAndSettle();
  }

  group('elenco', () {
    testWidgets('mostra i membri con il loro ruolo', (tester) async {
      await pumpMembers(
        tester,
        members: [
          member('u1', role: GroupRole.owner, username: 'rei'),
          member('u2'),
        ],
      );

      expect(find.text('rei'), findsOneWidget);
      expect(find.text('u2'), findsOneWidget);
      // I ruoli sono sotto ai nomi: senza il ruolo la lista dice solo chi c'e',
      // che e' la meta' del lavoro dell'owner.
      expect(find.text('Owner'), findsOneWidget);
      expect(find.text('Membro'), findsOneWidget);
      expect(find.text('2 membri'), findsOneWidget);
    });

    testWidgets('senza membri dice che il gruppo e vuoto', (tester) async {
      await pumpMembers(tester, members: []);

      expect(find.text('Il gruppo non ha ancora membri.'), findsOneWidget);
      // Senza dati non c'e' niente da riprovare: un bottone "Riprova" qui
      // riporterebbe a una lista che il server ha gia' detto essere vuota.
      expect(find.text('Riprova'), findsNothing);
    });

    testWidgets('un errore mostra il messaggio e permette di riprovare', (
      tester,
    ) async {
      repo.membersFailure = const GroupsFailure('Membri non disponibili.');
      await pumpMembers(tester);

      expect(find.text('Membri non disponibili.'), findsOneWidget);
      expect(find.text('Riprova'), findsOneWidget);
    });
  });

  group('azioni', () {
    testWidgets("l'owner vede cambio ruolo ed espulsione su un membro", (
      tester,
    ) async {
      await pumpMembers(tester, members: [member('u2')]);

      await openMenu(tester, 'u2');

      expect(find.text('Rendi admin'), findsOneWidget);
      expect(find.text('Espelli'), findsOneWidget);
      // "Rendi membro" non compare su un membro gia' membro: proporlo sarebbe
      // un'azione che non cambia niente e il backend la lascerebbe passare
      // come se fosse stata utile.
      expect(find.text('Rendi membro'), findsNothing);
    });

    testWidgets("l'owner non ha azioni sull'owner stesso", (tester) async {
      await pumpMembers(tester, members: [member('u1', role: GroupRole.owner)]);

      // `set_member_role` rifiuta il ruolo owner e `kick_member` non puo'
      // colpire il proprietario: offrire il menu significherebbe mostrare due
      // azioni che il server respinge.
      expect(find.byKey(const ValueKey('azioni-u1')), findsNothing);
    });

    testWidgets("l'admin puo' espellere ma non cambiare i ruoli", (
      tester,
    ) async {
      await pumpMembers(tester, role: GroupRole.admin, members: [member('u2')]);

      await openMenu(tester, 'u2');

      expect(find.text('Espelli'), findsOneWidget);
      expect(find.text('Rendi admin'), findsNothing);
      expect(find.text('Rendi membro'), findsNothing);
    });

    testWidgets('un membro semplice non ha azioni', (tester) async {
      await pumpMembers(
        tester,
        role: GroupRole.member,
        members: [member('u2')],
      );

      expect(find.byKey(const ValueKey('azioni-u2')), findsNothing);
    });

    testWidgets('un admin non ha azioni sull owner', (tester) async {
      await pumpMembers(
        tester,
        role: GroupRole.admin,
        members: [member('u1', role: GroupRole.owner)],
      );

      expect(find.byKey(const ValueKey('azioni-u1')), findsNothing);
    });
  });

  group('cambio ruolo', () {
    testWidgets('promuove ad admin e aggiorna l etichetta', (tester) async {
      await pumpMembers(tester, members: [member('u2', username: 'asuka')]);

      await openMenu(tester, 'u2');
      await tester.tap(find.text('Rendi admin'));
      await tester.pumpAndSettle();

      expect(repo.setRoleCalls, 1);
      expect(repo.roleChanges, ['u2|admin']);
      // L'etichetta cambia subito: e' il dato che l'utente sta guardando, e se
      // aspettasse il reload sembrerebbe che il comando non sia arrivato.
      expect(find.text('asuka'), findsOneWidget);
      expect(find.text('Admin'), findsOneWidget);
      expect(find.text('asuka ora e\' admin.'), findsOneWidget);
    });

    testWidgets('declassa un admin', (tester) async {
      await pumpMembers(
        tester,
        members: [member('u2', role: GroupRole.admin, username: 'rei')],
      );

      await openMenu(tester, 'u2');
      expect(find.text('Rendi admin'), findsNothing);
      expect(find.text('Rendi membro'), findsOneWidget);

      await tester.tap(find.text('Rendi membro'));
      await tester.pumpAndSettle();

      expect(repo.roleChanges, ['u2|member']);
      expect(find.text('Membro'), findsOneWidget);
    });

    testWidgets('un rifiuto del server lascia il ruolo com era', (
      tester,
    ) async {
      repo.setRoleFailure = const GroupsFailure(
        'Solo il owner puo cambiare i ruoli',
      );
      await pumpMembers(tester, members: [member('u2')]);

      await openMenu(tester, 'u2');
      await tester.tap(find.text('Rendi admin'));
      await tester.pumpAndSettle();

      expect(find.text('Solo il owner puo cambiare i ruoli'), findsOneWidget);
      // Il ruolo non viene promosso: l'aggiornamento locale avviene solo dopo
      // che il backend ha confermato.
      expect(find.text('Membro'), findsOneWidget);
    });
  });

  group('espulsione', () {
    testWidgets('chiede conferma prima di espellere', (tester) async {
      await pumpMembers(tester, members: [member('u2', username: 'asuka')]);

      await openMenu(tester, 'u2');
      await tester.tap(find.text('Espelli'));
      await tester.pumpAndSettle();

      expect(find.text('Espellere asuka?'), findsOneWidget);
      // La conferma e' gia' aperta ma nessuno e' stato espulso: espellere non
      // si annulla e senza conferma il tap su una voce di menu sbaglierebbe.
      expect(repo.kickCalls, 0);
      expect(find.text('asuka'), findsOneWidget);
    });

    testWidgets('annullare non espelle nessuno', (tester) async {
      await pumpMembers(tester, members: [member('u2')]);

      await openMenu(tester, 'u2');
      await tester.tap(find.text('Espelli'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Annulla'));
      await tester.pumpAndSettle();

      expect(repo.kickCalls, 0);
      expect(find.text('u2'), findsOneWidget);
    });

    testWidgets('confermando espelle e toglie il membro', (tester) async {
      await pumpMembers(
        tester,
        members: [
          member('u2', username: 'asuka'),
          member('u3'),
        ],
      );

      await openMenu(tester, 'u2');
      await tester.tap(find.text('Espelli'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Espelli'));
      await tester.pumpAndSettle();

      expect(repo.kickCalls, 1);
      expect(repo.kicked, ['g1|u2']);
      expect(find.text('asuka'), findsNothing);
      expect(find.text('u3'), findsOneWidget);
      expect(find.text('asuka non fa piu\' parte del gruppo.'), findsOneWidget);
      expect(find.text('1 membro'), findsOneWidget);
    });
  });
}
