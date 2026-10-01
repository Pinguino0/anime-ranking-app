import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/breakpoints.dart';
import '../../../auth/presentation/widgets/auth_scaffold.dart';
import '../../domain/ranking.dart';
import '../ranking_controller.dart';

/// Classifica di un gruppo.
///
/// Le tre classifiche speciali e la classifica principale stanno nella stessa
/// pagina, con i selettori in cima: sono quattro letture della stessa tabella,
/// e aprire una schermata per ognuna costringerebbe l'utente a tornare
/// indietro per cambiare vista.
class RankingScreen extends ConsumerStatefulWidget {
  const RankingScreen({required this.groupId, this.groupName, super.key});

  final String groupId;

  /// Nome del gruppo, mostrato nel titolo.
  ///
  /// Facoltativo perche' la schermata si apre anche dalla lista classifiche,
  /// dove il nome arriva dal gruppo in lista. Se manca si mostra solo
  /// "Classifica": un titolo generico e' meglio di far fallire la schermata per
  /// un dato che e' solo cosmetico.
  final String? groupName;

  @override
  ConsumerState<RankingScreen> createState() => _RankingScreenState();
}

class _RankingScreenState extends ConsumerState<RankingScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groupId = widget.groupId;
    final stats = ref.watch(groupStatsProvider(groupId));

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.groupName == null ? 'Classifica' : 'Classifica · ${widget.groupName}',
          // Il nome del gruppo puo' essere lungo: senza troncamento
          // l'appbar su telefono spingerebbe fuori il bottone indietro.
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Ricarica',
            icon: const Icon(Icons.refresh),
            onPressed: () => _refresh(context, ref),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          // Le quattro schede non entrano su telefono: senza `isScrollable` e
          // senza etichette corte, TabBar tronca i titoli a meta' ("I più
          // vot...") e le schede sembrano rotte.
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: 'Generale'),
            Tab(text: 'Più amati'),
            Tab(text: 'Più discussi'),
            Tab(text: 'Divisivi'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _StandardTab(groupId: groupId),
          _SpecialTab(groupId: groupId, kind: SpecialRankingKind.top),
          _SpecialTab(groupId: groupId, kind: SpecialRankingKind.mostVoted),
          _SpecialTab(groupId: groupId, kind: SpecialRankingKind.divisive),
        ],
      ),
      bottomNavigationBar: stats.maybeWhen(
        data: (data) => data.isEmpty ? null : _StatsStrip(stats: data),
        orElse: () => null,
      ),
    );
  }

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final groupId = widget.groupId;

    // Ricarica tutto quello che la pagina mostra: la singola tab visibile
    // sarebbe un refresh a meta', e l'utente che torna su una tab ritroverebbe
    // numeri vecchi senza averlo chiesto.
    ref.invalidate(rankingProvider(groupId));
    ref.invalidate(groupStatsProvider(groupId));
    for (final kind in SpecialRankingKind.values) {
      ref.invalidate(specialRankingProvider((groupId, kind)));
    }

    await ref.read(rankingProvider(groupId).future);
    if (!mounted) return;
    messenger.showSnackBar(const SnackBar(content: Text('Classifica aggiornata.')));
  }
}

/// Barra in basso con i totali del gruppo.
///
/// Sempre visibile mentre si scorre la classifica: i numeri di contesto (quanti
/// voti, quanto e' la media) servono per dare un senso alle posizioni, e
/// obbligare a tornare su per leggerli farebbe dimenticarli.
class _StatsStrip extends StatelessWidget {
  const _StatsStrip({required this.stats});

  final GroupStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      elevation: 3,
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: SafeArea(
          top: false,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _Stat(label: 'Membri', value: '${stats.memberCount}'),
              _Stat(label: 'Anime votati', value: '${stats.animeRated}'),
              _Stat(label: 'Voti', value: '${stats.totalVotes}'),
              _Stat(label: 'Media', value: _trim(stats.groupMean)),
            ],
          ),
        ),
      ),
    );
  }

  static String _trim(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: theme.textTheme.titleMedium),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Classifica principale.
