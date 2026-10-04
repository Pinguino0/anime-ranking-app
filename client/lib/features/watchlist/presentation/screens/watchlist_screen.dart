import 'package:animerank/core/ui/content_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../anime/domain/anime.dart';
import '../../../auth/presentation/widgets/auth_scaffold.dart';
import '../../../../core/constants/breakpoints.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/anime_thumb.dart';
import '../../../../core/ui/section_header.dart';
import '../../../../core/ui/transitions.dart';
import '../../../ranking/presentation/ranking_controller.dart';
import '../../domain/watchlist.dart';
import '../watchlist_controller.dart';

/// Watchlist personale dentro un gruppo.
///
/// Le voci sono raggruppate per stato invece di stare in un elenco unico: la
/// domanda che ci si pone guardando una watchlist e "cosa devo guardare adesso",
/// e la risposta sono le prime sezioni. Un elenco misto costringerebbe a
/// scorrerlo tutto per trovare gli anime in visione.
///
/// Il gruppo arriva dalla rotta e non da un selettore: la watchlist e' per
/// gruppo (stessa tabella, stesse colonne `group_id`), quindi una voce globale
/// nella navigazione dovrebbe prima chiedere "di quale gruppo?".
class WatchlistScreen extends ConsumerStatefulWidget {
  const WatchlistScreen({required this.groupId, this.groupName, super.key});

  final String groupId;
  final String? groupName;

  @override
  ConsumerState<WatchlistScreen> createState() => _WatchlistScreenState();
}

class _WatchlistScreenState extends ConsumerState<WatchlistScreen> {
  /// Stato scelto come filtro, null per "tutti".
  WatchStatus? _status;

  /// Filtro sui preferiti, indipendente dallo stato.
  ///
  /// Sono due filtri e non uno perche' "i miei preferiti" e' una domanda
  /// diversa da "cosa sto guardando": un anime completato e preferito sta
  /// nelle due liste, e con un filtro solo uno dei due casi sparirebbe.
  bool _favoritesOnly = false;

