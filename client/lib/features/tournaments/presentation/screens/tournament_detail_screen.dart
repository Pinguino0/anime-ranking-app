import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/breakpoints.dart';
import '../../../auth/presentation/widgets/auth_scaffold.dart';
import '../../../ranking/presentation/ranking_controller.dart';
import '../../../ranking/presentation/screens/ranking_screen.dart';
import '../../domain/tournaments.dart';
import '../tournaments_controller.dart';

/// Tabellone di un torneo.
///
/// Due schede: il tabellone e la classifica. Il tabellone serve mentre si
/// vota, la classifica dopo, e metterli nello stesso scorrimento nasconderebbe
/// l'una dietro l'altra.
///
/// La schermata riceve `groupId` e `canDelete` invece di andare a cercarli:
/// vengono dalla lista tornei, che conosce gia' entrambi, e ricalcolarli qui
/// significherebbe una richiesta in piu' per un dato che serve solo per un
/// menu.
class TournamentDetailScreen extends ConsumerStatefulWidget {
  const TournamentDetailScreen({
    required this.tournamentId,
    required this.groupId,
    required this.canDelete,
    super.key,
  });

  final String tournamentId;
  final String groupId;

  /// true se l'utente e admin: `delete_tournament` usa `is_group_admin`.
  final bool canDelete;

  @override
  ConsumerState<TournamentDetailScreen> createState() => _TournamentDetailScreenState();
}