class _StandardTab extends ConsumerWidget {
  const _StandardTab({required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ranking = ref.watch(rankingProvider(groupId));

    return ranking.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _ErrorState(
        message: '$error',
        onRetry: () => ref.read(rankingProvider(groupId).notifier).refresh(),
      ),
      data: (rows) {
        if (rows.isEmpty) {
          return const _EmptyState(
            message: 'Nessun anime votato in questo gruppo.',
            hint: 'Quando qualcuno vota un anime, la classifica si riempie da sola.',
          );
        }

        final controller = ref.read(rankingProvider(groupId).notifier);

        return Column(
          children: [
            // Fuori dal `RefreshIndicator`: e' un avviso, non una lista, e non
            // deve sparire appena si trascina.
            _OfflineBanner(groupId: groupId),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => controller.refresh(),
                child: Breakpoints.fromContext(context).isExpanded
                    // Da desktop la tabella e' un blocco unico con una sola riga
                    // di intestazioni: costruire una DataTable per riga
                    // ripeterebbe le intestazioni 50 volte e occuperebbe piu'
                    // schermo dei dati.
                    ? SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            RankingTable(rows: rows, groupId: groupId),
                            _LoadMore(groupId: groupId, controller: controller),
                          ],
                        ),
                      )
                    : _PagedList(rows: rows, groupId: groupId, controller: controller),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Lista della classifica che carica la pagina successiva da sola.
///
/// Il trigger e' vicino al fondo, non a fondo schermo: se arrivasse all'ultima
/// riga l'utente dovrebbe accorgersi che la lista continua e scorrere ancora,
/// mentre a mezza schermo dal fondo le righe sono gia' in arrivo. Con un
/// [ScrollController] che ascolta le posizioni, pero', non serve costruire un
/// righe "fantoccio": l'ultima riga reale fa da marcatore.
class _PagedList extends ConsumerStatefulWidget {
  const _PagedList({
    required this.rows,
    required this.groupId,
    required this.controller,
  });

  final List<RankingEntry> rows;
  final String groupId;
  final RankingController controller;

  @override
  ConsumerState<_PagedList> createState() => _PagedListState();
}

class _PagedListState extends ConsumerState<_PagedList> {
  final ScrollController _scroll = ScrollController();
  late final VoidCallback _onScroll;

  @override
  void initState() {
    super.initState();

    // La pagina va letta al momento dello scroll, non una volta sola in
    // `build`: `build` non gira a ogni scatto di rotella e costerebbe di
    // ricostruire tutta la lista a ogni pixel.
    _onScroll = () => _maybeLoadMore(ref.read(rankingPaginationProvider(widget.groupId)));
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  /// Carica quando le ultime righe entrano nella schermata.
  void _maybeLoadMore(RankingPagination pagination) {
    if (!_scroll.hasClients) return;

    // Il widget puo' essere ricostruito con piu' righe (dopo un tocco verso
    // l'alto) mentre il caricamento e' gia' in corso: senza questo controllo
    // si aprirebbero due richieste sulla stessa pagina.
    if (pagination.isLoadingMore) return;

    // Dopo un errore la lista resta a fondo schermo, quindi ogni scroll
    // residuo ripartirebbe da capo e la stessa pagina verrebbe richiesta in
    // loop finche' la rete non torna. Dopo un errore si riprova solo se lo chiede
    // l'utente.
    if (pagination.error != null) return;

    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent - _triggerOffset) {
      widget.controller.loadMore();
    }
  }

  /// Quanto prima del fondo scatta il caricamento.
  ///
  /// Circa tre righe: abbastanza perche' la richiesta finisca prima che
  /// l'utente arrivi in fondo, non cosi' tanto da caricare la pagina mentre
  /// sta ancora leggendo le prime righe.
  static const double _triggerOffset = 220;

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;

    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: rows.length + 1,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i < rows.length) {
          return RankingRow(entry: rows[i], groupId: widget.groupId);
        }

        return _LoadMore(groupId: widget.groupId, controller: widget.controller);
      },
    );
  }
}

/// Riga finale con il pulsante per le righe successive.
///
/// Un pulsante e non solo uno spinner: se il caricamento fallisce l'utente deve
/// poter riprovare da li', e con uno spinner che gira per sempre non avrebbe
/// nessuna azione. Quando non c'e' niente da caricare la riga sparisce, cosi'
/// l'ultima posizione non resta occupata da un elemento vuoto.
class _LoadMore extends ConsumerWidget {
  const _LoadMore({required this.groupId, required this.controller});

  final String groupId;
  final RankingController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    // `watch` e non `read`: senza ascoltare il provider il pulsante resterebbe
    // su "Altre posizioni" anche mentre la richiesta e' in volo, e il tocco
    // ripetuto aprirebbe richieste sovrapposte.
    final pagination = ref.watch(rankingPaginationProvider(groupId));
    if (!pagination.hasMore && !pagination.isLoadingMore) {
      return const SizedBox.shrink();
    }