  @override
  Widget build(BuildContext context) {
    final groupId = widget.groupId;
    final state = ref.watch(watchlistProvider(groupId));
    final totals = ref.watch(watchlistTotalsProvider(groupId)).value;
    final entries = _visible(state.value ?? const <WatchlistEntry>[]);
    final expanded = Breakpoints.fromContext(context).isExpanded;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.groupName == null ? 'Watchlist' : 'Watchlist · ${widget.groupName}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Aggiungi dalla classifica',
            icon: const Icon(Icons.playlist_add),
            onPressed: () => _addFromRanking(context, ref),
          ),
          IconButton(
            tooltip: 'Ricarica',
            icon: const Icon(Icons.refresh),
            onPressed: () => _refresh(context, ref),
          ),
        ],
      ),
      body: Column(
        children: [
          // I totali stanno in alto e non in fondo come nella classifica: qui
          // la lista parte dal principio e si scorre verso il basso, quindi in
          // fondo sarebbero l'ultima cosa che si vede e la prima che si
          // dimentica. Costa una riga di spazio in piu' in alto.
          if (totals != null && totals.entries > 0) _TotalsStrip(totals: totals),
          _FilterBar(
            status: _status,
            favoritesOnly: _favoritesOnly,
            onStatus: (value) => setState(() => _status = value),
            onFavorites: (value) => setState(() => _favoritesOnly = value),
          ),
          const Divider(height: 1),
          Expanded(
            child: state.when(
              // Lo scheletro ha la stessa altezza della riga vera: un
              // segnaposto piu' basso farebbe salire tutta la lista al primo
              // arrivo dei dati, e l'occhio perderebbe la riga che stava
              // leggendo.
              loading: () => _WatchlistSkeleton(),
              error: (error, _) => ErrorState(
                message: '$error',
                onRetry: () => ref.read(watchlistProvider(groupId).notifier).refresh(),
              ),
              // Il filtro e' applicato anche quando non c'e' niente da
              // mostrare: con il filtro attivo l elenco vuoto e' la risposta
              // ("non hai preferiti"), non un caricamento da rifare.
              data: (_) => entries.isEmpty
                  ? EmptyState(
                      icon: _favoritesOnly
                          ? Icons.star_border
                          : Icons.bookmark_border,
                      title: _emptyMessage,
                      message: _emptyHint,
                    )
                  : RefreshIndicator(
                      onRefresh: () =>
                          ref.read(watchlistProvider(groupId).notifier).refresh(),
                      child: expanded
                          ? SingleChildScrollView(
                              padding: const EdgeInsets.symmetric(
                                vertical: ArSpace.sm,
                              ),
                              child: WatchlistTable(
                                entries: entries,
                                groupId: groupId,
                              ),
                            )
                          : ListView(
                              padding: EdgeInsets.only(
                                left: ArSpace.page(context).left,
                                right: ArSpace.page(context).right,
                                bottom: ArSpace.xxl,
                              ),
                              children: _cards(context, ref, entries),
                            ),
                    ),
            ),
          ),
        ],
      ),
      floatingActionButton: state.hasValue
          ? FloatingActionButton.extended(
              onPressed: () => _addFromRanking(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('Aggiungi'),
              backgroundColor: ArColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(ArRadii.control),
              ),
            )
          : null,
    );
  }

  String get _emptyMessage {
    if (_favoritesOnly) return 'Nessun preferito.';
    final status = _status;
    return status == null ? 'La watchlist e vuota.' : 'Nessun anime in stato ${status.label.toLowerCase()}.';
  }

  String get _emptyHint {
    if (_favoritesOnly) return 'Segna un anime con la stella per ritrovarlo qui.';
    if (_status != null) return 'Cambia filtro o aggiungi un anime dalla classifica.';
    return 'Aggiungi un anime dalla classifica del gruppo: li voti mostrano cosa avete guardato insieme.';
  }

  /// Voci da mostrare, gia' filtrate.
  List<WatchlistEntry> _visible(List<WatchlistEntry> entries) {
    final filtered = entries
        .where((e) => _status == null || e.status == _status)
        .where((e) => !_favoritesOnly || e.isFavorite)
        .toList();

    // Dentro uno stato l ordine del backend e' per aggiornamento, che e' quello
    // giusto mentre si guarda qualcosa. Per l elenco piatto dei preferiti
    // l ordine alfabetico: sono titoli da ritrovare, non da finire.
    if (_status != null || _favoritesOnly) {
      filtered.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    }

    return filtered;
  }

  /// Schede con le intestazioni di stato, per il formato a lista.
  List<Widget> _cards(BuildContext context, WidgetRef ref, List<WatchlistEntry> entries) {
    final groupId = widget.groupId;

    if (_status != null || _favoritesOnly) {
      return [
        for (final (i, entry) in entries.indexed)
          WatchlistRow(entry: entry, groupId: groupId, revealMs: _delayOf(i)),
      ];
    }

    final widgets = <Widget>[];

    // L'indice corre su tutte le righe, non dentro ogni gruppo: l'onda deve
    // attraversare la pagina, altrimenti le intestazioni di stato ripartono
    // da capo e la lista sembra spezzata in tre elenchi.
    var seen = 0;

    for (final status in WatchStatus.displayOrder) {
      final rows = entries.where((e) => e.status == status).toList();
      if (rows.isEmpty) continue;

      widgets.add(
        Padding(
          padding: EdgeInsets.fromLTRB(
            ArSpace.page(context).left,
            ArSpace.md,
            ArSpace.page(context).right,
            ArSpace.xs,
          ),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: statusColor(status),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: ArSpace.xs),
              Expanded(
                child: Text(
                  status.label,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              MetricLabel('${rows.length}'),
            ],
          ),
        ),
      );

      widgets.addAll([
        for (final entry in rows)
          WatchlistRow(
            entry: entry,
            groupId: groupId,
            revealMs: _delayOf(seen++),
          ),
      ]);
    }

    return widgets;
  }

  /// Ritardo di comparsa della riga numero [index].
  ///
  /// Cresce con la posizione e si ferma a 320ms: oltre il limite le righe in
  /// fondo arriverebbero cosi' tardi che l'utente le cercherebbe gia' come se
  /// mancassero. Lo stesso tetto usato dalle caroselli della home, cosi' anche
  /// qui l'ingresso ha la stessa cadenza del resto dell'app.
  static int _delayOf(int index) => (index * 30).clamp(0, 320);

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final groupId = widget.groupId;

    // Entrambe le richieste, non solo le righe: un refresh a meta' lascerebbe le
    // cifre in alto che non sommano piu' con quello che c'e' elencato sotto.
    ref.invalidate(watchlistProvider(groupId));
    ref.invalidate(watchlistTotalsProvider(groupId));

    await ref.read(watchlistProvider(groupId).future);
    if (!mounted) return;
    messenger.showSnackBar(const SnackBar(content: Text('Watchlist aggiornata.')));
  }

  Future<void> _addFromRanking(BuildContext context, WidgetRef ref) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AddFromRankingSheet(groupId: widget.groupId),
    );
  }
}

/// Colore associato a uno stato.
///
/// Preso dalla palette del tema e non dal `ColorScheme`: i cinque colori sono
/// quelli dell'app (e dello sfondo dei pallini nella navigazione), e i ruoli
/// semantici del `ColorScheme` sono gia' occupati da errore e successo.
Color statusColor(WatchStatus status) => switch (status) {
      WatchStatus.planned => ArColors.planned,
      WatchStatus.watching => ArColors.watching,
      WatchStatus.completed => ArColors.completed,
      WatchStatus.dropped => ArColors.dropped,
      WatchStatus.paused => ArColors.paused,
    };

