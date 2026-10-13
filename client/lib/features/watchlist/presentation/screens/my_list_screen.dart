import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/anime_thumb.dart';
import '../../../../core/ui/content_row.dart';
import '../../../../core/ui/section_header.dart';
import '../../../anime/domain/anime.dart';
import '../../../anime/presentation/anime_controller.dart';
import '../../../episodes/presentation/episode_sync_controller.dart';
import '../../domain/watchlist.dart';
import '../watchlist_controller.dart';
import 'watchlist_screen.dart';

/// "La mia lista": la watchlist personale dell'utente.
///
/// A differenza della watchlist di un gruppo, questa non e' condivisa: raccoglie
/// solo cio' che l'utente segue per conto suo, senza passare da un gruppo. La
/// watchlist condivisa di un gruppo sta invece nella scheda del gruppo, dove
/// compaiono anche le voci consigliate dagli altri membri.
class MyListScreen extends ConsumerStatefulWidget {
  const MyListScreen({super.key});

  @override
  ConsumerState<MyListScreen> createState() => _MyListScreenState();
}

class _MyListScreenState extends ConsumerState<MyListScreen> {
  /// Il riallineamento parte una volta per apertura, non a ogni ridisegno.
  bool _synced = false;

  @override
  void initState() {
    super.initState();

    // Quando la lista personale e' pronta si chiedono al provider gli episodi
    // nuovi degli anime seguiti: e' da qui che nascono le notifiche "nuovo
    // episodio", ed e' l'unico posto dove la domanda ha senso farla (il
    // telefono parla con AnimeUnity, il datacenter no). La richiesta e' in
    // secondo piano: la lista compare subito.
    ref.listenManual(
      myListProvider,
      (_, next) => _syncIfReady(next),
      fireImmediately: true,
    );
  }

  void _syncIfReady(AsyncValue<List<WatchlistEntry>> value) {
    if (_synced) return;

    final entries = value.value;
    if (entries == null) return;
    _synced = true;

    // Ordine e tetto li decide il controller (in onda per primi, poi i piu'
    // recenti): qui si passa la lista che la schermata ha gia' caricato, cosi'
    // non si rifa' la stessa richiesta.
    unawaited(ref.read(episodeSyncProvider).syncWatchlist(entries: entries));
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(myListProvider);

    return Scaffold(
      backgroundColor: ArColors.bg,
      appBar: AppBar(
        title: const Text('La mia lista'),
        actions: [
          IconButton(
            tooltip: 'Aggiorna',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () {
              // A mano si vuole anche l'ultimo episodio, non solo le voci: il
              // giro d'insieme si forza perche' la sessione potrebbe averlo
              // gia' fatto all'avvio.
              _synced = false;
              unawaited(ref.read(episodeSyncProvider).syncWatchlist(force: true));
              ref.read(myListProvider.notifier).refresh();
            },
          ),
        ],
      ),
      floatingActionButton: list.hasValue
          ? FloatingActionButton.extended(
              onPressed: () => _add(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('Aggiungi'),
              backgroundColor: ArColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(ArRadii.control),
              ),
            )
          : null,
      body: switch (list) {
        AsyncLoading() => const Center(child: CircularProgressIndicator()),
        AsyncError(:final error) => ErrorState(
            message: '$error',
            onRetry: () => ref.read(myListProvider.notifier).refresh(),
          ),
        AsyncData(:final value) => _Body(entries: value),
      },
    );
  }

  /// Apre la ricerca per aggiungere un anime alla lista personale.
  ///
  /// Non passa da un gruppo: la lista personale e' di chi la usa, e obbligare a
  /// scegliere un gruppo prima di poterci mettere un titolo significava non
  /// poterla riempire affatto senza un gruppo. La ricerca parte dal catalogo e,
  /// se non trova, puo' interrogare quello esterno.
  Future<void> _add(BuildContext context, WidgetRef ref) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _AddToPersonalSheet(),
    );
  }
}

/// Ricerca per aggiungere un anime alla lista personale.
///
/// Un campo di ricerca e i risultati, senza il passaggio dal gruppo. Cerca prima
/// nel catalogo; se non trova nulla offre la ricerca online, con lo stesso
/// criterio della ricerca principale: prima il locale, poi — su richiesta —
/// l'esterno.
class _AddToPersonalSheet extends ConsumerStatefulWidget {
  const _AddToPersonalSheet();

  @override
  ConsumerState<_AddToPersonalSheet> createState() => _AddToPersonalSheetState();
}

class _AddToPersonalSheetState extends ConsumerState<_AddToPersonalSheet> {
  final TextEditingController _field = TextEditingController();

  /// Id appena aggiunti in questa sessione del foglio: la lista personale si
  /// ricarica in secondo piano, ma la riga deve sparire subito dal risultato.
  final Set<String> _added = {};

