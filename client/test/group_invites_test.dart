import 'package:animerank/core/error/app_failure.dart';
import 'package:animerank/features/groups/domain/group.dart';
import 'package:animerank/features/groups/presentation/groups_controller.dart';
import 'package:animerank/features/groups/presentation/screens/group_invites_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fake_groups.dart';

void main() {
  late FakeGroupsRepository repo;

  setUp(() => repo = FakeGroupsRepository());

  /// Monta la sezione inviti.
  Future<void> pumpInvites(
    WidgetTester tester, {
    List<GroupInvite>? invites,
  }) async {
    if (invites != null) repo.invites = invites;

    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [groupsRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(
          home: Scaffold(body: GroupInvitesSection(groupId: 'g1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Invito di comodo, valido e non ancora usato.
  GroupInvite invite({
    String id = 'inv1',
    String code = 'INV-0001',
    bool pending = true,
    DateTime? usedAt,
    DateTime? revokedAt,
  }) => GroupInvite(
    id: id,
    code: code,
    createdBy: 'me',
    expiresAt: DateTime.now().add(const Duration(days: 7)),
    createdAt: DateTime.now().subtract(const Duration(hours: 1)),
    usedAt: usedAt,
    revokedAt: revokedAt,
    pending: pending,
  );

  group('elenco', () {
    testWidgets('senza inviti dice che non ce ne sono', (tester) async {
      await pumpInvites(tester, invites: []);

      expect(find.text('Nessun invito attivo.'), findsOneWidget);
    });

    testWidgets('un invito valido mostra codice e scadenza', (tester) async {
      await pumpInvites(tester, invites: [invite()]);

      expect(find.text('INV-0001'), findsOneWidget);
      expect(find.textContaining('Valido fino al'), findsOneWidget);
    });

    testWidgets('un invito usato non si puo piu revocare', (tester) async {
      await pumpInvites(
        tester,
        invites: [
          invite(
            pending: false,
            usedAt: DateTime.now().subtract(const Duration(hours: 2)),
          ),
        ],
      );

      expect(find.text('Usato'), findsOneWidget);
      // Il backend rifiuta la revoca di un invito gia' usato: lasciare il
      // pulsante farebbe ogni tap un errore.
      expect(find.byTooltip('Revoca'), findsNothing);
      expect(find.byTooltip('Copia'), findsOneWidget);
    });

    testWidgets('un invito scaduto non si puo piu revocare', (tester) async {
      await pumpInvites(tester, invites: [invite(pending: false)]);

      expect(find.text('Scaduto'), findsOneWidget);
      expect(find.byTooltip('Revoca'), findsNothing);
    });

    testWidgets('un invito revocato resta in lista come revocato', (
      tester,
    ) async {
      await pumpInvites(
        tester,
        invites: [invite(pending: false, revokedAt: DateTime.now())],
      );

      expect(find.text('Revocato'), findsOneWidget);
      expect(find.byTooltip('Revoca'), findsNothing);
    });

    testWidgets('un errore offre il retry', (tester) async {
      repo.invitesFailure = const GroupsFailure('Permessi insufficienti.');
      await pumpInvites(tester);

      expect(find.text('Permessi insufficienti.'), findsOneWidget);
      expect(find.text('Riprova'), findsOneWidget);
    });
  });

  group('creazione', () {
    testWidgets('il dialogo sceglie i giorni proposti dal backend', (
      tester,
    ) async {
      await pumpInvites(tester, invites: []);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Crea'));
      await tester.pumpAndSettle();

      // Solo 1, 3, 7, 14, 30 giorni: sono gli unici che il backend accetta,
      // e un campo libero farebbe scoprire il limite solo dopo aver premuto.
      expect(find.text('1 g'), findsOneWidget);
      expect(find.text('30 g'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('crea con sette giorni per impostazione predefinita', (
      tester,
    ) async {
      await pumpInvites(tester, invites: []);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Crea'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Crea'));
      await tester.pumpAndSettle();

      expect(repo.createInviteCalls, 1);
      expect(repo.createdInvites, ['g1|7']);
      expect(repo.invitesCalls, greaterThanOrEqualTo(2));
    });

    testWidgets('scegliere i giorni li passa al backend', (tester) async {
      await pumpInvites(tester, invites: []);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Crea'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('14 g'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Crea'));
      await tester.pumpAndSettle();

      expect(repo.createdInvites, ['g1|14']);
    });

    testWidgets('annullare il dialogo non crea nulla', (tester) async {
      await pumpInvites(tester, invites: []);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Crea'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Annulla'));
      await tester.pumpAndSettle();

      expect(repo.createInviteCalls, 0);
    });

    testWidgets('un errore in creazione non aggiunge una riga falsa', (
      tester,
    ) async {
      repo.createInviteFailure = const GroupsFailure('Permessi insufficienti.');
      await pumpInvites(tester, invites: []);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Crea'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Crea'));
      await tester.pumpAndSettle();

      expect(find.text('Permessi insufficienti.'), findsOneWidget);
      expect(find.text('Nessun invito attivo.'), findsOneWidget);
    });
  });

  group('revoca', () {
    testWidgets('chiede conferma prima di revocare', (tester) async {
      await pumpInvites(tester, invites: [invite()]);

      await tester.tap(find.byTooltip('Revoca'));
      await tester.pumpAndSettle();

      expect(find.textContaining('INV-0001'), findsWidgets);
      expect(find.textContaining("smettera'"), findsOneWidget);
      expect(repo.revokeInviteCalls, 0);
    });

    testWidgets('annullare non revoca', (tester) async {
      await pumpInvites(tester, invites: [invite()]);

      await tester.tap(find.byTooltip('Revoca'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Annulla'));
      await tester.pumpAndSettle();

      expect(repo.revokeInviteCalls, 0);
      expect(find.textContaining('Valido fino al'), findsOneWidget);
    });

    testWidgets('confermando revoca e aggiorna lo stato', (tester) async {
      await pumpInvites(tester, invites: [invite()]);

      await tester.tap(find.byTooltip('Revoca'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Revoca'));
      await tester.pumpAndSettle();

      expect(repo.revokeInviteCalls, 1);
      expect(repo.revokedInvites, ['inv1']);
      expect(find.text('Revocato'), findsOneWidget);
      expect(find.text('Invito revocato.'), findsOneWidget);
    });

    testWidgets('un rifiuto del server lascia l invito attivo', (tester) async {
      repo.revokeInviteFailure = const GroupsFailure(
        'Questo invito e\' gia\' stato usato',
      );
      await pumpInvites(tester, invites: [invite()]);

      await tester.tap(find.byTooltip('Revoca'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Revoca'));
      await tester.pumpAndSettle();

      expect(find.text("Questo invito e' gia' stato usato"), findsOneWidget);
      // Il finto non ha cambiato nulla, quindi la riga resta valida: e'
      // quello che deve succedere se il backend ha rifiutato.
      expect(find.textContaining('Valido fino al'), findsOneWidget);
    });
  });
}
