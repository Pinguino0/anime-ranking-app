import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/breakpoints.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/anime_thumb.dart';
import '../../../../core/ui/content_row.dart';
import '../../../../core/ui/section_header.dart';
import '../../../../core/ui/status_pill.dart';
import '../../../../core/ui/transitions.dart';
import '../../../ranking/presentation/ranking_controller.dart';
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
    final tournament = bracket.value?.tournament;
    final page = ArSpace.page(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          tournament?.name ?? 'Torneo',
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
              icon: const Icon(Icons.delete_outline, color: ArColors.danger),
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
      body: Center(
        child: ConstrainedBox(
          // Il tabellone ha una larghezza massima: le colonne dei turni non
          // hanno motivo di crescere oltre un certo punto, e a 1400px ogni
          // scontro diventa una striscia vuota con due parole al centro.
          constraints: const BoxConstraints(maxWidth: 1160),
          child: bracket.when(
            loading: () => const _BracketSkeleton(),
            error: (error, _) => ErrorState(
              message: _message(error),
              onRetry: () =>
                  ref.read(tournamentBracketProvider(widget.tournamentId).notifier).refresh(),
            ),
            data: (data) => TabBarView(
              controller: _tabs,
              children: [
                _BracketTab(
                  bracket: data,
                  lastVotedMatchId: _lastVotedMatchId,
                  onVote: _vote,
                  page: page,
                ),
                _StandingsTab(
                  tournamentId: widget.tournamentId,
                  page: page,
                ),
              ],
            ),
          ),
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
            style: FilledButton.styleFrom(backgroundColor: ArColors.danger),
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
    required this.page,
  });

  final TournamentBracket bracket;

  /// Scontro appena votato: la sua carta viene evidenziata per un momento,
  /// cosi' l'utente capisce quale dei tanti scontri ha appena toccato.
  final String? lastVotedMatchId;

  final void Function(TournamentMatch match, String animeId) onVote;

  final EdgeInsets page;

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
      return const EmptyState(
        icon: Icons.hub_outlined,
        title: 'Tabellone vuoto',
        message: 'Il torneo non ha scontri: nessun anime da mettere in gara.',
      );
    }

    // Un solo oggetto con i quattro dati che ogni colonna riceve: passarli uno
    // per uno costringeva a ripetere la stessa lista di sette parametri nelle due
    // costruzioni, e il giorno in cui se ne aggiunge uno le due liste divergono
    // e una delle due colonne smette di riceverlo.
    final session = _BracketSession(
      tallies: tallies,
      memberCount: memberCount,
      isSaving: isSaving,
      lastVotedMatchId: lastVotedMatchId,
      onVote: onVote,
    );

    final isExpanded = Breakpoints.fromContext(context).isExpanded;
    final padding = EdgeInsets.fromLTRB(page.left, ArSpace.md, page.right, ArSpace.xl);

    return ListView(
      padding: padding,
      children: [
        if (bracket.hasChampion) ...[
          _ChampionBanner(tournament: bracket.tournament),
          const SizedBox(height: ArSpace.md),
        ],
        // Su schermo largo i turni sono colonne: il bracket si legge da
        // sinistra a destra come una classifica eliminatoria, e ogni turno
        // parte dalla stessa altezza in modo che gli scontri successivi
        // appaiano sotto quelli che li hanno decisi.
        if (isExpanded)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final round in bracket.rounds) ...[
                  Expanded(child: _RoundColumn(round: round, session: session)),
                  if (round != bracket.rounds.last) const SizedBox(width: ArSpace.md),
                ],
              ],
            ),
          )
        // Su telefono i turni sono sezioni incolonnate: affiancare otto
        // partite su 360px renderebbe ogni titolo illeggibile.
        else
          for (final round in bracket.rounds) ...[
            _RoundColumn(round: round, session: session),
            if (round != bracket.rounds.last) const SizedBox(height: ArSpace.lg),
          ],
      ],
    );
  }
}

/// Dati condivisi da tutte le colonne del tabellone.
///
/// Sono gli stessi per ogni turno: raccoglierli qui evita di ripeterli a ogni
/// chiamata di [_RoundColumn] e rende impossibile dimenticarne uno.
@immutable
class _BracketSession {
  const _BracketSession({
    required this.tallies,
    required this.memberCount,
    required this.isSaving,
    required this.lastVotedMatchId,
    required this.onVote,
  });

  final MatchTallies tallies;
  final int? memberCount;
  final bool isSaving;
  final String? lastVotedMatchId;
  final void Function(TournamentMatch match, String animeId) onVote;
}