  List<AnimeEntry> _results = const [];
  bool _loading = false;
  bool _triedRemote = false;
  String _query = '';
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _search({bool remote = false}) async {
    final query = _field.text.trim();
    if (query.isEmpty) {
      setState(() => _error = 'Scrivi il titolo di un anime.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    final repository = ref.read(animeRepositoryProvider);
    try {
      final page = remote
          ? await repository.searchRemote(query)
          : await repository.searchLocal(query);

      if (!mounted) return;
      setState(() {
        _results = page.results;
        _query = query;
        if (remote) _triedRemote = true;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error =
            error is AppFailure ? error.message : 'Ricerca non riuscita. Riprova.';
      });
    }
  }

  Future<void> _add(AnimeEntry entry) async {
    final animeId = entry.id;
    final messenger = ScaffoldMessenger.of(context);

    // Un risultato del catalogo esterno arriva senza id interno finche' la cache
    // non lo ha scritto: senza id non c'e' riga da inserire. Lo si dice invece
    // di far fallire la scrittura con un errore tecnico.
    if (animeId == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Questo titolo non e\' ancora in catalogo: riprova tra un momento.',
          ),
        ),
      );
      return;
    }

    try {
      await ref.read(watchlistActionProvider.notifier).setStatus(
            animeId: animeId,
            status: WatchStatus.watching,
          );

      if (!mounted) return;
      setState(() => _added.add(animeId));
      messenger.showSnackBar(
        SnackBar(content: Text('${entry.displayTitle} aggiunto in visione.')),
      );
    } on WatchlistFailure catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final page = ArSpace.page(context);
    final media = MediaQuery.of(context);

    final existing = {
      for (final entry
          in ref.watch(myListProvider).value ?? const <WatchlistEntry>[])
        entry.animeId,
    };

    return Padding(
      // Il foglio sale sopra la tastiera: senza, il campo in cui si scrive
      // resterebbe dietro di essa.
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SafeArea(
        child: ConstrainedBox(
          // Si adatta al contenuto finche' e' corto e si ferma a una frazione
          // dello schermo quando i risultati crescono.
          constraints: BoxConstraints(maxHeight: media.size.height * 0.82),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  page.left,
                  ArSpace.md,
                  page.right,
                  ArSpace.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Aggiungi alla mia lista',
                        style: theme.textTheme.titleLarge),
                    const SizedBox(height: ArSpace.xxs),
                    Text(
                      'Cerca un anime e mettilo in visione. La lista personale '
                      'non ha bisogno di un gruppo.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: ArColors.textMid,
                      ),
                    ),
                    const SizedBox(height: ArSpace.md),
                    TextField(
                      controller: _field,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _search(),
                      decoration: InputDecoration(
                        hintText: 'Titolo dell\'anime',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _loading
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                ),
                              )
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(child: _body(context, existing)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, Set<String> existing) {
    final theme = Theme.of(context);
    final page = ArSpace.page(context);

    if (_error != null) {
      return Padding(
        padding: EdgeInsets.all(page.left),
        child: Text(_error!, style: theme.textTheme.bodyMedium),
      );
    }

    if (_query.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(page.left),
        child: Text(
          'Scrivi almeno una parola e premi invio.',
          style: theme.textTheme.bodySmall?.copyWith(color: ArColors.textMid),
        ),
      );
    }

    if (_results.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(page.left),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Nessun risultato in catalogo per "$_query".',
              style: theme.textTheme.bodyMedium,
            ),
            if (!_triedRemote) ...[
              const SizedBox(height: ArSpace.sm),
              OutlinedButton.icon(
                onPressed: () => _search(remote: true),
                icon: const Icon(Icons.cloud_download_outlined),
                label: const Text('Cerca online'),
              ),
            ],
          ],
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      padding: EdgeInsets.symmetric(horizontal: page.left, vertical: ArSpace.xs),
      itemCount: _results.length,
      itemBuilder: (context, i) {
        final entry = _results[i];
        final already = entry.id != null &&
            (existing.contains(entry.id) || _added.contains(entry.id));

        return ListTile(
          leading: AnimeThumb(url: entry.imageUrl, title: entry.displayTitle),
          title: Text(
            entry.displayTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(entry.factsLabel.isEmpty ? '—' : entry.factsLabel),
          trailing: already
              ? const Icon(Icons.check_circle, color: ArColors.completed)
              : IconButton(
                  tooltip: 'Aggiungi ${entry.displayTitle}',
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: () => _add(entry),
                ),
        );
      },
    );
  }
}

/// Corpo della lista, con la striscia dei totali e i filtri.
class _Body extends StatefulWidget {
  const _Body({required this.entries});

  final List<WatchlistEntry> entries;

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  WatchStatus? _status;
  bool _favoritesOnly = false;

  @override
  Widget build(BuildContext context) {
    final all = widget.entries;
    final visible = _visible(all);

    return RefreshIndicator(
      onRefresh: () => _refresh(context),
      child: Column(
        children: [
          if (all.isNotEmpty) _TotalsStrip(totals: _totals(all)),
          _MyFilterBar(
            status: _status,
            favoritesOnly: _favoritesOnly,
            onStatus: (value) => setState(() => _status = value),
            onFavorites: (value) => setState(() => _favoritesOnly = value),
          ),
          const Divider(height: 1),
          Expanded(
            child: visible.isEmpty ? _empty() : _list(visible),
          ),
        ],
      ),
    );
  }

