import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/breakpoints.dart';
import '../../../../core/error/app_failure.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/content_row.dart';
import '../../../../core/ui/section_header.dart';
import '../../../../core/ui/transitions.dart';
import '../../../profile/presentation/widgets/avatar.dart';
import '../../domain/group.dart';
import '../groups_controller.dart';
// La pastiglia del ruolo e' quella dell'elenco gruppi: stesso ruolo, stesso
// disegno, altrimenti lo stesso admin avrebbe due colori a seconda della
// schermata da cui lo si guarda.
import 'groups_list_screen.dart';

/// Elenco dei membri di un gruppo, con le azioni che il ruolo permette.
///
/// Le azioni non sono offerte a tutti e poi lasciate fallire dal server: sono
/// mostrate solo dove il backend le accetterebbe. `set_member_role` e' del solo
/// owner e rifiuta il ruolo `owner` (per cedere la proprieta' c'e'
/// `transfer_group_ownership`), `kick_member` e' di admin e owner ma non puo
/// colpire l'owner. Offrire un'azione che il server rifiuta fa sembrare
/// rotta l'app invece che bloccata.
///
/// Sotto i 900px e' una lista di righe, da [LayoutSize.expanded] in su una
/// tabella: a quella larghezza una riga per persona lascerebbe il ruolo e la
/// data in due parole isolate a sinistra e il resto dello schermo vuoto, e
/// le colonne affiancate si leggono come una tabella senza dirlo.
class GroupMembersScreen extends ConsumerWidget {
  const GroupMembersScreen({required this.groupId, super.key});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final members = ref.watch(groupMembersProvider(groupId));

    // Il ruolo arriva dalla lista gruppi gia' caricata e non da una richiesta
    // nuova: il dettaglio gruppo funziona gia' cosi', e rifare qui la stessa
    // domanda mostrerebbe due volte lo stesso dato con due stati di caricamento
    // che possono divergere.
    final groups = ref.watch(groupsListProvider).value ?? const <AnimeGroup>[];
    final group = groups.where((g) => g.id == groupId).firstOrNull;
    final myRole = group?.myRole ?? GroupRole.member;

    return Scaffold(
      appBar: AppBar(title: const Text('Membri')),
      body: members.when(
        loading: () => const _MembersSkeleton(),
        // Errore e lista vuota non hanno niente in comune e non possono
        // condividere la stessa vista: un errore finisce da solo, una lista
        // vuota no — e li mostrare uguali lascerebbe senza via d'uscita
        // l'utente che ha davvero un problema di rete.
        error: (error, _) => ErrorState(
          message: error is GroupsFailure
              ? error.message
              : 'Membri non disponibili.',
          onRetry: () => ref.invalidate(groupMembersProvider(groupId)),
          icon: Icons.group_off_outlined,
        ),
        data: (rows) {
          if (rows.isEmpty) {
            // Nessun pulsante "Riprova": il server ha gia' detto che la lista e'
            // vuota, e ripetere la richiesta restituirebbe la stessa risposta.
            return const EmptyState(
              icon: Icons.group_outlined,
              title: 'Nessun membro',
              message: 'Il gruppo non ha ancora membri.',
            );
          }

          // Le due azioni hanno regole diverse e non si possono semplificare
          // in un solo flag: un admin puo' espellere ma non cambiare i ruoli,
          // quindi un unico `canManage` offrirebbe a tutti l'azione che il
          // backend rifiuta.
          bool canChange(GroupMember m) =>
              myRole.canAssignRoles && m.role != GroupRole.owner;
          bool canKick(GroupMember m) =>
              myRole.canManage && m.role != GroupRole.owner;

          return LayoutSize.expanded == Breakpoints.fromContext(context)
              ? _MembersTable(
                  members: rows,
                  onAction: (action, member) =>
                      _run(context, ref, action, member),
                  canChangeRole: canChange,
                  canKick: canKick,
                )
              : _MembersList(
                  members: rows,
                  onAction: (action, member) =>
                      _run(context, ref, action, member),
                  canChangeRole: canChange,
                  canKick: canKick,
                );
        },
      ),
      // La lista non ha bisogno del ruolo per disegnarsi: l'intestazione dice
      // solo quanti membri sono, dato che arriva con loro.
      bottomNavigationBar: members.value == null || members.value!.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.all(ArSpace.md),
              child: Text(
                '${members.value!.length} ${members.value!.length == 1 ? 'membro' : 'membri'}',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
    );
  }