/// Una colonna (o sezione) di turni.
class _RoundColumn extends StatelessWidget {
  const _RoundColumn({required this.round, required this.session});

  final TournamentRound round;
  final _BracketSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                round.label,
                style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
              ),
            ),
            // Il numero di scontri accanto al nome: senza, in un bracket da 16
            // non si capisce se una colonna ne ha 1 o 8.
            MetricLabel('${round.matches.length} scontri'),
          ],
        ),
        const SizedBox(height: ArSpace.xs),
        for (final match in round.matches) ...[
          _MatchCard(
            match: match,
            tally: session.tallies[match.id],
            memberCount: session.memberCount,
            isSaving: session.isSaving,
            isJustVoted: session.lastVotedMatchId == match.id,
            onVote: session.onVote,
          ),
          if (match != round.matches.last) const SizedBox(height: ArSpace.sm),
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
    final counts = tally ?? const MatchTally(matchId: '');
    final isVotable = match.isVotable;
    final finished = match.isFinished;

    return Card(
      // Bordo colorato sullo scontro appena votato: dopo il ricaricamento dei
      // conteggi l'utente vede i numeri muoversi, e senza un segnale saprebbe
      // di aver toccato la scheda sbagliata.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ArRadii.card),
        side: isJustVoted
            ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 2)
            : BorderSide.none,
      ),
      // Ombra solo sugli scontri chiusi: uno scontro ancora da decidere e' una
      // domanda, e una domanda non si mette in evidenza come un risultato.
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: DecoratedBox(
        decoration: BoxDecoration(boxShadow: finished ? ArShadows.card : null),
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
      ),
    );
  }
}

/// Riga di un contendente.
///
/// Il vincitore non e' solo un colore: e' l'unica riga che ha una barra di
/// vittorie accanto ai voti. Un numero non spiega perche' un anime e' passato e
/// l'altro no, e su un tabellone quella e' l'informazione che serve.
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
        // Verde semantico e non viola: il verde e' gia' il colore dello stato
        // "concluso" nella lista dei tornei, e qui un vincitore deve avere lo
        // stesso colore che ha la pastiglia del torneo finito.
        color: isWinner ? ArColors.success.withValues(alpha: 0.10) : null,
        padding: const EdgeInsets.symmetric(horizontal: ArSpace.sm, vertical: ArSpace.xs),
        child: Row(
          children: [
            if (isWinner)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Icon(Icons.check_circle, size: 18, color: ArColors.success),
              )
            else
              // Il posto dell'icona del vincitore resta vuoto anche quando non
              // c'e': con l'allineamento variabile i titoli degli scontri diversi
              // non combacerebbero mai incolonnati.
              const SizedBox(width: 24),
            // Uno slot vuoto mostra un segnaposto e il nome insieme, non due
            // volte "Da decidere": la riga deve dire cosa aspettare una volta sola.
            if (title == null)
              const Icon(Icons.help_outline, size: 28, color: ArColors.textLow)
            else
              AnimeThumb(url: imageUrl, title: title!, size: 28, radius: ArRadii.chip / 2),
            const SizedBox(width: ArSpace.xs),
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
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Icon(Icons.how_to_vote, size: 16, color: ArColors.accent),
              ),
            Text(
              '$votes',
              style: theme.textTheme.titleSmall?.copyWith(
                color: isWinner ? ArColors.textHigh : theme.colorScheme.onSurfaceVariant,
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
    final progress = memberCount == null || memberCount! == 0
        ? null
        : (votes / memberCount!).clamp(0.0, 1.0);

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
      padding: const EdgeInsets.fromLTRB(ArSpace.sm, ArSpace.xs, ArSpace.sm, ArSpace.sm),
      // Pieno e non traslucido: la riga e' un blocco dentro la card, e con un
      // alpha sopra un'altra superficie il colore risultante cambia a seconda
      // della card che lo ospita.
      color: ArColors.containerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          if (progress != null) ...[
            const SizedBox(height: 6),
            _ProgressBar(value: progress),
          ],
        ],
      ),
    );
  }
}