/// Scheda anime ricostruita da una riga di watchlist.
///
/// Come nella classifica: la riga porta l'id interno di `public.anime` e il
/// minimo dei dati, quindi la scheda mostra la realta' di quello che c'e',
/// senza riempirsi i buchi con copertine o voti inventati. La lista dei voti e'
/// un'altra tabella e non si ricava da qui.
AnimeEntry _animeOf(WatchlistEntry entry) => AnimeEntry(
      externalId: entry.animeId,
      title: entry.title,
      imageUrl: entry.imageUrl,
      episodes: entry.episodes,
      year: entry.year,
      genres: entry.genres,
      status: entry.airing ? AnimeAirStatus.airing : null,
    );

/// Cifre della watchlist, in alto.
///
/// Un bordo in basso invece di un'ombra: la striscia si appoggia al fondo della
/// pagina, che e' scuro, e un'ombra su fondo scuro non si vede.
class _TotalsStrip extends StatelessWidget {
  const _TotalsStrip({required this.totals});

  final WatchlistTotals totals;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: ArColors.containerLow,
        border: Border(bottom: BorderSide(color: ArColors.borderSoft)),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: ArSpace.page(context).left,
          vertical: ArSpace.sm,
        ),
        child: SafeArea(
          top: false,
          bottom: false,
          child: Row(
            children: [
              // `Expanded` e non `spaceEvenly`: le quattro cifre hanno larghezze
              // diverse (3 contro 1.240) e lo spazio fra loro dipenderebbe
              // allora dalla lunghezza dei numeri, spostando ogni etichetta a
              // ogni aggiornamento. Con Expanded le colonne restano ferme e il
              // testo si accorcia: su uno schermo da 340px l'etichetta lunga
              // non esce dai bordi.
              _Stat(label: 'In watchlist', value: totals.entries),
              _Stat(label: 'In visione', value: totals.watching),
              _Stat(label: 'Completati', value: totals.completed),
              _Stat(label: 'Episodi', value: totals.episodes),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            // Il punto come separatore delle migliare: nella scrittura
            // italiana il punto e' il separatore, e un conteggio abbreviato
            // su un totale che si aggiorna spesso fa perdere il conto.
            _thousands(value),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              color: ArColors.textHigh,
              fontVariations: const [FontVariation('wght', 700)],
            ),
          ),
          const SizedBox(height: ArSpace.xxs),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: ArColors.textLow,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }

  static String _thousands(int value) {
    final digits = value.abs().toString();
    final buffer = StringBuffer(value < 0 ? '-' : '');
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write('.');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }
}

/// Scheletro della lista: righe vuote alla stessa altezza di quelle vere.
class _WatchlistSkeleton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final page = ArSpace.page(context);

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        page.left,
        ArSpace.xs,
        page.right,
        ArSpace.xxl,
      ),
      itemCount: 6,
      itemBuilder: (context, _) => const Padding(
        padding: EdgeInsets.symmetric(vertical: ArSpace.xxs),
        child: Row(
          children: [
            SkeletonBox(width: 52, height: 52, radius: ArRadii.chip),
            SizedBox(width: ArSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SkeletonBox(height: 14),
                  SizedBox(height: ArSpace.xs),
                  SkeletonBox(height: 11, width: 120),
                ],
              ),
            ),
            SizedBox(width: ArSpace.sm),
            SkeletonBox(width: 88, height: 30, radius: ArRadii.chip),
          ],
        ),
      ),
    );
  }
}

/// Filtri per stato e per preferito.
///
/// Non una `TabBar` come nella classifica: qui i filtri non cambiano il
/// formato dei dati, solo quali righe si vedono, quindi spine dorsale con chip
/// e' piu' adatta e occupa una riga invece di due.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.status,
    required this.favoritesOnly,
    required this.onStatus,
    required this.onFavorites,
  });

  final WatchStatus? status;
  final bool favoritesOnly;
  final ValueChanged<WatchStatus?> onStatus;
  final ValueChanged<bool> onFavorites;

  @override
  Widget build(BuildContext context) {
    final page = ArSpace.page(context);

    // Altezza derivata dal passo del design system e non un numero scelto a
    // caso: chip da 32px (8 di padding verticale + 16 di riga) piu' due di aria
    // sopra e sotto arrivano esattamente a 48px.
    return SizedBox(
      height: ArSpace.xxl + ArSpace.xs,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(
          horizontal: page.left,
          vertical: ArSpace.xs,
        ),
        children: [
          ArChip(
            label: 'Tutti',
            selected: status == null && !favoritesOnly,
            onTap: () {
              onStatus(null);
              onFavorites(false);
            },
          ),
          const SizedBox(width: ArSpace.xs),
          ArChip(
            label: 'Preferiti',
            icon: Icons.star,
            iconColor: ArColors.favorite,
            selected: favoritesOnly,
            onTap: () => onFavorites(!favoritesOnly),
          ),
          const SizedBox(width: ArSpace.xs),
          // Il separatore sta fra i due gruppi di filtri: "Tutti" toglie
          // entrambi, gli altri sono indipendenti.
          for (final s in WatchStatus.displayOrder) ...[
            const SizedBox(width: ArSpace.xs),
            ArChip(
              label: s.label,
              icon: Icons.circle,
              iconColor: statusColor(s),
              selected: status == s && !favoritesOnly,
              // Rischedere lo stesso filtro lo deseleziona: con i chip
              // l'utente non ha un altro posto da premere per tornare a
              // vedere tutto, e "Tutti" in fondo alla riga si vede solo
              // scorrendo.
              onTap: () => onStatus(status == s && !favoritesOnly ? null : s),
            ),
          ],
        ],
      ),
    );
  }
}