    final error = pagination.error;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (error != null) ...[
            Text(
              error.message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
            ),
            const SizedBox(height: 8),
          ],
          if (pagination.isLoadingMore)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: CircularProgressIndicator(),
            )
          else
            OutlinedButton(
              onPressed: controller.loadMore,
              child: const Text('Altre posizioni'),
            ),
        ],
      ),
    );
  }
}

/// Una classifica speciale.
class _SpecialTab extends ConsumerWidget {
  const _SpecialTab({required this.groupId, required this.kind});

  final String groupId;
  final SpecialRankingKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(specialRankingProvider((groupId, kind)));
    final theme = Theme.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            kind.description,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: entries.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => _ErrorState(
              message: '$error',
              onRetry: () => ref.read(specialRankingProvider((groupId, kind)).notifier).refresh(),
            ),
            data: (rows) {
              if (rows.isEmpty) {
                return _EmptyState(
                  message: 'Niente da mostrare qui.',
                  hint: switch (kind) {
                    // "Divisivi" ha una soglia di 3 voti imposta dal backend:
                    // dire il numero rende il vuoto comprensibile invece che
                    // apparentemente rotto.
                    SpecialRankingKind.divisive =>
                      'Servono almeno 3 voti sullo stesso anime per misurare quanto sono divise le opinioni.',
                    SpecialRankingKind.mostVoted =>
                      'Nessun anime ha ancora ricevuto un voto in questo gruppo.',
                    SpecialRankingKind.top => 'Nessun anime votato in questo gruppo.',
                  },
                );
              }

              return RefreshIndicator(
                onRefresh: () =>
                    ref.read(specialRankingProvider((groupId, kind)).notifier).refresh(),
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) => SpecialRankingRow(entry: rows[i]),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Riga della classifica principale.
///
/// Da [LayoutSize.expanded] in su i numeri passano in una tabella con intestazioni
/// e la riga non usa piu' le coppie etichetta/valore: a 1400px una riga a
/// scheda con quattro numeri sparsi si legge peggio di una tabella, e il
/// prompt chiede esplicitamente che da desktop il formato sia tabella e non
/// "desktop rimpicciolito".
class RankingTable extends ConsumerWidget {
  const RankingTable({required this.rows, required this.groupId, super.key});

  final List<RankingEntry> rows;
  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DataTable(
      // Spaziatura contenuta e intestazioni brevi: sei colonne con intestazioni
      // lunghe escono dalla larghezza utile anche a 1200px, e una tabella che
      // trabocca mostra righe tagliate invece di numeri illeggibili.
      columnSpacing: 20,
      headingRowHeight: 40,
      columns: const [
        DataColumn(label: Text('#')),
        DataColumn(label: Text('Anime')),
        DataColumn(label: Text('Media'), numeric: true),
        DataColumn(label: Text('Voti'), numeric: true),
        DataColumn(label: Text('Peso'), numeric: true),
        DataColumn(label: Text('Tuo voto'), numeric: true),
      ],
      rows: [
        for (final entry in rows)
          DataRow(
            cells: [
              DataCell(Text('${entry.position}')),
              // La larghezza e' fissata perche' `DataTable` misura ogni colonna
              // sul contenuto e non distribuisce lo spazio: senza un tetto, il
              // titolo di un anime lungo allargherebbe la tabella oltre lo
              // schermo e le colonne dei numeri finirebbero fuori vista.
              DataCell(
                SizedBox(width: 320, child: _AnimeCell(entry: entry)),
              ),
              DataCell(Text(entry.meanScoreLabel ?? '-')),
              DataCell(Text('${entry.voteCount}')),
              DataCell(Text(entry.rankingScoreLabel)),
              DataCell(_VoteButton(entry: entry, groupId: groupId)),
            ],
          ),
      ],
    );
  }
}

/// Riga della classifica in formato scheda, per telefono e tablet.
///
/// Da [LayoutSize.expanded] in su la stessa lista e' una tabella: vedi
/// [RankingTable]. Il motivo e' che una riga a scheda con quattro numeri sparsi
/// si legge male a 1400px, e il prompt chiede che da desktop il formato
/// cambi e non che sia solo piu' largo.
class RankingRow extends ConsumerWidget {
  const RankingRow({required this.entry, required this.groupId, super.key});