/// Barra di quanto manca alla chiusura dello scontro.
///
/// Il riempimento parte da zero e si allarga con durata breve: e' il segnale
/// che distingue "questo scontro si sta chiudendo" da "questo scontro e'
/// fermo", che e' la differenza fra una votazione che sembra funzionare e una
/// che sembra bloccata.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(ArRadii.chip / 2),
      child: SizedBox(
        height: 4,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: value),
          duration: ArMotion.base,
          curve: ArMotion.enter,
          builder: (context, animated, _) => LinearProgressIndicator(
            value: animated,
            minHeight: 4,
            backgroundColor: ArColors.containerLow,
            valueColor: AlwaysStoppedAnimation(
              value >= 1 ? ArColors.success : ArColors.primary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Banner del campione.
///
/// Non e' [HeroBanner] e la ragione e' una sola: quel banner porta dentro un
/// pulsante "Guarda" pensato per aprire una scheda, e qui non c'e' niente da
/// aprire — il campione e' l'ultimo risultato della pagina, non un contenuto da
/// esplorare. Un pulsante che non porta da nessuna parte e' peggio di nessun
/// pulsante, perche' promette un'azione che l'app non puo' fare.
///
/// E' costruito con lo stesso linguaggio del tema (gradiente del brand, alone
/// colorato, oro di [ArColors.rank]) perche' il risultato di un torneo e' la
/// cosa che questa schermata deve far notare piu' di tutte le altre.
class _ChampionBanner extends StatelessWidget {
  const _ChampionBanner({required this.tournament});

  final Tournament tournament;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final champion = tournament.championTitle;
    final turns = '${tournament.bracketSize} anime · '
        '${tournament.rounds} ${tournament.rounds == 1 ? "turno" : "turni"}';

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ArColors.container,
        borderRadius: BorderRadius.circular(ArRadii.card),
        border: Border.all(color: ArColors.rank(1).withValues(alpha: 0.35)),
        // Alone dorato e non ombra: e' una vittoria, e l'oro e' il colore che
        // questo tema usa gia' per il primo posto in classifica.
        boxShadow: ArShadows.glow(ArColors.rank(1), strength: 0.22),
      ),
      child: Row(
        children: [
          // La fascia a gradiente e' alta quanto la riga e occupa una fetta
          // fissa a sinistra: e' la "pedana" su cui sta il campione, e dice
          // "vincitore" anche a chi non legge le parole.
          Container(
            width: 6,
            decoration: const BoxDecoration(gradient: ArColors.brand),
          ),
          const SizedBox(width: ArSpace.md),
          AnimeThumb(
            url: tournament.championImageUrl,
            title: champion ?? '',
            size: 56,
            radius: ArRadii.control,
          ),
          const SizedBox(width: ArSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // `ArColors.rank` e' un metodo, quindi non puo' stare in un
                // `const`: qui la posizione e' sempre la prima, e il colore
                // dell'oro e' gia' quello del primo posto in classifica.
                MetricLabel('Torneo concluso', color: ArColors.rank(1)),
                const SizedBox(height: ArSpace.xxs),
                Text(
                  champion ?? 'Campione',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: ArSpace.xxs),
                Text(turns, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: ArSpace.md),
          Padding(
            padding: const EdgeInsets.only(right: ArSpace.md),
            child: Icon(Icons.emoji_events, color: ArColors.rank(1), size: 28),
          ),
        ],
      ),
    );
  }
}

/// Tab della classifica finale.
class _StandingsTab extends ConsumerWidget {
  const _StandingsTab({required this.tournamentId, required this.page});

  final String tournamentId;
  final EdgeInsets page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final standings = ref.watch(tournamentStandingsProvider(tournamentId));
    final isExpanded = Breakpoints.fromContext(context).isExpanded;

    return standings.when(
      loading: () => const _StandingsSkeleton(),
      error: (error, _) => ErrorState(
        message: _message(error),
        onRetry: () =>
            ref.read(tournamentStandingsProvider(tournamentId).notifier).refresh(),
      ),
      data: (rows) {
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.leaderboard_outlined,
            title: 'Classifica vuota',
            message: 'Gli anime entrano in classifica quando il torneo viene creato.',
          );
        }

