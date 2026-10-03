import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/error/app_failure.dart';
import '../../domain/group.dart';
import '../groups_controller.dart';

/// Elenco dei membri di un gruppo, con le azioni che il ruolo permette.
///
/// Le azioni non sono offerte a tutti e poi lasciate fallire dal server: sono
/// mostrate solo dove il backend le accetterebbe. `set_member_role` e' del solo
/// owner e rifiuta il ruolo `owner` (per cedere la proprieta' c'e'
/// `transfer_group_ownership`), `kick_member` e' di admin e owner ma non puo
/// colpire l'owner. Offrire un'azione che il server rifiuta fa sembrare
/// rotta l'app invece che bloccata.
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
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorView(
          message: error is GroupsFailure
              ? error.message
              : 'Membri non disponibili.',
          onRetry: () => ref.invalidate(groupMembersProvider(groupId)),
        ),
        data: (rows) {
          if (rows.isEmpty) {
            return _ErrorView(
              message: 'Il gruppo non ha ancora membri.',
              onRetry: null,
              icon: Icons.group_outlined,
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final member = rows[i];

              return _MemberTile(
                member: member,
                // Le due azioni hanno regole diverse e non si possono
                // semplificare in un solo flag: un admin puo' espellere ma non
                // cambiare i ruoli, quindi un unico `canManage` offrirebbe a
                // tutti l'azione che il backend rifiuta.
                canChangeRole:
                    myRole.canAssignRoles && member.role != GroupRole.owner,
                canKick: myRole.canManage && member.role != GroupRole.owner,
                onAction: (action) => _run(context, ref, action, member),
              );
            },
          );
        },
      ),
      // La lista non ha bisogno del ruolo per disegnarsi: l'intestazione dice
      // solo quanti membri sono, dato che arriva con loro.
      bottomNavigationBar: members.value == null || members.value!.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.all(16),
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: member.avatarUrl == null
          ? CircleAvatar(child: Text(_initial(member)))
          : CircleAvatar(backgroundImage: NetworkImage(member.avatarUrl!)),
      title: Text(member.label),
      subtitle: Text(member.role.label),
      trailing: (canChangeRole || canKick)
          ? PopupMenuButton<_MemberAction>(
              // Il ruolo non cambia il menu: cambia il numero di voci, e senza
              // chiave Flutter riuserebbe a riordinare le voci aperte in precedenza.
              key: ValueKey('azioni-${member.userId}'),
              onSelected: onAction,
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
            )
          : null,
    );
  }

  /// Prima lettera del nome, per l'avatar di fallback.
  ///
  /// Con stringa vuota restituirebbe un carattere vuoto e l'avatar sembrerebbe
  /// rotto; qui si lascia il segnaposto.
  String _initial(GroupMember member) {
    final label = member.label.trim();
    return label.isEmpty ? '?' : label[0].toUpperCase();
  }
}

/// Stato di errore o lista vuota, con la stessa forma.
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry, this.icon});

  final String message;
  final VoidCallback? onRetry;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 40,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 12),
            ],
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: onRetry, child: const Text('Riprova')),
            ],
          ],
        ),
      ),
    );
  }
}
