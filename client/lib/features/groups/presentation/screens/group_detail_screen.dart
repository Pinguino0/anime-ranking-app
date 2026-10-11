import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/ar_badge.dart';
import '../../../../core/ui/code_text.dart';
import '../../../../core/ui/content_row.dart';
import '../../../../core/ui/section_header.dart';
import '../../../../core/ui/transitions.dart';
import '../../../profile/presentation/widgets/avatar.dart';
import '../../domain/group.dart';
import '../groups_controller.dart';
import 'group_invites_section.dart';
// `GroupRoleBadge` vive nella lista dei gruppi: il contrassegno del ruolo e'
// lo stesso in elenco e in dettaglio, e due copie finirebbero con colori
// diversi per lo stesso admin.
import 'groups_list_screen.dart';

/// Dettaglio di un gruppo: codice invito e amministrazione.
///
/// Il gruppo si legge dalla lista gia' caricata invece di chiedere di nuovo il
/// server: evita una seconda richiesta a ogni apertura e fa funzionare la
/// schermata anche con la rete lenta. Se il gruppo non e' in lista significa
/// che non si e' membri, e questo si dice subito — ma solo se la lista e'
/// arrivata davvero: quando la richiesta e' fallita la lista e' vuota anche se
/// l'utente e' membro, e dirgli "non sei membro" sarebbe un'affermazione
/// falsa su un errore di rete.
class GroupDetailScreen extends ConsumerWidget {
  const GroupDetailScreen({required this.groupId, super.key});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Un solo `watch`: la versione precedente ne faceva due, e la seconda
    // lettura poteva cadere su uno stato diverso della prima, cosi' la schermata
    // decideva cosa mostrare in base a dati che non avevano niente a che fare
    // fra loro.
    final state = ref.watch(groupsListProvider);
    final groups = state.value ?? const <AnimeGroup>[];
    final matches = groups.where((g) => g.id == groupId).toList();

    if (matches.isNotEmpty) return _Detail(group: matches.first);

    // Tre casi distinti e non uno solo "manca il gruppo": in caricamento non si
    // sa ancora, in errore si sa che il tentativo e' fallito, e solo nei dati
    // arrivati vuoti si puo' dire che non si e' membri.
    if (state.hasError) {
      return Scaffold(
        appBar: AppBar(title: const Text('Gruppo')),
        body: ErrorState(
          message: state.error is GroupsFailure
              ? (state.error! as GroupsFailure).message
              : 'Gruppo non disponibile.',
          onRetry: () => ref.read(groupsListProvider.notifier).refresh(),
        ),
      );
    }

    if (state.isLoading) {
      return const Scaffold(
        appBar: _DetailTitle(),
        body: _DetailSkeleton(),
      );
    }

    return Scaffold(
      appBar: const _DetailTitle(),
      body: EmptyState(
        icon: Icons.group_off_outlined,
        title: 'Non sei membro di questo gruppo.',
        message:
            'Puo\' succedere che il gruppo sia stato cancellato, che tu ne sia '
            'stato espulso, che il collegamento sia di un altro account.',
        action: FilledButton.icon(
          onPressed: () => context.go('/groups'),
          icon: const Icon(Icons.arrow_back, size: 19),
          label: const Text('Torna ai miei gruppi'),
        ),
      ),
    );
  }
}

/// Titolo dell'appbar.
///
/// Un campo `const` perche' la schermata lo usa identico nei tre casi di
/// caricamento, errore e assenza: scriverlo ogni volta significava tre copie
/// che potevano divergere nel titolo mentre la pagina restava identica.
class _DetailTitle extends StatelessWidget implements PreferredSizeWidget {
  const _DetailTitle();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) => AppBar(title: const Text('Gruppo'));
}

