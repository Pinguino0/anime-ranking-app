import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/router/app_router.dart';
import '../../domain/group.dart';
import '../groups_controller.dart';
import 'group_invites_section.dart';

/// Dettaglio di un gruppo: codice invito e amministrazione.
///
/// Il gruppo si legge dalla lista gia' caricata invece di chiedere di nuovo il
/// server: evita una seconda richiesta a ogni apertura e fa funzionare la
/// schermata anche con la rete lenta. Se il gruppo non e' in lista significa
/// che non si e' membri, e questo si dice subito.
class GroupDetailScreen extends ConsumerWidget {
  const GroupDetailScreen({required this.groupId, super.key});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(groupsListProvider).value ?? const <AnimeGroup>[];
    final matches = groups.where((g) => g.id == groupId).toList();

    if (groups.isEmpty && ref.watch(groupsListProvider).isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (matches.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Gruppo')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Non sei membro di questo gruppo.',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                FilledButton.tonal(
                  onPressed: () => context.go('/groups'),
                  child: const Text('Torna ai miei gruppi'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return _Detail(group: matches.first);
  }
}

class _Detail extends ConsumerStatefulWidget {
  const _Detail({required this.group});

  final AnimeGroup group;

  @override
  ConsumerState<_Detail> createState() => _DetailState();
}

class _DetailState extends ConsumerState<_Detail> {
  bool _busy = false;

  Future<void> _regenerate() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rigenerare il codice?'),
        content: const Text(
          'Il codice attuale smettera di funzionare. Chi lo aveva gia ricevuto '
          'dovra chiedere il nuovo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Rigenera'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      if (mounted) setState(() => _busy = false);
      return;
    }

    try {
      final code = await ref
          .read(groupsListProvider.notifier)
          .regenerateInviteCode(widget.group.id);
      messenger.showSnackBar(SnackBar(content: Text('Nuovo codice: $code')));
    } on GroupsFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _transfer() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);

    // La conferma sta dentro il foglio e non dopo: due passaggi separati
    // (scegli, poi conferma in una schermata diversa) farebbero comparire il
    // dialogo sopra un foglio gia' chiuso, e l'utente non vedrebbe piu' a chi
    // sta cedendo la proprieta'.
    final newOwner = await showModalBottomSheet<GroupMember>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _NewOwnerSheet(
        groupId: widget.group.id,
        onConfirm: (member) async {
          final confirmed = await showDialog<bool>(
            context: sheetContext,
            builder: (context) => AlertDialog(
              title: const Text('Cedere la proprieta?'),
              content: Text(
                '${member.label} diventa owner. Tu resti nel gruppo come admin: '
                'continui a poter amministrarlo, ma non a eliminarlo ne a cedere '
                'la proprieta\' altrove.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Annulla'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Cedi'),
                ),
              ],
            ),
          );

          // Il foglio resta aperto se l'utente annulla: annullare una conferma
          // non significa "torna indietro di due schermate".
          return confirmed == true;
        },
      ),
    );

    if (!mounted || newOwner == null) {
      if (mounted) setState(() => _busy = false);
      return;
    }

    try {
      await ref
          .read(groupsListProvider.notifier)
          .transferOwnership(
            groupId: widget.group.id,
            newOwnerId: newOwner.userId,
          );
      messenger.showSnackBar(
        SnackBar(content: Text('Proprieta passata a ${newOwner.label}.')),
      );
    } on GroupsFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Uscire dal gruppo?'),
        content: const Text(
          'I tuoi voti e la tua watchlist nel gruppo verranno rimossi. '
          'Rientrare richiedera un nuovo codice invito.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Esci'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ref.read(groupsListProvider.notifier).leave(widget.group.id);
      if (mounted) context.go('/groups');
    } on GroupsFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final group = widget.group;

