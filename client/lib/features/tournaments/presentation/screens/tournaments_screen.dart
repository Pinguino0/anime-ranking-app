import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/breakpoints.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/anime_thumb.dart';
import '../../../../core/ui/content_row.dart';
import '../../../../core/ui/section_header.dart';
import '../../../../core/ui/status_pill.dart';
import '../../../../core/ui/transitions.dart';
import '../../../groups/domain/group.dart';
import '../../../groups/presentation/groups_controller.dart';
import '../../../ranking/domain/ranking.dart';
import '../../../ranking/presentation/ranking_controller.dart';
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
    final page = ArSpace.page(context);

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
        loading: () => _LoadingList(page: page),
        error: (error, _) => ErrorState(
          message: _message(error),
          onRetry: () => ref.read(tournamentsProvider(groupId).notifier).refresh(),
        ),
        data: (rows) {
          if (rows.isEmpty) {
            return EmptyState(
              icon: Icons.emoji_events_outlined,
              title: 'Nessun torneo in questo gruppo',
              message: 'Lancia un torneo a eliminazione diretta: ogni membro vota '
                  'ogni scontro e vince chi raccoglie piu voti.',
              // Anche il pulsante dentro lo stato vuoto: il FAB c'e' sempre, ma
              // con la lista vuota e' l'unico elemento a schermo e questa e' la
              // schermata in cui l'utente arriva la prima volta.
              action: ArGradientButton(
                label: 'Lancia un torneo',
                icon: Icons.add,
                onPressed: () => _create(context, ref),
              ),
            );
          }

          return _TournamentList(
            rows: rows,
            page: page,
            onTap: (tournament) => _open(context, ref, tournament),
            onCreate: () => _create(context, ref),
          );
        },
      ),
      // Il FAB e' la scelta giusta solo dove il pollice arriva. Su desktop
      // sarebbe un bottone isolato nell'angolo di uno schermo da 1400px: li il
      // CTA sta nell'intestazione, dove l'occhio arriva gia' cercando il
      // contenuto.
      floatingActionButton: Breakpoints.fromContext(context).isCompact
          ? FloatingActionButton.extended(
              // Senza tag, due schermate con un FAB sulla stessa rotta
              // condividerebbero lo stesso hero e Flutter solleverebbe "multiple
              // heroes that share the same tag".
              heroTag: 'tournament-create',
              onPressed: () => _create(context, ref),
              icon: const Icon(Icons.emoji_events_outlined),
              label: const Text('Nuovo torneo'),
            )
          : null,
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

/// Elenco dei tornei, con larghezza massima.
///
/// La larghezza massima serve a una cosa sola: su un portatile da 1440px una
/// riga di 1368px non e' piu' una riga, e' una striscia di testo che l'occhio
/// attraversa senza fermarsi. Il contenuto si tiene a una misura in cui una riga
/// si legge tutta senza muovere gli occhi.
class _TournamentList extends StatelessWidget {
  const _TournamentList({
    required this.rows,
    required this.page,
    required this.onTap,
    required this.onCreate,
  });

  final List<Tournament> rows;
  final EdgeInsets page;
  final void Function(Tournament tournament) onTap;
  final VoidCallback onCreate;