/// Scheletro del dettaglio.
///
/// Se stessa forma della pagina reale — cinque card, il codice, il ruolo — cosi'
/// all'arrivo dei dati niente salta da una parte all'altra dello schermo.
class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: ArSpace.page(context).copyWith(top: ArSpace.md, bottom: 0),
      children: [
        for (var i = 0; i < 5; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: ArSpace.sm),
            child: SkeletonBox(height: 74, radius: ArRadii.card),
          ),
        const SizedBox(height: ArSpace.lg),
        const SkeletonBox(height: 140, radius: ArRadii.card),
        const SizedBox(height: ArSpace.lg),
        const SkeletonBox(height: 70, radius: ArRadii.card),
      ],
    );
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

    final page = ArSpace.page(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(group.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: ListView(
        // Il padding in fondo e' il doppio del normale perche' l'ultimo
        // pulsante e' quello che lascia il gruppo: su uno schermo basso finiva
        // sotto la barra di navigazione e l'unica azione distruttiva della
        // pagina era quella che non si poteva premere.
        padding: page.copyWith(
          top: ArSpace.md,
          bottom: ArSpace.xxl * 2,
        ),
        children: [
          if (group.description?.isNotEmpty == true) ...[
            Text(group.description!, style: theme.textTheme.bodyLarge),
            const SizedBox(height: ArSpace.lg),
          ],

          // Le sezioni del gruppo stanno in cima perche' sono quello che si va
          // a vedere nel gruppo: sotto il codice invito e il ruolo, che sono
          // informazioni di amministrazione, l'utente dovrebbe scorrerle per
          // trovarle.
          _LinkGrid(
            links: [
              _Link(
                icon: Icons.leaderboard_outlined,
                title: 'Classifica',
                subtitle: 'I titoli piu amati dal gruppo e le tue posizioni.',
                onTap: () => context.push(
                  AppRoutes.ranking(group.id),
                  extra: group.name,
                ),
              ),
              _Link(
                icon: Icons.compare_arrows,
                title: 'Duelli',
                subtitle: 'Metti in gara due anime e guarda chi vince.',
                onTap: () =>
                    context.push(AppRoutes.duels(group.id), extra: group.name),
              ),
              _Link(
                icon: Icons.emoji_events_outlined,
                title: 'Tornei',
                subtitle:
                    'Un tabellone a eliminazione diretta fra anime del gruppo.',
                onTap: () => context.push(
                  AppRoutes.tournaments(group.id),
                  extra: group.name,
                ),
              ),
              _Link(
                icon: Icons.bookmark_border,
                title: 'Watchlist',
                subtitle: 'Gli anime che stai guardando e quelli da iniziare.',
                onTap: () => context.push(
                  AppRoutes.watchlist(group.id),
                  extra: group.name,
                ),
              ),
              _Link(
                icon: Icons.group_outlined,
                title: 'Membri',
                subtitle: 'Chi partecipa al gruppo e i suoi ruoli.',
                onTap: () => context.push(AppRoutes.groupMembers(group.id)),
              ),
            ],
          ),
          const SizedBox(height: ArSpace.lg),

          if (group.canSeeInviteCode) ...[
            _InviteCard(
              code: group.inviteCode,
              busy: _busy,
              onRegenerate: _regenerate,
            ),
            const SizedBox(height: ArSpace.lg),

            // Gli inviti singoli stanno sotto il codice del gruppo, non
            // accanto: il codice e' l'accesso permanente del gruppo, gli inviti
            // sono accessi singoli che scadono. In questo ordine l'utente
            // arriva al caso comune per primo e trova il caso particolare
            // sotto, senza dover scegliere quale delle due cose cercare.
            GroupInvitesSection(groupId: group.id),
            const SizedBox(height: ArSpace.lg),
          ],

          _RolePanel(role: group.myRole),
          const SizedBox(height: ArSpace.xl),

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
            const SizedBox(height: ArSpace.sm),
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

/// Una sezione del gruppo, pronta per la griglia delle card.
class _Link {
  const _Link({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
}

/// Elenco delle sezioni del gruppo.
///
/// Le card si mettono in colonna per costruzione e non per caso: ognuna e' un
/// elemento della stessa lista, quindi lo spazio fra una e l'altra lo mette il
/// ciclo e non la carta successiva. Scriverlo a mano sotto ogni card — come
/// faceva la versione precedente — aveva gia' fatto dimenticare una volta lo
/// spazio, e la quinta card risultava attaccata alla quarta.
///
/// Resta una sola colonna anche sui schermi larghi: sono cinque voci con
/// sottotitoli lunghi, e affiancarle significherebbe testi che si spezzano
/// su tre righe per guadagnare poco — la larghezza che avanza viene usata
/// meglio limitando la colonna del testo.
class _LinkGrid extends StatelessWidget {
  const _LinkGrid({required this.links});

  final List<_Link> links;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, link) in links.indexed) ...[
          if (index > 0) const SizedBox(height: ArSpace.sm),
          ArReveal(
            // L'ingresso a ondate dice "sono stati caricati": le cinque card
            // senza animazione arriverebbero insieme e sembrerebbero disegnate a
            // caso. Il ritardo si ferma a 240ms perche' oltre l'ultima card
            // aspetterebbe senza che l'occhio capisse perche'.
            delayMs: (index * 45).clamp(0, 240),
            child: _LinkCard(link: link),
          ),
        ],
      ],
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
        padding: const EdgeInsets.all(ArSpace.md),
        child: SizedBox(
          // Altezza fissa e non "il piu' che ci sta": il foglio deve poter
          // scorrere i membri anche su uno schermo basso, e una lista che si
          // adatta al foglio mostrerebbe due righe e un bordo tagliato.
          height: 420,
          child: members.when(
            loading: () => _MembersSkeleton(),
            error: (error, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(ArSpace.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$error', textAlign: TextAlign.center),
                    const SizedBox(height: ArSpace.sm),
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
                    padding: const EdgeInsets.all(ArSpace.lg),
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
                  const SizedBox(height: ArSpace.xxs),
                  Text(
                    'Chi scegli diventa owner e puo\' eliminare il gruppo.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: ArSpace.sm),
                  Expanded(
                    child: ListView.builder(
                      itemCount: candidates.length,
                      itemBuilder: (context, i) {
                        final member = candidates[i];

                        // `ProfileAvatar` e non `CircleAvatar` con
                        // `NetworkImage`: senza `errorBuilder` un URL avatar
                        // rotto mostrerebbe il riquadro grigio di Flutter,
                        // mentre questo cade sull'iniziale, che dice comunque
                        // di chi si tratta.
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: ArSpace.xs,
                          ),
                          leading: ProfileAvatar(
                            url: member.avatarUrl,
                            fallbackText: avatarInitial(member.label),
                            size: 40,
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
}

/// Scheletro della lista dei membri nel foglio.
///
/// Stesse righe della lista reale: uno scheletro fatto di righe generiche
/// cambierebbe altezza al primo arrivo dei dati e la lista salterebbe sotto
/// le dita di chi stava gia' per premere.
class _MembersSkeleton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: 5,
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
                  SkeletonBox(width: 140 - i * 12, height: 14),
                  const SizedBox(height: ArSpace.xs),
                  const SkeletonBox(width: 60, height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Scheda che apre una sezione del gruppo.
///
/// Comune a classifica, duelli, tornei, watchlist e membri: hanno lo stesso
/// aspetto e la sola differenza e' la destinazione, quindi due copie
/// significherebbero che un ritocco al suono del tocco o al padding ne
/// lascerebbe sempre una indietro.
///
/// L'icona sta in un riquadro arrotondato invece che flottere da sola: e' il
/// modo piu' economico di dire "questa scheda si apre" senza dover aggiungere
/// un bordo alla card, che su fondo scuro si perde.
class _LinkCard extends StatelessWidget {
  const _LinkCard({required this.link});

  final _Link link;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final card = Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(ArSpace.md),
        child: Row(
          children: [
            // Il badge prende l'accento della sezione: dentro i gruppi e' il
            // teal, quindi cinque schede identiche si leggono come "gruppo" e
            // non come "un'altra schermata viola".
            ArBadge(
              icon: link.icon,
              size: 42,
              radius: ArRadii.control,
              outline: true,
            ),
            const SizedBox(width: ArSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(link.title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: ArSpace.xxs),
                  Text(
                    link.subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: ArSpace.sm),
            Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );

    return ArPressable(onTap: link.onTap, child: card);
  }
}

/// Riquadro con il ruolo dell'utente nel gruppo.
///
/// Il ruolo non e' una riga di testo ma un dato che cambia quello che si puo'
/// fare: sta in una card con il riquadro colorato perche' e' l'informazione
/// che spiega perche' alcuni pulsanti ci sono e altri no, e sta in fondo
/// perché la si cerca quando qualcosa non si puo' fare, non all'inizio.
class _RolePanel extends StatelessWidget {
  const _RolePanel({required this.role});

  final GroupRole role;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = role.canManage
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(ArSpace.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  MetricLabel('Il tuo ruolo'),
                  const SizedBox(height: ArSpace.xs),
                  GroupRoleBadge(role: role),
                  const SizedBox(height: ArSpace.xs),
                  Text(
                    switch (role) {
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
                ],
              ),
            ),
            // L'icona distingue a colpo d'occhio il ruolo con poteri da quello
            // senza: e' l'unica differenza visiva che non si perde quando il
            // testo e' letto di fretta.
            Icon(
              role.canManage ? Icons.shield_outlined : Icons.person_outline,
              color: color,
            ),
          ],
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(ArSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const MetricLabel('Codice invito'),
            const SizedBox(height: ArSpace.xs),
            // Il carattere del font e la spaziatura li decide `ArCodeText`:
            // il codice va letto ad alta voce o digitato a mano, e da vicino
            // un font proporzionale fa scambiare O da 0 e I da 1.
            ArCodeText(code, large: true),
            const SizedBox(height: ArSpace.sm),
            Wrap(
              spacing: ArSpace.sm,
              runSpacing: ArSpace.xs,
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
    // copia-in-clipboard e' andato, e potrebbe ripeterlo o incollare il vecchio.
    messenger.showSnackBar(const SnackBar(content: Text('Codice copiato.')));
  }
}