/// Tabella della watchlist, da desktop in su.
///
/// Le intestazioni servono perche' "5 / 12" e "In visione" accanto non si
/// distinguono: senza intestazione la colonna episodi sembra una seconda
/// colonna di numeri senza significato.
class WatchlistTable extends ConsumerWidget {
  const WatchlistTable({required this.entries, required this.groupId, super.key});

  final List<WatchlistEntry> entries;
  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DataTable(
      headingRowColor: const WidgetStatePropertyAll(ArColors.containerHigh),
      // La colonna delle caselle sparisce: con `onSelectChanged` attivo la
      // `DataTable` la aggiunge da sola, e qui non si sceglie nulla — si apre
      // una scheda. Una colonna di caselle vuote sposterebbe a destra tutte
      // le colonne vere.
      showCheckboxColumn: false,
      columnSpacing: ArSpace.lg,
      headingRowHeight: 44,
      columns: const [
        DataColumn(label: Text('Anime')),
        DataColumn(label: Text('Stato')),
        DataColumn(label: Text('Episodi'), numeric: true),
        DataColumn(label: Text('Preferito')),
        DataColumn(label: Text('')),
      ],
      rows: [
        for (final entry in entries)
          DataRow(
            // La riga intera apre la scheda, come nella classifica: in una
            // tabella non c'e' un'area "titolino" da premere e costringere a
            // puntare il mouse al testo renderebbe la meta' della riga muta.
            onSelectChanged: (_) => _openDetail(context, entry),
            cells: [
              // Larghezza fissata perche' `DataTable` misura ogni colonna sul
              // contenuto: senza un tetto, un titolo lungo spingerebbe le
              // colonne dei numeri fuori dalla finestra.
              DataCell(
                SizedBox(
                  width: 340,
                  child: Row(
                    children: [
                      AnimeThumb(
                        url: entry.imageUrl,
                        title: entry.title,
                        size: 44,
                        radius: ArRadii.chip,
                      ),
                      const SizedBox(width: ArSpace.sm),
                      Expanded(child: _AnimeLine(entry: entry)),
                    ],
                  ),
                ),
              ),
              DataCell(_StatusMenu(entry: entry, groupId: groupId)),
              DataCell(_EpisodeButton(entry: entry, groupId: groupId)),
              DataCell(_FavoriteButton(entry: entry, groupId: groupId)),
              DataCell(
                IconButton(
                  tooltip: 'Rimuovi dalla watchlist',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _remove(context, ref, entry),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Future<void> _openDetail(BuildContext context, WatchlistEntry entry) {
    return context.push<void>(
      AppRoutes.animeDetail,
      extra: _animeOf(entry),
    );
  }

  Future<void> _remove(BuildContext context, WidgetRef ref, WatchlistEntry entry) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await _confirmRemove(context, entry.title);

    if (confirmed != true || !context.mounted) return;

    try {
      await ref.read(watchlistActionProvider.notifier).remove(
            groupId: entry.groupId.isEmpty ? groupId : entry.groupId,
            animeId: entry.animeId,
          );
      messenger.showSnackBar(SnackBar(content: Text('${entry.title} rimosso dalla watchlist.')));
    } on WatchlistFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

/// Riga della watchlist in formato scheda.
///
/// Da [LayoutSize.expanded] in su la stessa lista e' una tabella: vedi
/// [WatchlistTable]. Su schermo largo una riga a scheda con stato, episodi e
/// preferito lascia piu' spazio vuoto dei dati che mostra.
class WatchlistRow extends StatelessWidget {
  const WatchlistRow({
    required this.entry,
    required this.groupId,
    this.revealMs = 0,
    super.key,
  });

  final WatchlistEntry entry;
  final String groupId;

  /// Ritardo di comparsa, per l'onda della lista.
  final int revealMs;

  @override
  Widget build(BuildContext context) {
    final anime = _animeOf(entry);

    // La scheda e' l'involucro premibile e non la riga intera: il tocco
    // apre la scheda dell'opera, mentre stato, episodi e preferito hanno
    // gia' un controllo tutto loro e devono restare indipendenti. Un
    // `InkWell` su tutta la riga ruberebbe il tocco a quei tre pulsanti e
    // aprirebbe l'anime mentre l'utente credeva di cambiarne lo stato.
    final card = Container(
      margin: const EdgeInsets.symmetric(vertical: ArSpace.xxs),
      padding: const EdgeInsets.all(ArSpace.sm),
      decoration: BoxDecoration(
        color: ArColors.container,
        borderRadius: BorderRadius.circular(ArRadii.card),
        // Filetto colorato sullo stato: su fondo scuro un bordo neutro fa
        // sparire le righe una dentro l'altra, e il colore qui non e'
        // decorazione — e' la stessa informazione del pallino.
        border: Border.all(
          color: statusColor(entry.status).withValues(alpha: 0.16),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              AnimeThumb(
                url: entry.imageUrl,
                title: entry.title,
                size: 52,
                radius: ArRadii.chip,
                heroTag: anime.heroTag,
              ),
              const SizedBox(width: ArSpace.sm),
              Expanded(child: _AnimeLine(entry: entry)),
              const SizedBox(width: ArSpace.xs),
              _FavoriteButton(entry: entry, groupId: groupId),
              _OverflowMenu(entry: entry, groupId: groupId),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: ArSpace.xs),
            child: Row(
              children: [
                _StatusChip(entry: entry, groupId: groupId),
                const Spacer(),
                _EpisodeButton(entry: entry, groupId: groupId),
              ],
            ),
          ),
          if (entry.progress != null)
            Padding(
              padding: const EdgeInsets.only(top: ArSpace.xs),
              child: _ProgressBar(value: entry.progress!, color: statusColor(entry.status)),
            ),
        ],
      ),
    );

    return ArReveal(
      delayMs: revealMs,
      child: ArPressable(
        onTap: () => context.push(AppRoutes.animeDetail, extra: anime),
        child: card,
      ),
    );
  }
}

/// Barra di avanzamento sugli episodi.
///
/// La traccia resta in un colore spento perche' e' il massimo possibile, e il
/// riempimento prende il colore dello stato: e' la stessa informazione del
/// pallino, ripetuta in forma di lunghezza.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.value, required this.color});

  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(ArSpace.xxs),
      child: LinearProgressIndicator(
        value: value,
        minHeight: ArSpace.xxs,
        valueColor: AlwaysStoppedAnimation(color),
        backgroundColor: ArColors.containerHighest,
      ),
    );
  }
}

/// Nome, episodi e stato di una voce.
///
/// Lo stato e' qui dentro e non solo nel menu: e' l'informazione principale di
/// una watchlist, e chiedere un tocco per sapere se un anime e' finito o
/// abbandonato significa non poterla usare come lista.
class _AnimeLine extends StatelessWidget {
  const _AnimeLine({required this.entry});

  final WatchlistEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = entry.meta;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          entry.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall,
        ),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: ArSpace.xxs),
          Text(
            meta,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: ArColors.textMid),
          ),
        ],
      ],
    );
  }
}