  /// Altezza fissa della card in griglia.
  ///
  /// Serve perche' [SliverGridDelegateWithFixedCrossAxisCount] chiede una
  /// altezza costante e le card hanno un contenuto variabile (il riga del
  /// campione c'e' solo a torneo finito). Per questo la riga del campione e'
  /// sempre presente: quando manca, dice che il campione e' ancora da decidere,
  /// che e' un'informazione vera e tiene tutte le card alte uguali.
  static const double _cardExtent = 148;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final columns = Breakpoints.gridColumns(width, min: 1, max: 2);
    // Con una sola colonna la lista non ha bisogno di un tetto: e' gia' larga
    // quanto lo schermo meno i margini.
    final maxWidth = columns > 1 ? 1040.0 : 720.0;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (columns > 1) _wideHeader(context),
            Expanded(
              child: columns > 1
                  ? GridView.builder(
                      padding: EdgeInsets.fromLTRB(
                        page.left,
                        ArSpace.xs,
                        page.right,
                        ArSpace.xxl,
                      ),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisExtent: _cardExtent,
                        crossAxisSpacing: ArSpace.md,
                        mainAxisSpacing: ArSpace.md,
                      ),
                      itemCount: rows.length,
                      itemBuilder: (context, i) => _TournamentCard(
                        tournament: rows[i],
                        onTap: () => onTap(rows[i]),
                      ),
                    )
                  : ListView.separated(
                      padding: EdgeInsets.fromLTRB(
                        page.left,
                        ArSpace.md,
                        page.right,
                        // Spazio per il FAB: senza, l'ultima card finisce
                        // sotto il bottone e non e' cliccabile.
                        ArSpace.xxl + ArSpace.xxl,
                      ),
                      itemCount: rows.length,
                      separatorBuilder: (_, _) => const SizedBox(height: ArSpace.sm),
                      itemBuilder: (context, i) => _TournamentCard(
                        tournament: rows[i],
                        onTap: () => onTap(rows[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Intestazione con il CTA, al posto del FAB.
  ///
  /// Dice anche quanti tornei ci sono: una lista senza numero non da' l'idea di
  /// quanto sia lunga, e su griglia l'occhio conta le card solo a meta' scorrimento.
  Widget _wideHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: ArSpace.md),
      child: Row(
        children: [
          Expanded(
            child: SectionHeader(
              title: 'Tornei del gruppo',
              subtitle: rows.length == 1 ? '1 torneo' : '${rows.length} tornei',
              padding: EdgeInsets.zero,
            ),
          ),
          const SizedBox(width: ArSpace.md),
          ArGradientButton(
            label: 'Nuovo torneo',
            icon: Icons.emoji_events_outlined,
            onPressed: onCreate,
          ),
        ],
      ),
    );
  }
}

/// Riga della lista tornei.
///
/// La scheda e' tutta piatta, senza bordo: il tema definisce le card come
/// superfici tonali, e aggiungere un bordo sopra una superficie tonale stacca
/// la card dal fondo invece di sollevarla.
class _TournamentCard extends StatelessWidget {
  const _TournamentCard({required this.tournament, required this.onTap});

  final Tournament tournament;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final champion = tournament.championDisplayTitle;
    final isDone = tournament.isCompleted;

