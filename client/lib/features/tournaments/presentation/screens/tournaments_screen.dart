import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../auth/presentation/widgets/auth_scaffold.dart';
import '../../../../core/router/app_router.dart';
import '../../../groups/domain/group.dart';
import '../../../groups/presentation/groups_controller.dart';
import '../../../ranking/domain/ranking.dart';
import '../../../ranking/presentation/ranking_controller.dart';
import '../../../ranking/presentation/screens/ranking_screen.dart';
import '../../domain/tournaments.dart';
import '../tournaments_controller.dart';

/// Tornei di un gruppo.
///
/// Chi puo' lanciare un torneo? Qualunque membro: `create_tournament` controlla
/// solo l'appartenenza al gruppo, non il ruolo. Quindi la creazione e' qui senza
/// condizioni, mentre l'eliminazione resta agli admin (`delete_tournament`
/// usa `is_group_admin`).
class TournamentsScreen extends ConsumerWidget {
  const TournamentsScreen({required this.groupId, this.groupName, super.key});

  final String groupId;
  final String? groupName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tournaments = ref.watch(tournamentsProvider(groupId));

    return Scaffold(
      appBar: AppBar(
        title: Text(
          groupName == null ? 'Tornei' : 'Tornei · $groupName',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Ricarica',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.read(tournamentsProvider(groupId).notifier).refresh(),
          ),
        ],
      ),
      body: tournaments.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorState(
          message: _message(error),
          onRetry: () => ref.read(tournamentsProvider(groupId).notifier).refresh(),
        ),
        data: (rows) {
          if (rows.isEmpty) {
            return _EmptyState(
              message: 'Nessun torneo in questo gruppo',
              hint: 'Lancia un torneo a eliminazione diretta: ogni membro vota '
                  'ogni scontro e vince chi raccoglie piu voti.',
              onCreate: () => _create(context, ref),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            itemCount: rows.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, i) => _TournamentTile(
              tournament: rows[i],
              onTap: () => _open(context, ref, rows[i]),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _create(context, ref),
        icon: const Icon(Icons.emoji_events_outlined),
        label: const Text('Nuovo torneo'),
      ),
    );
  }

  /// Apre il tabellone, passando se l'utente puo' eliminarlo.
  Future<void> _open(BuildContext context, WidgetRef ref, Tournament tournament) async {
    // `delete_tournament` e' l'unica azione amministrativa sui tornei: senza
    // sapere il ruolo il pulsante comparirebbe anche per un membro semplice e
    // fallirebbe solo dopo il tocco.
    final role = await _myRole(ref);

    if (!context.mounted) return;
    await context.push(
      AppRoutes.tournamentDetail(tournament.groupId, tournament.id),
      extra: role.canManage,
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);

    final created = await showModalBottomSheet<Tournament>(
      context: context,
      isScrollControlled: true,
      builder: (_) => CreateTournamentSheet(groupId: groupId),
    );

    if (created == null || !context.mounted) return;

    // Il tabellone appena creato si apre subito: l'utente ha appena scelto gli
    // anime e vuole vedere il primo scontro, non tornare alla lista. `canDelete`
    // e false perche' il ruolo non e' stato calcolato su questo percorso: la
    // creazione non ne ha bisogno e il menu si riattiva riaprendo il torneo
    // dalla lista.
    await context.push(AppRoutes.tournamentDetail(groupId, created.id), extra: false);
    if (!context.mounted) return;
    messenger.showSnackBar(const SnackBar(content: Text('Torneo lanciato.')));
  }

  /// Ruolo dell'utente nel gruppo, per il menu di eliminazione.
  Future<GroupRole> _myRole(WidgetRef ref) async {
    final groups = ref.read(groupsListProvider).value ?? const <AnimeGroup>[];
    for (final group in groups) {
      if (group.id == groupId) return group.myRole;
    }

    // Gruppo non in lista (apertura diretta): nessun ruolo noto, quindi nessun
    // menu. Meglio che mostrare "Elimina torneo" a chi non puo' usarlo.
    return GroupRole.member;
  }
}

/// Riga della lista tornei.
class _TournamentTile extends StatelessWidget {
  const _TournamentTile({required this.tournament, required this.onTap});

