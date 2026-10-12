import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/content_row.dart';
import '../../../../core/ui/section_header.dart';
import '../../../groups/domain/group.dart';
import '../../../groups/presentation/groups_controller.dart';
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

    // Solo gli anime ancora aperti: un'opera completata o droppata non riceve
    // episodi nuovi, e rileggerla sarebbe una richiesta per niente.
    final ids = [
      for (final entry in entries)
        if (entry.status != WatchStatus.completed &&
            entry.status != WatchStatus.dropped)
          entry.animeId,
    ];
    if (ids.isEmpty) return;

    unawaited(ref.read(episodeSyncProvider).syncFollowed(ids));
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
              // A mano si vuole anche l'ultimo episodio, non solo le voci.
              _synced = false;
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

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final groups = ref.read(groupsListProvider).value ?? const <AnimeGroup>[];

    if (groups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Crea un gruppo per aggiungere anime alla lista.')),
      );
      return;
    }

    // La lista personale non ha una classifica propria da cui pescare: si usa
    // quella di un gruppo come suggerimento, ma l'aggiunta resta personale.
    final chosen = groups.length == 1
        ? groups.first
        : await showModalBottomSheet<AnimeGroup>(
            context: context,
            showDragHandle: true,
            builder: (context) => _GroupChooser(groups: groups),
          );

    if (chosen == null || !context.mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AddFromRankingSheet(groupId: chosen.id, personal: true),
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

/// Scelta del gruppo da cui pescare gli anime da aggiungere.
///
/// La lista personale non ha una classifica propria: si usa quella di un
/// gruppo come suggerimento. Con un gruppo solo non compare.
class _GroupChooser extends StatelessWidget {
  const _GroupChooser({required this.groups});

  final List<AnimeGroup> groups;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(ArSpace.md),
            child: Text('Da quale gruppo pesco i titoli?', style: theme.textTheme.titleMedium),
          ),
          for (final group in groups)
            ListTile(
              leading: const Icon(Icons.groups_outlined),
              title: Text(group.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.of(context).pop(group),
            ),
          const SizedBox(height: ArSpace.sm),
        ],
      ),
    );
  }
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