    return ArPressable(
      onTap: onTap,
      scale: 0.985,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(ArSpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      tournament.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(width: ArSpace.sm),
                  StatusPill(
                    label: tournament.status.label,
                    // Lo stato usa gli stessi colori del tabellone: "concluso"
                    // e' la vittoria, e in verde si legge come tale anche nella
                    // lista, senza dover aprire il torneo.
                    color: isDone ? ArColors.success : ArColors.accent,
                    filled: true,
                  ),
                ],
              ),
              const SizedBox(height: ArSpace.xxs),
              Text(
                [
                  '${tournament.bracketSize} anime · ${tournament.rounds} '
                  '${tournament.rounds == 1 ? "turno" : "turni"}',
                  if (tournament.creatorName != null) 'di ${tournament.creatorName}',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: ArSpace.sm),
              // Riga del campione sempre presente: e' il posto dove il risultato
              // di un torneo si legge senza aprirlo, e tenere l'altezza costante
              // e' cio' che permette alla griglia di non avere buchi.
              //
              // Niente `Spacer` qui dentro: la stessa card vive sia nella lista
              // (dove l'altezza non e' limitata) sia in griglia (dove lo e'), e
              // uno spazio elastico dentro una lista senza altezza finita va in
              // errore di layout. Uno spazio fisso rende le due situazioni
              // identiche.
              Row(
                children: [
                  if (isDone)
                    AnimeThumb(
                      url: tournament.championImageUrl,
                      title: champion ?? '',
                      size: 24,
                      radius: ArRadii.chip / 2,
                    )
                  else
                    const Icon(
                      Icons.help_outline,
                      size: 22,
                      color: ArColors.textLow,
                    ),
                  const SizedBox(width: ArSpace.xs),
                  Expanded(
                    child: Text(
                      isDone ? 'Campione: $champion' : 'Campione da decidere',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: isDone
                            ? ArColors.rank(1)
                            : theme.colorScheme.onSurfaceVariant,
                        fontVariations: [
                          FontVariation('wght', isDone ? 700 : 400),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Scheletri in attesa dei tornei.
///
/// Sono tre card fantasma e non uno spinner: la lista sa gia' quanto e' alta e
/// dove stanno i bordi, e veder comparire quella forma e' un'informazione che
/// lo spinner non da'.
class _LoadingList extends StatelessWidget {
  const _LoadingList({required this.page});

  final EdgeInsets page;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(page.left, ArSpace.md, page.right, ArSpace.xl),
      itemCount: 3,
      separatorBuilder: (_, _) => const SizedBox(height: ArSpace.sm),
      itemBuilder: (_, _) => const Card(
        child: Padding(
          padding: EdgeInsets.all(ArSpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBox(width: 180, height: 20),
              SizedBox(height: ArSpace.sm),
              SkeletonBox(width: 120, height: 14),
            ],
          ),
        ),
      ),
    );
  }
}

/// Quota di schermo che puo' occupare la lista degli anime dentro il foglio.
///
/// Non e' "tutto lo spazio che resta": e' una frazione fissa. La lista era un
/// `Flexible` dentro un altro `Flexible`, e con la tastiera aperta su uno
/// schermo basso lo spazio residuo andava a zero o quasi, con due esiti diversi
/// a seconda di quanto era: overflow da schermo, oppure lista alta quanto
/// tutta la pagina e pulsante "Lancia" spinto fuori. Una quota fissa elimina il
/// caso in cui lo spazio non esiste.
const double _pickerListShare = 0.4;

/// Foglio di creazione del torneo.
///
/// Il nome e la lista degli anime sono nello stesso foglio perche' i due
/// controlli dipendono l'uno dall'altro: il numero di scelte ammesso (2, 4, 8,
/// 16) e' quello che decide la forma del tabellone, e cambiarlo dopo aver
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
          left: ArSpace.lg,
          right: ArSpace.lg,
          top: ArSpace.md,
          // Il foglio va sopra la tastiera: senza questo il campo del nome
          // finisce coperto mentre si scrive.
          bottom: MediaQuery.viewInsetsOf(context).bottom + ArSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Nuovo torneo', style: theme.textTheme.titleLarge),
            const SizedBox(height: ArSpace.md),
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
            const SizedBox(height: ArSpace.xs),
            // Un solo `Flexible` per tutta la zona sotto il campo: e' il
            // contenitore che cede spazio quando la tastiera si apre, e nulla
            // dentro prova a chiederne un pezzo.
            Flexible(
              child: ranking.when(
                loading: () => const _PickerSkeleton(),
                error: (error, _) => ErrorState(
                  message: _rankingMessage(error),
                  onRetry: () =>
                      ref.read(rankingProvider(widget.groupId).notifier).refresh(),
                ),
                data: (entries) {
                  if (entries.isEmpty) {
                    return EmptyState(
                      icon: Icons.hub_outlined,
                      title: 'Nessun anime votato',
                      message: 'Il gruppo non ha anime votati: un torneo si lancia '
                          'fra anime che qualcuno ha gia valutato.',
                    );
                  }

                  return _animePicker(entries);
                },
              ),
            ),
            if (participantsError != null) ...[
              const SizedBox(height: ArSpace.xs),
              Text(
                participantsError,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: ArSpace.md),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Annulla'),
                  ),
                ),
                const SizedBox(width: ArSpace.sm),
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
    final listHeight = MediaQuery.sizeOf(context).height * _pickerListShare;

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
        // `shrinkWrap` con altezza limitata: la lista si ferma a quello che
        // serve davvero e non occupa il foglio quando gli anime sono due.
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: listHeight),
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
                title: Text(entry.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(_scoreLabel(entry)),
                secondary: AnimeThumb(
                  url: entry.imageUrl,
                  title: entry.displayTitle,
                  size: 32,
                  radius: ArRadii.chip / 2,
                ),
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

/// Scheletro della lista anime, con la stessa altezza della lista vera.
///
/// Se lo scheletro fosse piu' basso, l'elenco salterebbe avanti quando arrivano
/// i dati: e' il salto che fa sembrare l'app lenta anche quando e' veloce.
class _PickerSkeleton extends StatelessWidget {
  const _PickerSkeleton();

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * _pickerListShare),
      child: ListView.separated(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: 4,
        separatorBuilder: (_, _) => const SizedBox(height: ArSpace.sm),
        itemBuilder: (_, _) => const Row(
          children: [
            SkeletonBox(width: 32, height: 32, radius: ArRadii.chip / 2),
            SizedBox(width: ArSpace.sm),
            Expanded(child: SkeletonBox(height: 14)),
          ],
        ),
      ),
    );
  }
}

/// Testo d'errore con fallback sui messaggi tecnici.
String _message(Object error) => switch (error) {
      final TournamentsFailure e => e.message,
      _ => 'Tornei non disponibili. Riprova.',
    };

/// Errore della classifica dentro il foglio.
///
/// Messaggio diverso da quello dei tornei perche' la richiesta che e' fallita
/// e' un'altra: dire "tornei non disponibili" mentre si sta caricando la lista
/// degli anime da cui scegliere sarebbe una bugia.
String _rankingMessage(Object error) => switch (error) {
      final RankingFailure e => e.message,
      _ => 'Gli anime del gruppo non sono disponibili. Riprova.',
    };