  final Tournament tournament;
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tournament.name, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      [
                        '${tournament.bracketSize} anime · ${tournament.rounds} '
                        '${tournament.rounds == 1 ? "turno" : "turni"}',
                        if (tournament.creatorName != null) 'di ${tournament.creatorName}',
                      ].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (tournament.championTitle != null) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          AnimeThumb(
                            url: tournament.championImageUrl,
                            title: tournament.championTitle ?? '',
                            size: 24,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Campione: ${tournament.championTitle}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.primary,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _StatusChip(status: tournament.status),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pastiglia di stato del torneo.
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final TournamentStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        status == TournamentStatus.completed ? theme.colorScheme.primary : theme.colorScheme.secondary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.label,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

/// Foglio di creazione del torneo.
///
/// Il nome e la lista degli anime sono nello stesso foglio perche' i due
/// controlli dipendono l'uno dall'altro: il numero di scelte ammesso (2, 4, 8,
/// 16) e quello che decide la forma del tabellone, e cambiarlo dopo aver
/// scritto il nome significherebbe rifare tutto.
class CreateTournamentSheet extends ConsumerStatefulWidget {
  const CreateTournamentSheet({required this.groupId, super.key});

  final String groupId;

  @override
  ConsumerState<CreateTournamentSheet> createState() => _CreateTournamentSheetState();
}

class _CreateTournamentSheetState extends ConsumerState<CreateTournamentSheet> {
  final TextEditingController _name = TextEditingController();

  /// Id scelti, nell'ordine di selezione.
  ///
  /// L'ordine conta: `create_tournament` assegna il primo anime al primo
  /// scontro del turno 1, quindi la lista e' il tabellone iniziale.
  final List<String> _selected = [];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ranking = ref.watch(rankingProvider(widget.groupId));
    final nameError = TournamentValidators.nameError(_name.text);
    final participantsError = _selected.isEmpty
        ? null
        : TournamentValidators.participantsError(_selected);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 16,
          // Il foglio va sopra la tastiera: senza questo il campo del nome
          // finisce coperto mentre si scrive.
          bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Nuovo torneo', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              maxLength: 60,
              decoration: InputDecoration(
                labelText: 'Nome del torneo',
                hintText: 'Coppa del venerdi',
                errorText: _name.text.isEmpty ? null : nameError,
                border: const OutlineInputBorder(),
              ),
              // `onChanged` e non `onSubmitted`: senza un rebuild lo stato di
              // validazione resterebbe sbagliato e il pulsante non si abiliterebbe
              // mai.
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            ranking.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, _) => Text(
                _message(error),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
              data: (entries) {
                if (entries.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'Il gruppo non ha anime votati: un torneo si lancia fra '
                      'anime che qualcuno ha gia valutato.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  );
                }

                return Flexible(child: _animePicker(entries));
              },
            ),
            if (participantsError != null) ...[
              const SizedBox(height: 8),
              Text(
                participantsError,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Annulla'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: nameError == null && participantsError == null
                        ? () => _create(context)
                        : null,
                    child: const Text('Lancia'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _animePicker(List<RankingEntry> entries) {
    final theme = Theme.of(context);
    // Il contatore sta sopra la lista e non nel pulsante: con 16 scelte lo
    // schermo da 900px finirebbe dentro la lista.
    final nearest = TournamentValidators.nearestBracketSize(_selected.length);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Anime scelti: ${_selected.length}', style: theme.textTheme.titleSmall),
            ),
            TextButton.icon(
              // Ha senso solo se ci sono scelte da fare: con 2 anime gia' scelti
              // non c'e' piu' niente da generare.
              onPressed: _selected.isEmpty || entries.length < nearest
                  ? null
                  : () => _takeTop(entries, nearest),
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: const Text('I primi'),
            ),
          ],
        ),
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: entries.length,
            itemBuilder: (context, i) {
              final entry = entries[i];
              final isSelected = _selected.contains(entry.animeId);

              return CheckboxListTile(
                value: isSelected,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(_scoreLabel(entry)),
                secondary: AnimeThumb(url: entry.imageUrl, title: entry.title, size: 32),
                onChanged: (_) => _toggle(entry.animeId),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Sceglie i primi N anime della classifica.
  ///
  /// E' il modo piu' rapido per un torneo fra i piu' amati del gruppo, che e'
  /// anche l'unico pratico per 16 partecipanti: sceglierli a mano richiederebbe
  /// di scorrere piu' liste.
  void _takeTop(List<RankingEntry> entries, int size) {
    final top = entries.take(size).map((e) => e.animeId).toSet();
    setState(() {
      _selected
        ..clear()
        ..addAll(entries.where((e) => top.contains(e.animeId)).map((e) => e.animeId));
    });
  }

  void _toggle(String animeId) {
    setState(() {
      if (!_selected.remove(animeId)) _selected.add(animeId);
    });
  }

  Future<void> _create(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    try {
      final tournament = await ref.read(tournamentActionProvider.notifier).create(
            groupId: widget.groupId,
            name: _name.text,
            animeIds: List.of(_selected),
          );
      navigator.pop(tournament);
    } on TournamentsFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// Il voto con cui l'utente ha valutato l'anime, per non confonderlo con la
  /// media del gruppo: sono due numeri diversi sulla stessa riga.
  static String _scoreLabel(RankingEntry entry) {
    final mine = entry.myScore;
    final mean = entry.meanScore;

    return [
      if (mine != null) 'tuo voto ${mine.toStringAsFixed(mine == mine.roundToDouble() ? 0 : 1)}',
      if (mean != null) 'media ${mean.toStringAsFixed(1)}',
      if (entry.voteCount > 0) '${entry.voteCount} voti',
    ].join(' · ');
  }
}

/// Testo d'errore con fallback sui messaggi tecnici.
String _message(Object error) => switch (error) {
      final TournamentsFailure e => e.message,
      _ => 'Tornei non disponibili. Riprova.',
    };

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message, required this.hint, required this.onCreate});

  final String message;
  final String hint;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.emoji_events_outlined, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(message, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            // Anche il pulsante dentro lo stato vuoto: il FAB c'e' sempre, ma
            // con la lista vuota e' l'unico elemento a schermo e questa e' la
            // schermata in cui l'utente arriva la prima volta.
            FilledButton.tonalIcon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('Lancia un torneo'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AuthErrorBanner.error(message),
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: onRetry, child: const Text('Riprova')),
            ],
          ),
        ),
      ),
    );
  }
}