class _TournamentDetailScreenState extends ConsumerState<TournamentDetailScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  /// Scontro su cui si e' appena votato, per l'annuncio.
  ///
  /// Lo scontro non si chiude finche' non ha votato tutto il gruppo, quindi il
  /// risultato del proprio voto non e' un esito: e' "vote registrato".
  String? _lastVotedMatchId;

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bracket = ref.watch(tournamentBracketProvider(widget.tournamentId));

    return Scaffold(
      appBar: AppBar(
        title: Text(
          bracket.value?.tournament.name ?? 'Torneo',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Ricarica',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
          if (widget.canDelete)
            IconButton(
              tooltip: 'Elimina torneo',
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Tabellone'),
            Tab(text: 'Classifica'),
          ],
        ),
      ),
      body: bracket.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorState(
          message: _message(error),
          onRetry: () => ref.read(tournamentBracketProvider(widget.tournamentId).notifier).refresh(),
        ),
        data: (data) => TabBarView(
          controller: _tabs,
          children: [
            _BracketTab(
              bracket: data,
              lastVotedMatchId: _lastVotedMatchId,
              onVote: _vote,
            ),
            _StandingsTab(tournamentId: widget.tournamentId),
          ],
        ),
      ),
    );
  }

  /// Rilettura completa: tabellone, voti e classifica.
  Future<void> _refresh() async {
    final messenger = ScaffoldMessenger.of(context);
    final id = widget.tournamentId;

    ref.invalidate(tournamentBracketProvider(id));
    ref.invalidate(tournamentVotesProvider(id));
    ref.invalidate(tournamentStandingsProvider(id));

    await ref.read(tournamentBracketProvider(id).future);
    if (!mounted) return;
    messenger.showSnackBar(const SnackBar(content: Text('Tabellone aggiornato.')));
  }

  Future<void> _vote(TournamentMatch match, String animeId) async {
    final messenger = ScaffoldMessenger.of(context);
    final tournamentId = widget.tournamentId;

    try {
      final closed = await ref.read(tournamentActionProvider.notifier).vote(
            tournamentId: tournamentId,
            matchId: match.id,
            animeId: animeId,
          );

      if (!mounted) return;
      setState(() => _lastVotedMatchId = match.id);

      messenger.showSnackBar(
        SnackBar(
          content: Text(
            closed
                // Il backend chiude lo scontro solo all'ultimo voto del gruppo, e
                // a quel punto fa avanzare il vincente: e' l'unico momento in cui
                // c'e' un esito da annunciare.
                ? 'Ultimo voto: scontro chiuso e vincente nel turno dopo.'
                : 'Voto registrato. Manca il voto degli altri membri.',
          ),
        ),
      );
    } on TournamentsFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _delete() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminare il torneo?'),
        content: const Text(
          'Vanno via tutti gli scontri e i voti. Non si puo annullare.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Elimina'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ref.read(tournamentActionProvider.notifier).delete(
            groupId: widget.groupId,
            tournamentId: widget.tournamentId,
          );
      navigator.pop();
    } on TournamentsFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

/// Tab del tabellone.
class _BracketTab extends ConsumerWidget {
  const _BracketTab({
    required this.bracket,
    required this.lastVotedMatchId,
    required this.onVote,
  });

  final TournamentBracket bracket;

  /// Scontro appena votato: la sua carta viene evidenziata per un momento,
  /// cosi' l'utente capisce quale dei tanti scontri ha appena toccato.
  final String? lastVotedMatchId;

  final void Function(TournamentMatch match, String animeId) onVote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tournamentId = bracket.tournament.id;
    // I voti e i membri possono non essere ancora arrivati: senza questi numeri
    // gli scontri si mostrano comunque, solo senza conteggi e senza la barra di
    // quanto manca. Meglio un tabellone incompleto che uno vuoto.
    final tallies = ref.watch(tournamentVotesProvider(tournamentId)).value ??
        const <String, MatchTally>{};
    final isSaving = ref.watch(tournamentActionProvider).isLoading;
    // I membri servono a mostrare quanti mancano: `resolve_tournament_match`
    // chiude lo scontro solo quando ha votato tutto il gruppo, quindi il numero
    // di voti da solo non dice se la partita e' decisa.
    final memberCount =
        ref.watch(groupStatsProvider(bracket.tournament.groupId)).value?.memberCount;

    if (bracket.rounds.isEmpty) {
      return const _EmptyState(
        message: 'Tabellone vuoto',
        hint: 'Il torneo non ha scontri: nessun anime da mettere in gara.',
      );
    }

    final isExpanded = Breakpoints.fromContext(context).isExpanded;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        if (bracket.hasChampion) _ChampionBanner(tournament: bracket.tournament),
        if (bracket.hasChampion) const SizedBox(height: 16),
        if (isExpanded)
          // Su schermo largo i turni sono colonne: il bracket si legge da
          // sinistra a destra come una classifica eliminatoria.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final round in bracket.rounds) ...[
                Expanded(
                  child: _RoundColumn(
                    round: round,
                    tallies: tallies,
                    memberCount: memberCount,
                    isSaving: isSaving,
                    lastVotedMatchId: lastVotedMatchId,
                    onVote: onVote,
                  ),
                ),
                if (round != bracket.rounds.last) const SizedBox(width: 12),
              ],
            ],
          )
        else
          // Su telefono i turni sono sezioni incolonnate: affiancare otto
          // partite su 360px renderebbe ogni titolo illeggibile.
          for (final round in bracket.rounds) ...[
            _RoundColumn(
              round: round,
              tallies: tallies,
              memberCount: memberCount,
              isSaving: isSaving,
              lastVotedMatchId: lastVotedMatchId,
              onVote: onVote,
            ),
            if (round != bracket.rounds.last) const SizedBox(height: 20),
          ],
      ],
    );
  }
}

/// Una colonna (o sezione) di turni.
class _RoundColumn extends StatelessWidget {
  const _RoundColumn({
    required this.round,
    required this.tallies,
    required this.memberCount,
    required this.isSaving,
    required this.lastVotedMatchId,
    required this.onVote,
  });

  final TournamentRound round;
  final MatchTallies tallies;
  final int? memberCount;
  final bool isSaving;
  final String? lastVotedMatchId;
  final void Function(TournamentMatch match, String animeId) onVote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          round.label,
          style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
        ),
        const SizedBox(height: 8),
        for (final match in round.matches) ...[
          _MatchCard(
            match: match,
            tally: tallies[match.id],
            memberCount: memberCount,
            isSaving: isSaving,
            isJustVoted: lastVotedMatchId == match.id,
            onVote: onVote,
          ),
          if (match != round.matches.last) const SizedBox(height: 12),
        ],
      ],
    );
  }
}