/// Voci dei menu che cambiano lo stato.
///
/// Un posto solo per i cinque stati: le tre versioni del menu (chip di riga,
/// colonna della tabella, menu di overflow) hanno la stessa lista e cambiano
/// solo l'involucro, quindi elencare gli stati in tre posti lascerebbe fuori un
/// passaggio dall'uno all'altro.
///
/// Il testo e' dentro un `Expanded` con troncamento: un menu popup non e' piu'
/// largo di 280px e una voce lunga in un font largo ("Rimuovi dalla watchlist"
/// in un test, dove ogni carattere e' largo quanto il font) uscirebbe dai
/// bordi invece di andare a capo.
List<PopupMenuItem<String>> _statusItems(WatchStatus current) => [
      for (final status in WatchStatus.displayOrder)
        PopupMenuItem<String>(
          value: status.wire,
          child: Row(
            children: [
              Icon(
                status == current ? Icons.check : Icons.circle_outlined,
                size: 18,
                color: statusColor(status),
              ),
              const SizedBox(width: ArSpace.sm),
              Expanded(
                child: Text(
                  status.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
    ];

/// Salva il nuovo stato e segnala l'errore se il backend lo rifiuta.
///
/// Le tre copie del menu chiamano questa funzione invece di ripetere il
/// `try/catch`: un messaggio d'errore mostrato in un punto e non in un altro
/// e' il tipo di difetto che si nota solo quando succede.
Future<void> _saveStatus(
  BuildContext context,
  WidgetRef ref, {
  required String groupId,
  required String animeId,
  required WatchStatus status,
}) async {
  final messenger = ScaffoldMessenger.of(context);

  try {
    await ref.read(watchlistActionProvider.notifier).setStatus(
          groupId: groupId,
          animeId: animeId,
          status: status,
        );
  } on WatchlistFailure catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
}

/// Pallino con lo stato, che apre il menu per cambiarlo.
///
/// Nella riga a scheda lo stato e' un elemento cliccabile con la sua
/// etichetta: e' l'informazione principale di una watchlist e deve potersi
/// cambiare senza aprire prima un altro menu.
///
/// La stessa [ArChip] dei filtri, con la freccia: condividere il componente
/// fa si che una pastiglia cambiata qui non resti indietro rispetto a quella
/// sopra, e il raggio e' quello di tutto il resto.
class _StatusChip extends ConsumerWidget {
  const _StatusChip({required this.entry, required this.groupId});

  final WatchlistEntry entry;
  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      tooltip: 'Cambia stato',
      initialValue: entry.status.wire,
      onSelected: (value) => _saveStatus(
        context,
        ref,
        groupId: groupId,
        animeId: entry.animeId,
        status: WatchStatus.fromWire(value),
      ),
      itemBuilder: (context) => _statusItems(entry.status),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: ArSpace.sm,
          vertical: ArSpace.xs,
        ),
        decoration: BoxDecoration(
          color: statusColor(entry.status).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(ArRadii.chip),
          border: Border.all(
            color: statusColor(entry.status).withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: statusColor(entry.status),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: ArSpace.xs),
            // Troncato e non fisso: la colonna della tabella si stringe quando
            // le colonne dei numeri hanno piu' cifre, e un'etichetta che esce
            // dalla cella sposta tutte le colonne invece di accorciarsi.
            Flexible(
              child: Text(
                entry.status.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: ArColors.textHigh,
                    ),
              ),
            ),
            const SizedBox(width: ArSpace.xxs),
            Icon(Icons.arrow_drop_down, size: 18, color: ArColors.textLow),
          ],
        ),
      ),
    );
  }
}

