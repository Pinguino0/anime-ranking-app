import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../auth/presentation/widgets/auth_scaffold.dart';
import '../../../../core/constants/breakpoints.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../ranking/presentation/ranking_controller.dart';
import '../../../ranking/presentation/screens/ranking_screen.dart';
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
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => _ErrorState(
                message: '$error',
                onRetry: () => ref.read(watchlistProvider(groupId).notifier).refresh(),
              ),
              // Il filtro e' applicato anche quando non c'e' niente da
              // mostrare: con il filtro attivo l elenco vuoto e' la risposta
              // ("non hai preferiti"), non un caricamento da rifare.
              data: (_) => entries.isEmpty
                  ? _EmptyState(
                      message: _emptyMessage,
                      hint: _emptyHint,
                    )
                  : Breakpoints.fromContext(context).isExpanded
                      ? RefreshIndicator(
                          onRefresh: () =>
                              ref.read(watchlistProvider(groupId).notifier).refresh(),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: WatchlistTable(entries: entries, groupId: groupId),
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: () =>
                              ref.read(watchlistProvider(groupId).notifier).refresh(),
                          child: ListView(
                            padding: const EdgeInsets.only(bottom: 24),
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
    final theme = Theme.of(context);

    if (_status != null || _favoritesOnly) {
      return [
        for (final entry in entries) WatchlistRow(entry: entry, groupId: widget.groupId),
      ];
    }

    final widgets = <Widget>[];

    for (final status in WatchStatus.displayOrder) {
      final rows = entries.where((e) => e.status == status).toList();
      if (rows.isEmpty) continue;

      widgets.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
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
              const SizedBox(width: 8),
              Text(status.label, style: theme.textTheme.titleSmall),
              const SizedBox(width: 6),
              Text(
                '${rows.length}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );

      widgets.addAll([
        for (final entry in rows) WatchlistRow(entry: entry, groupId: widget.groupId),
      ]);
    }

    return widgets;
  }

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

/// Cifre della watchlist, in alto.
class _TotalsStrip extends StatelessWidget {
  const _TotalsStrip({required this.totals});

  final WatchlistTotals totals;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: SafeArea(
          top: false,
          bottom: false,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _Stat(label: 'In watchlist', value: '${totals.entries}'),
              _Stat(label: 'In visione', value: '${totals.watching}'),
              _Stat(label: 'Completati', value: '${totals.completed}'),
              _Stat(label: 'Episodi', value: '${totals.episodes}'),
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
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          ChoiceChip(
            label: const Text('Tutti'),
            selected: status == null && !favoritesOnly,
            onSelected: (_) {
              onStatus(null);
              onFavorites(false);
            },
          ),
          const SizedBox(width: 8),
          FilterChip(
            avatar: Icon(Icons.star, size: 18, color: ArColors.favorite),
            label: const Text('Preferiti'),
            selected: favoritesOnly,
            onSelected: onFavorites,
          ),
          const SizedBox(width: 8),
          // Il separatore sta fra i due gruppi di filtri: "Tutti" toglie
          // entrambi, gli altri sono indipendenti.
          for (final s in WatchStatus.displayOrder) ...[
            const SizedBox(width: 8),
            ChoiceChip(
              avatar: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: statusColor(s),
                  shape: BoxShape.circle,
                ),
              ),
              label: Text(s.label),
              selected: status == s && !favoritesOnly,
              onSelected: (selected) {
                // Rischedere lo stesso filtro lo deseleziona: con i chip
                // l'utente non ha un altro posto da premere per tornare a
                // vedere tutto, e "Tutti" in fondo alla riga si vede solo
                // scorrendo.
                onStatus(selected && !favoritesOnly ? s : null);
              },
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
      columnSpacing: 24,
      headingRowHeight: 40,
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
            cells: [
              // Larghezza fissata perche' `DataTable` misura ogni colonna sul
              // contenuto: senza un tetto, un titolo lungo spingerebbe le
              // colonne dei numeri fuori dalla finestra.
              DataCell(SizedBox(width: 340, child: _AnimeLine(entry: entry))),
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
  const WatchlistRow({required this.entry, required this.groupId, super.key});

  final WatchlistEntry entry;
  final String groupId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        children: [
          Row(
            children: [
              AnimeThumb(url: entry.imageUrl, title: entry.title, size: 44),
              const SizedBox(width: 12),
              Expanded(child: _AnimeLine(entry: entry)),
              const SizedBox(width: 8),
              _FavoriteButton(entry: entry, groupId: groupId),
              _OverflowMenu(entry: entry, groupId: groupId),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 56, top: 4),
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
              padding: const EdgeInsets.only(left: 56, right: 8, top: 6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: entry.progress,
                  minHeight: 4,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
            ),
        ],
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
              const SizedBox(width: 10),
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

/// Salva il nuovo stato e segnala l errore se il backend lo rifiuta.
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
class _StatusChip extends ConsumerWidget {
  const _StatusChip({required this.entry, required this.groupId});

  final WatchlistEntry entry;
  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
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
            const SizedBox(width: 6),
            // Troncato e non fisso: la colonna della tabella si stringe quando
            // le colonne dei numeri hanno piu' cifre, e un'etichetta che esce
            // dalla cella sposta tutte le colonne invece di accorciarsi.
            Flexible(
              child: Text(
                entry.status.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium,
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down, size: 18, color: theme.colorScheme.onSurfaceVariant),
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
        padding: const EdgeInsets.symmetric(vertical: 8),
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
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                entry.status.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 2),
            const Icon(Icons.arrow_drop_down, size: 20),
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
        color: entry.isFavorite ? ArColors.favorite : null,
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
    final theme = Theme.of(context);

    return TextButton.icon(
      onPressed: () => _open(context, ref),
      icon: const Icon(Icons.playlist_add_check, size: 18),
      label: Text(entry.episodeLabel),
      style: TextButton.styleFrom(
        foregroundColor:
            entry.hasStarted ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final episode = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
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

    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Episodi guardati', style: theme.textTheme.titleMedium),
          const SizedBox(height: 2),
          Text(
            widget.entry.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
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
                // Il massimo e il totale solo quando e' noto: con `episodes` a
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
            const SizedBox(height: 8),
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
              padding: const EdgeInsets.only(top: 8),
              child: AuthErrorBanner.error(_error!),
            ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Annulla'),
              ),
              const SizedBox(width: 8),
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
    final ranking = ref.watch(rankingProvider(widget.groupId));
    final existing = {
      for (final e in ref.watch(watchlistProvider(widget.groupId)).value ?? const [])
        e.animeId,
    };

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (context, scrollController) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Aggiungi dalla classifica', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    'Gli anime che il gruppo ha gia votato. Aggiungerne uno lo '
                    'mette in visione.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ranking.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => _ErrorState(
                  message: '$error',
                  onRetry: () =>
                      ref.read(rankingProvider(widget.groupId).notifier).refresh(),
                ),
                data: (rows) {
                  if (rows.isEmpty) {
                    return const _EmptyState(
                      message: 'La classifica del gruppo e vuota.',
                      hint: 'Servono anime votati prima di poterli aggiungere.',
                    );
                  }

                  return ListView.builder(
                    controller: scrollController,
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final row = rows[i];
                      final already = existing.contains(row.animeId) || _added.contains(row.animeId);

                      return ListTile(
                        leading: AnimeThumb(url: row.imageUrl, title: row.title),
                        title: Text(row.title, maxLines: 1, overflow: TextOverflow.ellipsis),
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
            Icon(Icons.bookmark_border, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
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