/// Uno scontro con i due contendenti e i voti.
///
/// Le righe vuote (turni successivi al primo) si vedono ma non si possono
/// toccare: e' l'unico modo per far capire che il tabellone e' gia' generato e
/// che quei posti si riempiranno da soli con i vincitori.
class _MatchCard extends StatelessWidget {
  const _MatchCard({
    required this.match,
    required this.tally,
    required this.memberCount,
    required this.isSaving,
    required this.isJustVoted,
    required this.onVote,
  });

  final TournamentMatch match;
  final MatchTally? tally;
  final int? memberCount;
  final bool isSaving;
  final bool isJustVoted;
  final void Function(TournamentMatch match, String animeId) onVote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final counts = tally ?? const MatchTally(matchId: '');
    final isVotable = match.isVotable;

    return Card(
      // Bordo colorato sullo scontro appena votato: dopo il ricaricamento dei
      // conteggi l'utente vede i numeri muoversi, e senza un segnale saprebbe
      // di aver toccato la scheda sbagliata.
      shape: isJustVoted
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.colorScheme.primary, width: 2),
            )
          : null,
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          _ContenderRow(
            title: match.animeATitle,
            imageUrl: match.animeAImageUrl,
            votes: counts.votesFor(match, match.animeAId),
            isWinner: match.isWinner(match.animeAId),
            isMine: counts.isMine(match.animeAId),
            // `isSaving` blocca il tocco durante la richiesta: senza, un doppio
            // tocco farebbe partire due voti e mostrerebbe due risultati
            // diversi per lo stesso scontro.
            onTap: isVotable && !isSaving ? () => onVote(match, match.animeAId!) : null,
          ),
          const Divider(height: 1),
          _ContenderRow(
            title: match.animeBTitle,
            imageUrl: match.animeBImageUrl,
            votes: counts.votesFor(match, match.animeBId),
            isWinner: match.isWinner(match.animeBId),
            isMine: counts.isMine(match.animeBId),
            onTap: isVotable && !isSaving ? () => onVote(match, match.animeBId!) : null,
          ),
          _MatchFooter(
            votes: counts.total,
            memberCount: memberCount,
            isVotable: isVotable,
            hasVoted: counts.myAnimeId != null,
          ),
        ],
      ),
    );
  }
}

/// Riga di un contendente.
class _ContenderRow extends StatelessWidget {
  const _ContenderRow({
    required this.title,
    required this.imageUrl,
    required this.votes,
    required this.isWinner,
    required this.isMine,
    required this.onTap,
  });

  final String? title;
  final String? imageUrl;
  final int votes;
  final bool isWinner;
  final bool isMine;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      child: Container(
        color: isWinner ? theme.colorScheme.primary.withValues(alpha: 0.10) : null,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            if (isWinner)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(Icons.check_circle, size: 18, color: theme.colorScheme.primary),
              )
            else
              const SizedBox(width: 24),
            // Uno slot vuoto mostra un segnaposto e il nome insieme, non due
            // volte "Da decidere": la riga deve dire cosa aspettare una volta sola.
            if (title == null)
              const Icon(Icons.help_outline, size: 28, color: Color(0xFF888888))
            else
              AnimeThumb(url: imageUrl, title: title!, size: 28),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title ?? 'Da decidere',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: title == null ? theme.colorScheme.onSurfaceVariant : null,
                  fontStyle: title == null ? FontStyle.italic : FontStyle.normal,
                  fontWeight: isWinner ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
            if (isMine)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(Icons.how_to_vote, size: 16, color: theme.colorScheme.secondary),
              ),
            Text(
              '$votes',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Riga di stato sotto uno scontro.
class _MatchFooter extends StatelessWidget {
  const _MatchFooter({
    required this.votes,
    required this.memberCount,
    required this.isVotable,
    required this.hasVoted,
  });

  final int votes;
  final int? memberCount;
  final bool isVotable;
  final bool hasVoted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final String text;
    if (!isVotable) {
      text = 'In attesa dei vincitori';
    } else if (hasVoted) {
      text = 'Hai votato · $votes${memberCount == null ? '' : '/$memberCount'}';
    } else {
      text = 'Vota per chi preferisci · $votes${memberCount == null ? '' : '/$memberCount'}';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// Banner del campione.
class _ChampionBanner extends StatelessWidget {
  const _ChampionBanner({required this.tournament});

  final Tournament tournament;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: theme.colorScheme.primary.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            AnimeThumb(url: tournament.championImageUrl, title: tournament.championTitle ?? '', size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Torneo concluso', style: theme.textTheme.labelMedium),
                  const SizedBox(height: 4),
                  Text(
                    tournament.championTitle ?? 'Campione',
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Icon(Icons.emoji_events),
          ],
        ),
      ),
    );
  }
}