/// Versione del cambio stato per la tabella.
///
/// Nella tabella non c'e' spazio per il pallino con l etichetta, quindi il
/// bottone e un pallino colorato: stesso menu [_statusItems], un elemento in
/// meno da leggere.
class _StatusMenu extends ConsumerWidget {
  const _StatusMenu({required this.entry, required this.groupId});

  final WatchlistEntry entry;
  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      tooltip: 'Cambia stato',
      initialValue: entry.status.wire,
      onSelected: (value) => _saveStatus(
        context,
        ref,
        groupId: groupId,
        animeId: entry.animeId,
        status: WatchStatus.fromWire(value),
      ),
      itemBuilder: (context) => _statusItems(entry.status),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: ArSpace.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: statusColor(entry.status),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: ArSpace.xs),
            Flexible(
              child: Text(
                entry.status.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const SizedBox(width: ArSpace.xxs),
            const Icon(Icons.arrow_drop_down, size: 20, color: ArColors.textLow),
          ],
        ),
      ),
    );
  }
}

/// Contrassegno di preferito.
class _FavoriteButton extends ConsumerWidget {
  const _FavoriteButton({required this.entry, required this.groupId});

  final WatchlistEntry entry;
  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messenger = ScaffoldMessenger.of(context);
    final busy = ref.watch(watchlistActionProvider).isLoading;

    return IconButton(
      tooltip: entry.isFavorite ? 'Togli dai preferiti' : 'Metti tra i preferiti',
      icon: Icon(
        entry.isFavorite ? Icons.star : Icons.star_border,
        color: entry.isFavorite ? ArColors.favorite : ArColors.textLow,
      ),
      onPressed: busy
          ? null
          : () async {
              try {
                await ref.read(watchlistActionProvider.notifier).setFavorite(
                      groupId: groupId,
                      animeId: entry.animeId,
                      isFavorite: !entry.isFavorite,
                    );
              } on WatchlistFailure catch (e) {
                messenger.showSnackBar(SnackBar(content: Text(e.message)));
              }
            },
    );
  }
}

/// Episodi guardati, con il foglio per cambiarli.
class _EpisodeButton extends ConsumerWidget {
  const _EpisodeButton({required this.entry, required this.groupId});

  final WatchlistEntry entry;
  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TextButton.icon(
      onPressed: () => _open(context, ref),
      icon: const Icon(Icons.playlist_add_check, size: 18),
      label: Text(entry.episodeLabel),
      style: TextButton.styleFrom(
        foregroundColor: entry.hasStarted ? ArColors.primary : ArColors.textLow,
      ),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final episode = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => EpisodeSheet(entry: entry),
    );

    if (episode == null || !context.mounted) return;

    try {
      await ref.read(watchlistActionProvider.notifier).setEpisode(
            groupId: groupId,
            animeId: entry.animeId,
            episode: episode,
          );
      messenger.showSnackBar(SnackBar(content: Text('Episodi aggiornati a $episode.')));
    } on WatchlistFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

/// Menu con le azioni meno frequenti.
///
/// Stato, episodi e preferito hanno gia' un posto fisso nella riga; qui finiscono
/// solo le azioni che non devono stare in vista per non rubare spazio ai dati.
class _OverflowMenu extends ConsumerWidget {
  const _OverflowMenu({required this.entry, required this.groupId});