  final RankingEntry entry;
  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          _PositionBadge(entry: entry),
          const SizedBox(width: 12),
          Expanded(child: _AnimeCell(entry: entry)),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                entry.meanScoreLabel ?? '-',
                style: theme.textTheme.titleMedium,
              ),
              Text(
                '${entry.voteCount} ${entry.voteCount == 1 ? 'voto' : 'voti'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
          _VoteButton(entry: entry, groupId: groupId),
        ],
      ),
    );
  }
}

/// Riga di una classifica speciale.
class SpecialRankingRow extends StatelessWidget {
  const SpecialRankingRow({required this.entry, super.key});

  final SpecialRankingEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (valueTitle, valueText) = entry.valueLabel;
    final (secondaryTitle, secondaryText) = entry.secondaryLabel;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Text(
              '${entry.position}',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: _AnimeCell(title: entry.title, imageUrl: entry.imageUrl)),
          const SizedBox(width: 8),
          // Entrambe le metriche hanno etichetta: "8.5" e "3" senza sapere
          // cosa sia ciascuno fanno leggere a indovinare.
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(valueText, style: theme.textTheme.titleMedium),
              Text(
                valueTitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(secondaryText, style: theme.textTheme.bodyMedium),
              Text(
                secondaryTitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Numero di posizione con la variazione.
///
/// La variazione e' accanto al numero e non dentro: il numero e' la posizione,
/// tutto il resto e' un commento. Un "-2" in rosso accanto al numero dice
/// "sei sceso di due posti", che e' l'informazione utile.
class _PositionBadge extends StatelessWidget {
  const _PositionBadge({required this.entry});

  final RankingEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final delta = entry.positionDelta;

    return SizedBox(
      width: 32,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${entry.position}', style: theme.textTheme.titleMedium),
          if (delta != 0)
            Text(
              delta > 0 ? '+$delta' : '$delta',
              style: theme.textTheme.labelSmall?.copyWith(
                color: delta > 0 ? Colors.green.shade700 : theme.colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }
}

/// Nome e immagine di un anime, con i dettagli in pillola.
class _AnimeCell extends StatelessWidget {
  const _AnimeCell({this.entry, this.title, this.imageUrl});

  final RankingEntry? entry;
  final String? title;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = title ?? entry!.title;
    final url = imageUrl ?? entry?.imageUrl;
    final meta = _meta();

    return Row(
      children: [
        AnimeThumb(url: url, title: name),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              if (meta.isNotEmpty)
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Dettagli secondari: anno, episodi, generi.
  ///
  /// Uno solo: un elenco di genre tag in fondo a ogni riga trasformerebbe la
  /// classifica in un muro di testo e le righe di altezze diverse.
  String _meta() {
    if (entry == null) return '';

    final parts = <String>[
      if (entry!.year != null) '${entry!.year}',
      if (entry!.episodes != null) '${entry!.episodes} episodi',
      ...entry!.genres.take(2),
    ];

    return parts.join(' · ');
  }
}

/// Copertina dell'anime con fallback sull'iniziale.
class AnimeThumb extends StatelessWidget {
  const AnimeThumb({this.url, required this.title, this.size = 40, super.key});

  final String? url;
  final String title;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final fallback = ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Text(
          title.trim().isEmpty ? '?' : title.trim()[0].toUpperCase(),
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: size,
        height: size,
        child: (url == null || url!.isEmpty)
            ? fallback
            : Image.network(
                url!,
                fit: BoxFit.cover,
                // Senza gestione dell'errore, un URL rotto mostrerebbe il
                // riquadro grigio di Image.network senza dire nulla: peggio
                // del fallback, che almeno mostra di che anime si tratta.
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }
}

/// Pulsante per votare.
///
/// Mostra il voto gia' dato e apre il selettore al tocco. Il voto non si
/// cambia "al volo" con un menu: un passo da 8.5 a 9 per sbaglio su un
/// telefono e' un voto perso, e i voti non si annullano da soli.
class _VoteButton extends ConsumerWidget {
  const _VoteButton({required this.entry, required this.groupId});

  final RankingEntry entry;
  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final mine = entry.myScore;

    if (mine == null) {
      return IconButton(
        onPressed: () => _open(context, ref),
        icon: const Icon(Icons.star_border),
        tooltip: 'Vota ${entry.title}',
      );
    }

    return TextButton(
      onPressed: () => _open(context, ref),
      style: TextButton.styleFrom(
        foregroundColor: theme.colorScheme.primary,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      child: Text(
        mine.toStringAsFixed(mine == mine.roundToDouble() ? 0 : 1),
        style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final result = await showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      builder: (context) => RateSheet(entry: entry),
    );

    if (result == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);

    try {
      await ref.read(ratingProvider.notifier).rate(
            groupId: groupId,
            animeId: entry.animeId,
            score: result,
          );
      messenger.showSnackBar(
        SnackBar(content: Text('Voto di ${_formatVote(result)} a ${entry.title}.')),
      );
    } on RankingFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

/// Voto formattato per la conferma a schermo.
///
/// 7 e non "7.0", 7.5 e non "7.50": il testo di un messaggio non ha bisogno di
/// due decimali, e l'allineamento a due cifree in una lista di messaggi e'
/// rumore.
String _formatVote(double value) =>
    value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toStringAsFixed(1);

/// Foglio di votazione.
///
/// Un cursore a passo 0.5 da 0 a 10 con il valore grande in alto: scegliere
/// 7.5 con due cursori separati ("intero" e "mezzo punto") e' esatto ma
/// scomodo, e una griglia di 21 pulsanti occuperebbe meta' schermo.
///
/// Stateful e non `StatefulBuilder` dentro uno stateless: il valore scelto
/// deve sopravvivere al rebuild del foglio, e un campo su una classe senza
/// stato viene ricreato a ogni build.
class RateSheet extends StatefulWidget {
  const RateSheet({required this.entry, super.key});

  final RankingEntry entry;

  @override
  State<RateSheet> createState() => _RateSheetState();
}

class _RateSheetState extends State<RateSheet> {
  /// Voto in modifica, null finche' l'utente non tocca il cursore.
  double? _chosen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = widget.entry;

    // Parte dal voto gia' dato: riaprire il foglio non deve far partire da
    // zero un utente che sta solo correggendo un mezzo punto.
    final value = _chosen ?? entry.myScore ?? 7;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(entry.title, style: theme.textTheme.titleMedium),
            if (entry.genres.isNotEmpty)
              Text(
                entry.genres.take(3).join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 16),
            Text(
              _trim(value),
              textAlign: TextAlign.center,
              style: theme.textTheme.displayMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            Slider(
              value: value,
              min: RatingValidators.min,
              max: RatingValidators.max,
              // 21 divisioni = 21 posizioni da 0 a 10 a passo 0.5: senza
              // `divisions` il cursore si fermerebbe su valori che il CHECK
              // del database rifiuta.
              divisions: ((RatingValidators.max - RatingValidators.min) / RatingValidators.step)
                  .round(),
              label: value.toStringAsFixed(1),
              onChanged: (v) => setState(() => _chosen = v),
            ),
            Text(
              '0 = pessimo, 10 = capolavoro. Passi da mezzo punto.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
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
                    onPressed: () => Navigator.of(context).pop(value),
                    child: const Text('Vota'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 7 e non "7.0", 7.5 e non "7.50": il numero grande in centro non ha bisogno
  /// di due decimali per essere leggibile.
  static String _trim(double value) => _formatVote(value);
}

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
            Icon(Icons.leaderboard_outlined, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(message, style: theme.textTheme.titleMedium),
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

/// Avviso "stai vedendo una copia salvata".
///
/// Serve perche' una classifica vecchia senza avviso e' una classifica
/// sbagliata: le posizioni intorno a cui si e' deciso dove guardare sarebbero
/// altre. Il testo dice anche quando e' stata scritta la copia, cosi' l'utente
/// sa da quanto e' ferma.
class _OfflineBanner extends ConsumerWidget {
  const _OfflineBanner({required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final status = ref.watch(rankingCacheStatusProvider(groupId));
    if (!status.fromCache) return const SizedBox.shrink();

    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.wifi_off, size: 18, color: theme.colorScheme.onSecondaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Classifica salvata${_savedAt(status.savedAt)}: non si aggiorna senza rete.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSecondaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// " del 3 maggio", oppure niente se la copia non ha un tempo noto.
  static String _savedAt(DateTime? savedAt) {
    if (savedAt == null) return '';

    final local = savedAt.toLocal();
    final now = DateTime.now();
    final sameDay = local.year == now.year && local.month == now.month && local.day == now.day;

    final time = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    return sameDay ? ' di oggi alle $time' : ' del ${local.day}/${local.month} alle $time';
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