/// Tab della classifica finale.
class _StandingsTab extends ConsumerWidget {
  const _StandingsTab({required this.tournamentId});

  final String tournamentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final standings = ref.watch(tournamentStandingsProvider(tournamentId));
    final isExpanded = Breakpoints.fromContext(context).isExpanded;

    return standings.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _ErrorState(
        message: _message(error),
        onRetry: () => ref.read(tournamentStandingsProvider(tournamentId).notifier).refresh(),
      ),
      data: (rows) {
        if (rows.isEmpty) {
          return const _EmptyState(
            message: 'Classifica vuota',
            hint: 'Gli anime entrano in classifica quando il torneo viene creato.',
          );
        }

        return isExpanded
            ? SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 900),
                    child: DataTable(
                      columnSpacing: 28,
                      columns: const [
                        DataColumn(label: Text('#')),
                        DataColumn(label: Text('Anime')),
                        DataColumn(label: Text('Vinte'), numeric: true),
                        DataColumn(label: Text('Voti ricevuti'), numeric: true),
                        DataColumn(label: Text('Stato')),
                      ],
                      rows: [
                        for (var i = 0; i < rows.length; i++)
                          DataRow(
                            cells: [
                              DataCell(Text('${i + 1}')),
                              DataCell(
                                Row(
                                  children: [
                                    AnimeThumb(url: rows[i].imageUrl, title: rows[i].title, size: 32),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(rows[i].title, overflow: TextOverflow.ellipsis),
                                    ),
                                  ],
                                ),
                              ),
                              DataCell(Text('${rows[i].matchesWon}')),
                              DataCell(Text('${rows[i].votesReceived}')),
                              DataCell(Text(rows[i].isOut ? 'Eliminato' : 'In gara')),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: rows.length,
                itemBuilder: (context, i) {
                  final row = rows[i];
                  return ListTile(
                    leading: SizedBox(
                      width: 28,
                      child: Text('${i + 1}', style: Theme.of(context).textTheme.titleSmall),
                    ),
                    title: Row(
                      children: [
                        AnimeThumb(url: row.imageUrl, title: row.title, size: 32),
                        const SizedBox(width: 10),
                        Expanded(child: Text(row.title, overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                    subtitle: Text(
                      '${row.matchesWon} vinte · ${row.votesReceived} voti ricevuti',
                    ),
                    trailing: Text(
                      row.isOut ? 'Eliminato' : 'In gara',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: row.isOut
                                ? Theme.of(context).colorScheme.onSurfaceVariant
                                : Theme.of(context).colorScheme.primary,
                          ),
                    ),
                  );
                },
              );
      },
    );
  }
}

/// Testo d'errore con fallback sui messaggi tecnici.
String _message(Object error) => switch (error) {
      final TournamentsFailure e => e.message,
      _ => 'Dati del torneo non disponibili. Riprova.',
    };

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message, required this.hint});

  final String message;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hub_outlined, size: 48, color: theme.colorScheme.onSurfaceVariant),
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