  final WatchlistEntry entry;
  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      tooltip: 'Altre azioni',
      onSelected: (value) {
        if (value == 'remove') {
          _remove(context, ref);
          return;
        }

        _saveStatus(
          context,
          ref,
          groupId: groupId,
          animeId: entry.animeId,
          status: WatchStatus.fromWire(value),
        );
      },
      itemBuilder: (context) => [
        const PopupMenuItem<String>(
          enabled: false,
          child: Text('Cambia stato'),
        ),
        ..._statusItems(entry.status),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: 'remove',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 18),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Rimuovi dalla watchlist',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await _confirmRemove(context, entry.title);

    if (confirmed != true || !context.mounted) return;

    try {
      await ref.read(watchlistActionProvider.notifier).remove(
            groupId: groupId,
            animeId: entry.animeId,
          );
      messenger.showSnackBar(
        SnackBar(content: Text('${entry.title} rimosso dalla watchlist.')),
      );
    } on WatchlistFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

/// Conferma prima di togliere una voce.
///
/// La rimozione e' definitiva e non si annulla: senza conferma un tocco su una
/// riga lunga da 44px su un telefono perde il lavoro di mesi di episodi.
Future<bool?> _confirmRemove(BuildContext context, String title) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Rimuovere dalla watchlist?'),
      content: Text(
        'La voce di $title sparisce, con gli episodi segnati. '
        'Gli altri membri del gruppo non vedono la tua watchlist, quindi nessuno '
        'perde niente.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Annulla'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Rimuovi'),
        ),
      ],
    ),
  );
}

/// Foglio per gli episodi guardati.
///
/// Due pulsanti e un cursore quando il totale e noto, solo due pulsanti quando
/// non lo e': un cursore con un massimo inventato (perche' di 500 episodi?) fa
/// scegliere un numero senza significato.
class EpisodeSheet extends StatefulWidget {
  const EpisodeSheet({required this.entry, super.key});

  final WatchlistEntry entry;

  @override
  State<EpisodeSheet> createState() => _EpisodeSheetState();
}

class _EpisodeSheetState extends State<EpisodeSheet> {
  late int _episode = widget.entry.currentEpisode;
  String? _error;

  int get _total => widget.entry.episodes ?? 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _total;
    final page = ArSpace.page(context);