  /// Esegue un'azione e mostra l'esito.
  ///
  /// Il refresh dopo l'azione serve a riallineare la lista con il server:
  /// l'aggiornamento locale del controller e' un aiuto immediato, ma la
  /// verita' sul ruolo applicato ce l'ha solo il backend.
  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    _MemberAction action,
    GroupMember member,
  ) async {
    final messenger = ScaffoldMessenger.of(context);

    try {
      final notifier = ref.read(groupMembersProvider(groupId).notifier);

      switch (action) {
        case _MemberAction.makeAdmin:
          await notifier.setRole(userId: member.userId, role: GroupRole.admin);
        case _MemberAction.makeMember:
          await notifier.setRole(userId: member.userId, role: GroupRole.member);
        case _MemberAction.kick:
          if (!await _confirmKick(context, member)) return;
          await notifier.kick(member.userId);
      }

      await notifier.refresh();
      messenger.showSnackBar(
        SnackBar(content: Text(_doneMessage(action, member))),
      );
    } on GroupsFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// Messaggio di conferma per l'azione riuscita.
  String _doneMessage(_MemberAction action, GroupMember member) =>
      switch (action) {
        _MemberAction.makeAdmin => '${member.label} ora e\' admin.',
        _MemberAction.makeMember => '${member.label} ora e\' membro.',
        _MemberAction.kick => '${member.label} non fa piu\' parte del gruppo.',
      };

  /// Chiede conferma prima di espellere.
  ///
  /// Espellere non si puo' annullare e la persona espulsa non riceve avviso
  /// nell'app, quindi serve una conferma esplicita: il tap su una voce di menu
  /// e' veloce e un errore si vedrebbe solo in un gruppo affollato.
  Future<bool> _confirmKick(BuildContext context, GroupMember member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Espellere ${member.label}?'),
        content: const Text(
          'Perdera\' accesso al gruppo. Potra\' rientrare solo con un nuovo '
          'codice invito.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Espelli'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }
}

/// Azioni disponibili su un membro.
enum _MemberAction { makeAdmin, makeMember, kick }

/// Elenco dei membri come lista di righe.
///
/// Sotto i 900px: una tabella a quella larghezza taglierebbe le colonne e
/// costringerebbe a scorrere di lato per leggere il ruolo di una riga.
class _MembersList extends StatelessWidget {
  const _MembersList({
    required this.members,
    required this.onAction,
    required this.canChangeRole,
    required this.canKick,
  });

  final List<GroupMember> members;
  final void Function(_MemberAction, GroupMember) onAction;
  final bool Function(GroupMember) canChangeRole;
  final bool Function(GroupMember) canKick;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: ArSpace.page(context).copyWith(top: ArSpace.sm),
      itemCount: members.length,
      itemBuilder: (context, i) {
        final member = members[i];

        return ArReveal(
          // L'ingresso a ondate dice "sono stati caricati": le righe senza
          // animazione arriverebbero insieme e sembrerebbero disegnate a caso.
          // Il ritardo si ferma a 240ms perche' oltre l'ultima riga
          // aspetterebbe senza che l'occhio capisse perche'.
          delayMs: (i * 45).clamp(0, 240),
          child: _MemberTile(
            member: member,
            canChangeRole: canChangeRole(member),
            canKick: canKick(member),
            onAction: (action) => onAction(action, member),
          ),
        );
      },
    );
  }
}

/// Elenco dei membri come tabella.
///
/// Da [LayoutSize.expanded] in su: le colonne sono quello che distingue un
/// elenco di persone da un elenco di azioni, e su schermo largo una riga per
/// persona lascerebbe due terzi del viewport vuoti.
class _MembersTable extends StatelessWidget {
  const _MembersTable({
    required this.members,
    required this.onAction,
    required this.canChangeRole,
    required this.canKick,
  });

  final List<GroupMember> members;
  final void Function(_MemberAction, GroupMember) onAction;
  final bool Function(GroupMember) canChangeRole;
  final bool Function(GroupMember) canKick;