  Future<void> _refresh(BuildContext context) {
    return ProviderScope.containerOf(context).read(myListProvider.notifier).refresh();
  }

  Widget _list(List<WatchlistEntry> entries) {
    final horizontal = ArSpace.page(context).left;

    // Una colonna sola con un tetto di larghezza: su schermo largo una riga
    // distesa su tutta la pagina renderebbe difficile seguire titolo, stato ed
    // episodi.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: EdgeInsets.fromLTRB(horizontal, ArSpace.xs, horizontal, ArSpace.xxl),
          children: [
            if (_status != null || _favoritesOnly)
              for (final (i, entry) in entries.indexed)
                WatchlistRow(entry: entry, revealMs: _delayOf(i))
            else
              ..._byStatus(entries),
          ],
        ),
      ),
    );
  }

  List<Widget> _byStatus(List<WatchlistEntry> entries) {
    final widgets = <Widget>[];
    var seen = 0;

    for (final status in WatchStatus.displayOrder) {
      final rows = entries.where((e) => e.status == status).toList();
      if (rows.isEmpty) continue;

      widgets.add(
        Padding(
          padding: const EdgeInsets.only(top: ArSpace.md, bottom: ArSpace.xs),
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
                child: Text(status.label, style: Theme.of(context).textTheme.titleSmall),
              ),
              MetricLabel('${rows.length}'),
            ],
          ),
        ),
      );

      for (final entry in rows) {
        widgets.add(WatchlistRow(entry: entry, revealMs: _delayOf(seen++)));
      }
    }

    return widgets;
  }

  List<WatchlistEntry> _visible(List<WatchlistEntry> all) {
    final filtered = all
        .where((e) => _status == null || e.status == _status)
        .where((e) => !_favoritesOnly || e.isFavorite)
        .toList();

    if (_status != null || _favoritesOnly) {
      filtered.sort(
        (a, b) => a.displayTitle.toLowerCase().compareTo(b.displayTitle.toLowerCase()),
      );
    }

    return filtered;
  }

  WatchlistTotals _totals(List<WatchlistEntry> entries) {
    var watching = 0, completed = 0, dropped = 0, favorites = 0, episodes = 0;

    for (final entry in entries) {
      switch (entry.status) {
        case WatchStatus.watching:
          watching++;
        case WatchStatus.completed:
          completed++;
        case WatchStatus.dropped:
          dropped++;
        case WatchStatus.planned:
        case WatchStatus.paused:
          break;
      }
      if (entry.isFavorite) favorites++;
      if (entry.status == WatchStatus.watching ||
          entry.status == WatchStatus.completed) {
        episodes += entry.currentEpisode;
      }
    }

    return WatchlistTotals(
      entries: entries.length,
      watching: watching,
      completed: completed,
      dropped: dropped,
      favorites: favorites,
      episodes: episodes,
      hours: episodes * 0.75,
    );
  }

  Widget _empty() {
    if (_favoritesOnly) {
      return const EmptyState(
        icon: Icons.star_border,
        title: 'Nessun preferito.',
        message: 'Segna un anime con la stella per ritrovarlo qui.',
      );
    }
    if (_status != null) {
      return EmptyState(
        icon: Icons.bookmark_border,
        title: 'Nessun anime in stato ${_status!.label.toLowerCase()}.',
        message: 'Cambia filtro o aggiungi un anime alla lista.',
      );
    }
    return const EmptyState(
      icon: Icons.bookmark_border,
      title: 'La tua lista e vuota.',
      message: 'Aggiungi un anime: la lista personale raccoglie quello che '
          'segui per conto tuo, senza passare da un gruppo.',
    );
  }

  static int _delayOf(int index) => (index * 30).clamp(0, 320);
}

/// Striscia con i totali complessivi.
class _TotalsStrip extends StatelessWidget {
  const _TotalsStrip({required this.totals});

  final WatchlistTotals totals;

  @override
  Widget build(BuildContext context) {
    final page = ArSpace.page(context);

    return DecoratedBox(
      decoration: const BoxDecoration(
        color: ArColors.containerLow,
        border: Border(bottom: BorderSide(color: ArColors.borderSoft)),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: page.left, vertical: ArSpace.sm),
        child: Row(
          children: [
            _Stat(label: 'In lista', value: totals.entries),
            _Stat(label: 'In visione', value: totals.watching),
            _Stat(label: 'Completati', value: totals.completed),
            _Stat(label: 'Episodi', value: totals.episodes),
          ],
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
            '$value',
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
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

/// Filtri per stato e preferito.
class _MyFilterBar extends StatelessWidget {
  const _MyFilterBar({
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

    return SizedBox(
      height: ArSpace.xxl + ArSpace.xs,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: page.left, vertical: ArSpace.xs),
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
          for (final s in WatchStatus.displayOrder) ...[
            const SizedBox(width: ArSpace.xs),
            ArChip(
              label: s.label,
              icon: Icons.circle,
              iconColor: statusColor(s),
              selected: status == s && !favoritesOnly,
              onTap: () => onStatus(status == s && !favoritesOnly ? null : s),
            ),
          ],
        ],
      ),
    );
  }
}