    return Padding(
      padding: EdgeInsets.only(
        left: page.left,
        right: page.right,
        top: ArSpace.lg,
        // Il margine inferiore segue la tastiera: senza, il foglio coprirebbe
        // il cursore e i due pulsanti proprio mentre si sta scegliendo il
        // numero.
        bottom: MediaQuery.viewInsetsOf(context).bottom + ArSpace.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Episodi guardati', style: theme.textTheme.titleLarge),
          const SizedBox(height: ArSpace.xxs),
          Text(
            widget.entry.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: ArColors.textMid),
          ),
          const SizedBox(height: ArSpace.lg),
          Row(
            children: [
              IconButton.filledTonal(
                onPressed: _episode > 0 ? () => _change(_episode - 1) : null,
                icon: const Icon(Icons.remove),
                tooltip: 'Un episodio in meno',
              ),
              Expanded(
                child: Center(
                  child: Text(
                    total > 0 ? '$_episode / $total' : '$_episode',
                    style: theme.textTheme.headlineSmall,
                  ),
                ),
              ),
              IconButton.filledTonal(
                // Il massimo e' il totale solo quando e' noto: con `episodes` a
                // null non c'e' un limite da rispettare e bloccare il pulsone
                // farebbe sembrare l anime senza dati, quando invece e' solo un
                // anime ancora in corso senza numero di episodi.
                onPressed: total > 0 && _episode >= total ? null : () => _change(_episode + 1),
                icon: const Icon(Icons.add),
                tooltip: 'Un episodio in piu',
              ),
            ],
          ),
          if (total > 0) ...[
            const SizedBox(height: ArSpace.xs),
            Slider(
              value: _episode.toDouble().clamp(0, total.toDouble()),
              max: total.toDouble(),
              divisions: total > 1 ? total : null,
              label: '$_episode',
              onChanged: (value) => setState(() {
                _episode = value.round();
                _error = null;
              }),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: ArSpace.xs),
              child: AuthErrorBanner.error(_error!),
            ),
          const SizedBox(height: ArSpace.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Annulla'),
              ),
              const SizedBox(width: ArSpace.xs),
              FilledButton(
                // Disabilitato invece che fallire al salvataggio: l errore
                // arrival comunque dal backend, qui serve a non far perdere il
                // numero scelto a chi ha spinto oltre.
                onPressed: _error == null ? () => Navigator.of(context).pop(_episode) : null,
                child: const Text('Salva'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _change(int value) {
    setState(() {
      _episode = value;
      _error = WatchlistValidators.episodeError(episode: value, total: _totalOrNull);
    });
  }

  int? get _totalOrNull => widget.entry.episodes;
}

/// Foglio per aggiungere anime dalla classifica del gruppo.
///
/// La classifica e' l'unico elenco di anime che il gruppo ha gia' incontrato,
/// quindi aggiungere da li' evita di dover cercare il titolo in un catalogo e
/// evita anime che nessuno ha mai visto.
///
/// Uno stato locale per gli appena aggiunti: la lista ricaricherebbe la
/// watchlist a ogni inserimento e per un istante i pallini "gia aggiunto"
/// sparirebbero, facendo sembrare che l'aggiunta non sia avvenuta.
class AddFromRankingSheet extends ConsumerStatefulWidget {
  const AddFromRankingSheet({required this.groupId, super.key});

  final String groupId;

  @override
  ConsumerState<AddFromRankingSheet> createState() => _AddFromRankingSheetState();
}

class _AddFromRankingSheetState extends ConsumerState<AddFromRankingSheet> {
  final Set<String> _added = {};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final page = ArSpace.page(context);
    final ranking = ref.watch(rankingProvider(widget.groupId));
    final existing = {
      for (final e in ref.watch(watchlistProvider(widget.groupId)).value ?? const [])
        e.animeId,
    };

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (context, scrollController) {
        return DecoratedBox(
          decoration: const BoxDecoration(
            color: ArColors.containerHigh,
            borderRadius: BorderRadius.vertical(top: Radius.circular(ArRadii.sheet)),
          ),
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  page.left,
                  ArSpace.md,
                  page.right,
                  ArSpace.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Aggiungi dalla classifica',
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: ArSpace.xxs),
                    Text(
                      'Gli anime che il gruppo ha gia votato. Aggiungerne uno lo '
                      'mette in visione.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: ArColors.textMid,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ranking.when(
                  // Scheletro di righe, non girone: la lista e' di una riga
                  // sola con due pezzi di testo, e uno scheletro a cassettoni
                  // farebbe saltare il foglio al primo arrivo dei dati.
                  loading: () => ListView.builder(
                    padding: EdgeInsets.symmetric(
                      horizontal: page.left,
                      vertical: ArSpace.xs,
                    ),
                    itemCount: 7,
                    itemBuilder: (context, _) => const Padding(
                      padding: EdgeInsets.symmetric(vertical: ArSpace.xs),
                      child: Row(
                        children: [
                          SkeletonBox(width: 40, height: 40, radius: ArRadii.chip),
                          SizedBox(width: ArSpace.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SkeletonBox(height: 14),
                                SizedBox(height: ArSpace.xs),
                                SkeletonBox(height: 11, width: 90),
                              ],
                            ),
                          ),
                          SizedBox(width: ArSpace.sm),
                          SkeletonBox(width: 32, height: 32, radius: ArRadii.chip),
                        ],
                      ),
                    ),
                  ),
                  error: (error, _) => ErrorState(
                    message: '$error',
                    onRetry: () =>
                        ref.read(rankingProvider(widget.groupId).notifier).refresh(),
                  ),
                  data: (rows) {
                    if (rows.isEmpty) {
                      return const EmptyState(
                        icon: Icons.leaderboard_outlined,
                        title: 'La classifica del gruppo e vuota.',
                        message: 'Servono anime votati prima di poterli aggiungere.',
                      );
                    }

                    return ListView.builder(
                      controller: scrollController,
                      padding: EdgeInsets.symmetric(
                        horizontal: page.left,
                        vertical: ArSpace.xs,
                      ),
                      itemCount: rows.length,
                      itemBuilder: (context, i) {
                        final row = rows[i];
                        final already = existing.contains(row.animeId) ||
                            _added.contains(row.animeId);

                        return ListTile(
                          leading: AnimeThumb(url: row.imageUrl, title: row.title),
                          title: Text(
                            row.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text('#${row.position} · ${row.meanScoreLabel ?? '-'}'),
                          trailing: already
                              ? const Icon(Icons.check_circle, color: ArColors.completed)
                              : IconButton(
                                  tooltip: 'Aggiungi ${row.title}',
                                  icon: const Icon(Icons.add_circle_outline),
                                  onPressed: () => _add(row.animeId, row.title),
                                ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _add(String animeId, String title) async {
    final messenger = ScaffoldMessenger.of(context);

    try {
      await ref.read(watchlistActionProvider.notifier).setStatus(
            groupId: widget.groupId,
            animeId: animeId,
            status: WatchStatus.watching,
          );

      if (!mounted) return;
      setState(() => _added.add(animeId));
      messenger.showSnackBar(SnackBar(content: Text('$title aggiunto in visione.')));
    } on WatchlistFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}