  /// Data breve: giorno, mese e anno.
  ///
  /// Il giorno e il mese non si possono scambiare fra loro in italiano senza
  /// l'anno, e in un gruppo la data d'ingresso serve proprio per distinguere
  /// chi c'era gia' da chi si e' aggiunto dopo.
  static String _date(DateTime value) =>
      '${value.day.toString().padLeft(2, '0')}/'
      '${value.month.toString().padLeft(2, '0')}/${value.year}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: ArSpace.page(context).copyWith(top: ArSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: 'Membri del gruppo',
            subtitle: '${members.length} '
                '${members.length == 1 ? 'persona' : 'persone'}',
          ),
          const SizedBox(height: ArSpace.sm),
          Card(
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 44,
                dataRowMinHeight: 56,
                dataRowMaxHeight: 72,
                // Il tratteggio e' sottile ma presente: senza, alla larghezza di
                // una tabella le righe si leggono come un blocco unico e si
                // perde il conteggio delle persone.
                dividerThickness: 1,
                columns: const [
                  DataColumn(label: Text('Membro')),
                  DataColumn(label: Text('Ruolo')),
                  DataColumn(label: Text('Ingresso')),
                  DataColumn(label: Text('')),
                ],
                rows: [
                  for (final member in members)
                    DataRow(
                      cells: [
                        DataCell(
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ProfileAvatar(
                                url: member.avatarUrl,
                                fallbackText: avatarInitial(member.label),
                                size: 32,
                              ),
                              const SizedBox(width: ArSpace.sm),
                              Text(member.label),
                            ],
                          ),
                        ),
                        DataCell(GroupRoleBadge(role: member.role)),
                        DataCell(
                          Text(
                            _date(member.joinedAt),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        DataCell(
                          Align(
                            alignment: Alignment.centerRight,
                            child: _MemberMenu(
                              member: member,
                              canChangeRole: canChangeRole(member),
                              canKick: canKick(member),
                              onAction: (action) => onAction(action, member),
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Riga di un membro con le sue azioni.
class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.member,
    required this.canChangeRole,
    required this.canKick,
    required this.onAction,
  });

  final GroupMember member;
  final bool canChangeRole;
  final bool canKick;
  final ValueChanged<_MemberAction> onAction;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      // Il padding laterale lo mette la riga e non la ListView: quella aggiunge
      // solo quello verticale, quindi senza questo l'avatar tocca il bordo dello
      // schermo e sembra tagliato.
      contentPadding: const EdgeInsets.symmetric(horizontal: ArSpace.md),
      // `ProfileAvatar` e non `CircleAvatar` con `NetworkImage`: senza
      // `errorBuilder` un URL avatar rotto mostrerebbe il riquadro grigio di
      // Flutter, mentre questo cade sull'iniziale, che dice comunque di chi si
      // tratta.
      leading: ProfileAvatar(
        url: member.avatarUrl,
        fallbackText: avatarInitial(member.label),
        size: 40,
      ),
      title: Text(member.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      // Sotto al nome c'e' la pastiglia del ruolo e non la sua etichetta come
      // testo semplice: e' lo stesso elemento dell'elenco gruppi, e una riga in
      // cui il ruolo e' una parola e la scheda in cui e' una pastiglia fa
      // sembrare che i due ruoli diversi siano due cose diverse.
      subtitle: Align(
        alignment: Alignment.centerLeft,
        child: GroupRoleBadge(role: member.role),
      ),
      trailing: _MemberMenu(
        member: member,
        canChangeRole: canChangeRole,
        canKick: canKick,
        onAction: onAction,
      ),
    );
  }
}

/// Menu delle azioni su un membro.
///
/// Vive in una classe perche' lo usano sia la lista sia la tabella: le voci e
/// le loro condizioni sono le stesse, e due copie finirebbero per mostrare
/// azioni diverse alla stessa persona.
class _MemberMenu extends StatelessWidget {
  const _MemberMenu({
    required this.member,
    required this.canChangeRole,
    required this.canKick,
    required this.onAction,
  });

  final GroupMember member;
  final bool canChangeRole;
  final bool canKick;
  final ValueChanged<_MemberAction> onAction;

  @override
  Widget build(BuildContext context) {
    // Nessun controllo quando non c'e' niente da fare: un bottone grigio che
    // non apre nulla e' peggio della sua assenza, perche' sembra un bug.
    if (!canChangeRole && !canKick) return const SizedBox.shrink();

    return PopupMenuButton<_MemberAction>(
      // Il ruolo non cambia il menu: cambia il numero di voci, e senza chiave
      // Flutter riuserebbe a riordinare le voci aperte in precedenza.
      key: ValueKey('azioni-${member.userId}'),
      onSelected: onAction,
      tooltip: 'Azioni su ${member.label}',
      itemBuilder: (context) => [
        if (canChangeRole && member.role != GroupRole.admin)
          const PopupMenuItem(
            value: _MemberAction.makeAdmin,
            child: Text('Rendi admin'),
          ),
        if (canChangeRole && member.role != GroupRole.member)
          const PopupMenuItem(
            value: _MemberAction.makeMember,
            child: Text('Rendi membro'),
          ),
        if (canKick)
          const PopupMenuItem(
            value: _MemberAction.kick,
            child: Text('Espelli'),
          ),
      ],
    );
  }
}

/// Scheletro dell'elenco.
///
/// Stesse righe della lista reale: uno scheletro fatto di righe generiche
/// cambierebbe altezza al primo arrivo dei dati e la lista salterebbe sotto le
/// dita di chi stava gia' per premere.
class _MembersSkeleton extends StatelessWidget {
  const _MembersSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: ArSpace.page(context).copyWith(top: ArSpace.sm),
      itemCount: 6,
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.symmetric(vertical: ArSpace.sm),
        child: Row(
          children: [
            const SkeletonBox(height: 40, width: 40, radius: 40),
            const SizedBox(width: ArSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(width: 140 - i * 10, height: 14),
                  const SizedBox(height: ArSpace.xs),
                  const SkeletonBox(width: 52, height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}