    return Scaffold(
      appBar: AppBar(title: Text(group.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (group.description?.isNotEmpty == true) ...[
            Text(group.description!, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 24),
          ],

          // Le tre sezioni stanno in cima perche' sono quello che si va a
          // vedere nel gruppo: sotto il codice invito e il ruolo, che sono
          // informazioni di amministrazione, l'utente dovrebbe scorrerle per
          // trovarle.
          _LinkCard(
            icon: Icons.leaderboard_outlined,
            title: 'Classifica',
            subtitle: 'I titoli piu amati dal gruppo e le tue posizioni.',
            onTap: () =>
                context.push(AppRoutes.ranking(group.id), extra: group.name),
          ),
          const SizedBox(height: 12),
          _LinkCard(
            icon: Icons.compare_arrows,
            title: 'Duelli',
            subtitle: 'Metti in gara due anime e guarda chi vince.',
            onTap: () =>
                context.push(AppRoutes.duels(group.id), extra: group.name),
          ),
          const SizedBox(height: 12),
          _LinkCard(
            icon: Icons.emoji_events_outlined,
            title: 'Tornei',
            subtitle:
                'Un tabellone a eliminazione diretta fra anime del gruppo.',
            onTap: () => context.push(
              AppRoutes.tournaments(group.id),
              extra: group.name,
            ),
          ),
          const SizedBox(height: 12),
          _LinkCard(
            icon: Icons.bookmark_border,
            title: 'Watchlist',
            subtitle: 'Gli anime che stai guardando e quelli da iniziare.',
            onTap: () =>
                context.push(AppRoutes.watchlist(group.id), extra: group.name),
          ),
          _LinkCard(
            icon: Icons.group_outlined,
            title: 'Membri',
            subtitle: 'Chi partecipa al gruppo e i suoi ruoli.',
            onTap: () => context.push(AppRoutes.groupMembers(group.id)),
          ),
          const SizedBox(height: 24),

          if (group.canSeeInviteCode) ...[
            _InviteCard(
              code: group.inviteCode,
              busy: _busy,
              onRegenerate: _regenerate,
            ),
            const SizedBox(height: 24),

            // Gli inviti singoli stanno sotto il codice del gruppo, non
            // accanto: il codice e' l'accesso permanente del gruppo, gli inviti
            // sono accessi singoli che scadono. In questo ordine l'utente
            // arriva al caso comune per primo e trova il caso particolare
            // sotto, senza dover scegliere quale delle due cose cercare.
            GroupInvitesSection(groupId: group.id),
            const SizedBox(height: 24),
          ],

          Text('Il tuo ruolo', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(
            group.myRole.label,
            style: theme.textTheme.titleMedium?.copyWith(
              color: group.myRole.canManage
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            switch (group.myRole) {
              GroupRole.owner =>
                'Puoi amministrare il gruppo e gestire i ruoli.',
              GroupRole.admin =>
                'Puoi amministrare il gruppo ed espellere i membri.',
              GroupRole.member =>
                'Puoi votare e commentare. Chiedi a un admin per altro.',
            },
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),

          const SizedBox(height: 32),
          if (!group.isOwner)
            OutlinedButton.icon(
              onPressed: _busy ? null : _leave,
              icon: const Icon(Icons.logout),
              label: const Text('Esci dal gruppo'),
            )
          else ...[
            OutlinedButton.icon(
              onPressed: _busy ? null : _transfer,
              icon: const Icon(Icons.swap_horiz),
              label: const Text('Cedi la proprieta'),
            ),
            const SizedBox(height: 12),
            Text(
              'Sei l owner: per lasciare il gruppo devi prima cedere la '
              'proprieta\' o eliminarlo.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Foglio di scelta del nuovo owner.
///
/// I membri sono gia' ordinati dal backend (owner in cima, poi admin, poi per
/// data di ingresso), quindi la lista li mostra nell'ordine in cui arrivano:
/// riordinare qui significherebbe due regole diverse per lo stesso dato.
///
/// L'owner attuale non e' selezionabile perche' il backend rifiuta di cedere
/// la proprieta' a se' stessi: proporlo come scelta significa proporre un
/// errore.
class _NewOwnerSheet extends ConsumerWidget {
  const _NewOwnerSheet({required this.groupId, required this.onConfirm});

  final String groupId;

  /// Chiede conferma e restituisce true solo se l'utente ha detto di si'.
  final Future<bool> Function(GroupMember member) onConfirm;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(groupMembersProvider(groupId));

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          height: 420,
          child: members.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$error', textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: () =>
                          ref.invalidate(groupMembersProvider(groupId)),
                      child: const Text('Riprova'),
                    ),
                  ],
                ),
              ),
            ),
            data: (rows) {
              final candidates = [
                for (final m in rows)
                  if (m.canReceiveOwnership) m,
              ];

              if (candidates.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Sei l unico membro: non c\'e nessuno a cui cedere la '
                      'proprieta\'.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Cedi la proprieta\' a',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Chi scegli diventa owner e puo\' eliminare il gruppo.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView.builder(
                      itemCount: candidates.length,
                      itemBuilder: (context, i) {
                        final member = candidates[i];

                        return ListTile(
                          leading: member.avatarUrl == null
                              ? CircleAvatar(child: Text(_initial(member)))
                              : CircleAvatar(
                                  backgroundImage: NetworkImage(
                                    member.avatarUrl!,
                                  ),
                                ),
                          title: Text(member.label),
                          subtitle: Text(member.role.label),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () async {
                            if (await onConfirm(member)) {
                              if (context.mounted) {
                                Navigator.of(context).pop(member);
                              }
                            }
                          },
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Prima lettera del nome, per l'avatar di fallback.
  ///
  /// Con stringa vuota restituirebbe un char vuoto e l'avatar sembrerebbe
  /// rotto; qui si lascia il segnaposto dell'icona.
  String _initial(GroupMember member) {
    final label = member.label.trim();
    return label.isEmpty ? '?' : label[0].toUpperCase();
  }
}

/// Scheda che apre una sezione del gruppo.
///
/// Comune a classifica e watchlist: le due hanno lo stesso aspetto e la sola
/// differenza e' la destinazione, quindi due copie significherebbero che un
/// ritocco al suono del tocco o al padding ne lascerebbe sempre una indietro.
class _LinkCard extends StatelessWidget {
  const _LinkCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, color: theme.colorScheme.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

/// Scheda con il codice invito, copiabile con un tocco.
class _InviteCard extends StatelessWidget {
  const _InviteCard({
    required this.code,
    required this.busy,
    required this.onRegenerate,
  });

  final String code;
  final bool busy;
  final Future<void> Function() onRegenerate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Codice invito', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            // Monospaziato e spaziato fra i caratteri: il codice va letto ad
            // alta voce o digitato a mano, e O/0 e I/1 si confondono in un
            // font proporzionale.
            Text(
              code,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontFamily: 'monospace',
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: code.isEmpty ? null : () => _copy(context),
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copia'),
                ),
                TextButton.icon(
                  onPressed: busy ? null : onRegenerate,
                  icon: const Icon(Icons.autorenew, size: 18),
                  label: const Text('Rigenera'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: code));

    // Conferma esplicita: senza, l'utente non ha modo di sapere se il
    // copia-in-clipboard e andato, e potrebbe ripeterlo o incollare il vecchio.
    messenger.showSnackBar(const SnackBar(content: Text('Codice copiato.')));
  }
}