        return isExpanded ? _table(context, rows) : _list(context, rows);
      },
    );
  }

  /// Tabella su desktop.
  ///
  /// Va in `SingleChildScrollView` anche quando c'e' spazio: la tabella ha una
  /// larghezza minima data dalle colonne piu' larghe, e a 900px di finestra con
  /// un nome anime in fondo si andrebbe a capo o si taglierebbe. Scorrendo
  /// solo quando serve, il comportamento resta identico al telefono.
  Widget _table(BuildContext context, List<TournamentStanding> rows) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(page.left, ArSpace.md, page.right, ArSpace.xl),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columnSpacing: ArSpace.lg,
          headingRowColor: const WidgetStatePropertyAll(ArColors.containerHigh),
          dividerThickness: 1,
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
                  DataCell(_Position(position: i + 1)),
                  DataCell(
                    // Larghezza minima dichiarata: senza, la colonna si stringe
                    // fino alla copertina e il titolo sparisce dietro l'ellipsis
                    // anche quando la finestra e' larga.
                    Row(
                      children: [
                        AnimeThumb(
                          url: rows[i].imageUrl,
                          title: rows[i].title,
                          size: 32,
                          radius: ArRadii.chip / 2,
                        ),
                        const SizedBox(width: ArSpace.sm),
                        ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 160, maxWidth: 280),
                          child: Text(rows[i].title, overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  ),
                  DataCell(
                    ArCountUp(
                      value: rows[i].matchesWon.toDouble(),
                      builder: (_, animated) => Text('${animated.round()}'),
                    ),
                  ),
                  DataCell(
                    ArCountUp(
                      value: rows[i].votesReceived.toDouble(),
                      builder: (_, animated) => Text('${animated.round()}'),
                    ),
                  ),
                  DataCell(
                    StatusPill(
                      label: rows[i].isOut ? 'Eliminato' : 'In gara',
                      color: rows[i].isOut
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : ArColors.success,
                      filled: true,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// Elenco a schede su telefono e tablet.
  Widget _list(BuildContext context, List<TournamentStanding> rows) {
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(page.left, ArSpace.sm, page.right, ArSpace.xl),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: ArSpace.xs),
      itemBuilder: (context, i) {
        final row = rows[i];
        final theme = Theme.of(context);

        return Card(
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(ArSpace.sm),
            child: Row(
              children: [
                SizedBox(width: 28, child: _Position(position: i + 1)),
                const SizedBox(width: ArSpace.xs),
                AnimeThumb(
                  url: row.imageUrl,
                  title: row.title,
                  size: 40,
                  radius: ArRadii.chip,
                ),
                const SizedBox(width: ArSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${row.matchesWon} vinte · ${row.votesReceived} voti ricevuti',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: ArSpace.sm),
                StatusPill(
                  label: row.isOut ? 'Eliminato' : 'In gara',
                  color: row.isOut ? ArColors.textLow : ArColors.success,
                  filled: true,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Numero di posizione, colorato come le medaglie.
///
/// Viene da [ArColors.rank] cosi' la posizione ha lo stesso significato nella
/// classifica, nei duelli e nel tabellone: l'oro del primo posto non ricomincia
/// a ogni schermata.
class _Position extends StatelessWidget {
  const _Position({required this.position});

  final int position;

  @override
  Widget build(BuildContext context) {
    return Text(
      '$position',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: position <= 3 ? ArColors.rank(position) : ArColors.textMid,
            fontVariations: const [FontVariation('wght', 700)],
          ),
    );
  }
}

/// Scheletro del tabellone.
///
/// Tre colonne di due schede: la forma e' gia' nota dal bracket generato, e
/// vederla comparire dice all'utente che il tabellone sta per arrivare.
class _BracketSkeleton extends StatelessWidget {
  const _BracketSkeleton();

  @override
  Widget build(BuildContext context) {
    final page = ArSpace.page(context);
    final columns = Breakpoints.gridColumns(MediaQuery.sizeOf(context).width, min: 1, max: 3);

    return Padding(
      padding: EdgeInsets.fromLTRB(page.left, ArSpace.md, page.right, ArSpace.xl),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var c = 0; c < columns; c++) ...[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SkeletonBox(width: 90, height: 16),
                  const SizedBox(height: ArSpace.xs),
                  for (var i = 0; i < (columns - c); i++) ...[
                    const SkeletonBox(height: 96, radius: ArRadii.card),
                    const SizedBox(height: ArSpace.sm),
                  ],
                ],
              ),
            ),
            if (c != columns - 1) const SizedBox(width: ArSpace.md),
          ],
        ],
      ),
    );
  }
}

/// Scheletro della classifica.
class _StandingsSkeleton extends StatelessWidget {
  const _StandingsSkeleton();

  @override
  Widget build(BuildContext context) {
    final page = ArSpace.page(context);

    return ListView.separated(
      padding: EdgeInsets.fromLTRB(page.left, ArSpace.sm, page.right, ArSpace.xl),
      itemCount: 5,
      separatorBuilder: (_, _) => const SizedBox(height: ArSpace.xs),
      itemBuilder: (_, _) => const Card(
        child: Padding(
          padding: EdgeInsets.all(ArSpace.sm),
          child: Row(
            children: [
              SkeletonBox(width: 40, height: 40, radius: ArRadii.chip),
              SizedBox(width: ArSpace.sm),
              Expanded(child: SkeletonBox(height: 16)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Testo d'errore con fallback sui messaggi tecnici.
String _message(Object error) => switch (error) {
      final TournamentsFailure e => e.message,
      _ => 'Dati del torneo non disponibili. Riprova.',
    };
