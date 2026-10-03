import 'dart:async';

import 'package:animerank/core/constants/breakpoints.dart';
import 'package:animerank/features/anime/data/anime_repository.dart';
import 'package:animerank/features/anime/domain/anime.dart';
import 'package:animerank/features/anime/presentation/anime_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Ricerca del catalogo anime.
///
/// Due percorsi, in quest'ordine:
///
///  1. il catalogo locale, che e' veloce e funziona senza rete esterna;
///  2. Jikan, se il primo non trova niente.
///
/// Il secondo passaggio e' quello che rende il catalogo che si costruisce da
/// solo: nessuno popola a mano un elenco di migliaia di titoli, e il primo
/// utente a cercare qualcosa deve poterlo trovare.
///
/// La schermata non chiede mai piu' di una pagina per volta e accumula i
/// risultati: portare tutto il catalogo sul telefono costerebbe piu' di quanto
/// vale, e l'utente legge le prime righe.
class AnimeSearchScreen extends ConsumerStatefulWidget {
  const AnimeSearchScreen({super.key});

  @override
  ConsumerState<AnimeSearchScreen> createState() => _AnimeSearchScreenState();
}

class _AnimeSearchScreenState extends ConsumerState<AnimeSearchScreen> {
  /// Riferimento al campo di testo, per il focus programmatico.
  ///
  /// Senza, l'utente che tocca "Cerca anime" deve toccare due volte: una per
  /// aprire la schermata e una per ottenere la tastiera.
  final TextEditingController _textController = TextEditingController();

  final ScrollController _scrollController = ScrollController();

  /// Timer del rimando: ogni tasto non deve aprire una richiesta.
  ///
  /// 350 ms e' il compromesso: sotto, la ricerca parte mentre l'utente sta
  /// ancora scrivendo e si sente il doppio "nessun risultato"; sopra, sembra
  /// che la tastiera non reagisca.
  static const Duration _debounce = Duration(milliseconds: 350);

  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    // Timer e listener non sopravvivono allo smontaggio: senza questa pulizia
    // il timer scatterebbe una richiesta su un controller gia' distrutto.
    _debounceTimer?.cancel();
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _textController.dispose();
    super.dispose();
  }

  /// Carica la pagina successiva quando lo scroll si avvicina al fondo.
  ///
  /// La soglia di 600px anticipa il caricamento rispetto al fondo esatto: senza,
  /// l'utente arriverebbe in fondo e vedrebbe uno spinner comparire da solo,
  /// che si legge come un blocco.
  void _onScroll() {
    if (!_scrollController.hasClients) return;

    final position = _scrollController.position;
    if (position.pixels < position.maxScrollExtent - 600) return;

    ref.read(animeSearchProvider.notifier).loadMore();
  }

  void _onQueryChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () {
      if (!mounted) return;
      ref.read(animeSearchProvider.notifier).search(value);
      // Ogni ricerca riparte dall alto: continuare a scorrere mentre il testo
      // cambia mostrerebbe risultati a meta' lista, che non esistono.
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  Future<void> _refresh() async {
    _debounceTimer?.cancel();
    await ref.read(animeSearchProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(animeSearchProvider);
    final pagination = ref.watch(animePaginationProvider);
    final filtersOpen = ref.watch(animeFiltersPanelProvider);
    final controller = ref.watch(animeSearchProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Anime'),
        actions: [
          IconButton(
            tooltip: 'Aggiorna',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _SearchField(
              controller: _textController,
              onChanged: _onQueryChanged,
              filterCount: controller.filters.activeCount,
              filtersOpen: ref.watch(animeFiltersPanelProvider),
              onToggleFilters: controller.toggleFiltersPanel,
              onClearFilters: controller.clearFilters,
            ),
            _RecentStrip(),
            if (filtersOpen)
              _FilterPanel(
                filters: controller.filters,
                onApply: controller.applyFilters,
                onToggleGenre: controller.toggleGenre,
              ),
            Expanded(
              child: _buildBody(context, results, pagination, controller),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    AsyncValue<List<AnimeEntry>> results,
    AnimePagination pagination,
    AnimeSearchController controller,
  ) {
    // L'errore ha la precedenza sul caricamento quando non c'e' ancora un
    // valore: durante un retry automatico lo stato e' "caricando con un
    // errore dentro", e mostrare lo scheletro lascerebbe l'utente davanti a
    // uno spinner che gira senza spiegare nulla. Con dati gia' presenti la
    // lista resta, perche' un errore in coda non deve cancellare cio' che
    // l'utente sta leggendo.
    if (results.hasError && !results.hasValue) {
      final error = results.error!;
      return _ErrorView(
        message: '$error',
        // Solo gli errori recuperabili propongono "Riprova": su un errore di
        // permessi l'attesa non aiuta e il pulsante porterebbe a riprovare per
        // sempre.
        onRetry: error is AnimeFailure && !error.isRetryable ? null : _refresh,
      );
    }

    return results.when(
      loading: () => const _LoadingList(),
      error: (error, _) => _ErrorView(message: '$error', onRetry: _refresh),
      data: (rows) {
        if (rows.isEmpty) {
          return _EmptyResults(controller: controller, pagination: pagination);
        }

        return _ResultsList(
          rows: rows,
          pagination: pagination,
          controller: controller,
          scrollController: _scrollController,
          onLoadMore: () => ref.read(animeSearchProvider.notifier).loadMore(),
          onSearchRemote: () =>
              ref.read(animeSearchProvider.notifier).searchRemote(forced: true),
        );
      },
    );
  }
}

/// Campo di ricerca con pulsante filtri.
class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.onChanged,
    required this.filterCount,
    required this.filtersOpen,
    required this.onToggleFilters,
    required this.onClearFilters,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  final int filterCount;
  final bool filtersOpen;
  final VoidCallback onToggleFilters;
  final VoidCallback onClearFilters;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: SearchBar(
              controller: controller,
              hintText: 'Cerca anime',
              // Il focus automatico mette la tastiera subito: l utente che ha
              // scelto "Cerca anime" dalla home vuole scrivere, non toccare
              // prima il campo per poterlo toccare dopo.
              autoFocus: true,
              leading: const Icon(Icons.search),
              // La X azzera il campo e rilancia la ricerca: senza, il testo
              // resterebbe e la lista continuerebbe a mostrare i risultati
              // precedenti, che non piu' corrispondono a quello che si vede.
              trailing: [
                if (controller.text.isNotEmpty)
                  IconButton(
                    tooltip: 'Cancella',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                  ),
              ],
              onChanged: onChanged,
              // Invio fa la ricerca subito: rimandare di 350ms su un tocco
              // esplicito sembrerebbe che l'app abbia ignorato la richiesta.
              onSubmitted: onChanged,
            ),
          ),
          const SizedBox(width: 8),
          // Badge sui filtri attivi: senza, l'utente non ha modo di capire
          // perche' la lista e' piu' corta di quanto si aspettava.
          Badge(
            isLabelVisible: filterCount > 0,
            label: Text('$filterCount'),
            child: IconButton.filledTonal(
              tooltip: 'Filtri',
              icon: const Icon(Icons.tune),
              onPressed: onToggleFilters,
            ),
          ),
        ],
      ),
    );
  }
}

/// Striscia "usciti di recente", pieghevole.
///
/// Sta chiusa per defaulte perche' la ricerca e' il compito principale della
/// schermata: una striscia sempre aperta spingerebbe i risultati sotto la
/// piega e l'utente non vedrebbe nulla di cio' che ha cercato.
class _RecentStrip extends ConsumerStatefulWidget {
  const _RecentStrip();

  @override
  ConsumerState<_RecentStrip> createState() => _RecentStripState();
}

class _RecentStripState extends ConsumerState<_RecentStrip> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final recent = ref.watch(recentAnimeProvider);

    if (recent.maybeWhen(data: (rows) => rows.isEmpty, orElse: () => true)) {
      return const SizedBox.shrink();
    }

    return Column(
      children: [
        ListTile(
          dense: true,
          leading: const Icon(Icons.new_releases_outlined),
          title: const Text('Usciti di recente'),
          trailing: Icon(_open ? Icons.expand_less : Icons.expand_more),
          onTap: () => setState(() => _open = !_open),
        ),
        if (_open)
          recent.when(
            data: (rows) => SizedBox(
              height: 150,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: rows.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, index) =>
                    AnimeSearchResultCard(entry: rows[index], compact: true),
              ),
            ),
            loading: () => const SizedBox(
              height: 150,
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, _) => const SizedBox.shrink(),
          ),
      ],
    );
  }
}

/// Pannello dei filtri.
class _FilterPanel extends ConsumerWidget {
  const _FilterPanel({
    required this.filters,
    required this.onApply,
    required this.onToggleGenre,
  });

  final AnimeFilters filters;
  final ValueChanged<AnimeFilters> onApply;
  final ValueChanged<String> onToggleGenre;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final genres = ref.watch(animeGenresProvider);

    return Container(
      // Senza il contenitore con bordo il pannello si confonderebbe con lo
      // sfondo della lista: l'utente non capirebbe che e' una sezione che si
      // chiude.
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      // Il pannello scorre e non occupa piu' di meta' schermo: con cinque
      // gruppi di filtri su un telefono prenderebbe piu' spazio dei risultati,
      // e i risultati sono la ragione per cui l'utente ha aperto la
      // schermata. Il tetto serve perche' il pannello sta in una Column con la
      // lista: senza, cresce fino a uscire dal viewport e i filtri in fondo
      // diventano irraggiungibili.
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.5,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Filtri', style: theme.textTheme.titleSmall),
                  ),
                  // Azzerare e' una delle azioni piu' frequenti dopo una ricerca
                  // delusa: dover chiudere il pannello e azzerare le pastiglie una
                  // a una e' il modo piu' rapido per far smettere di usare i filtri.
                  TextButton(
                    onPressed: filters.activeCount == 0
                        ? null
                        : () => onApply(const AnimeFilters()),
                    child: const Text('Azzera'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final type in AnimeMediaType.values)
                    ChoiceChip(
                      label: Text(type.label),
                      selected: filters.mediaType == type,
                      onSelected: (selected) => onApply(
                        selected
                            ? filters.copyWith(mediaType: type)
                            : filters.copyWith(clearMediaType: true),
                      ),
                    ),
                  for (final season in AnimeSeason.values)
                    FilterChip(
                      label: Text(season.label),
                      selected: filters.season == season,
                      onSelected: (selected) => onApply(
                        selected
                            ? filters.copyWith(season: season)
                            : filters.copyWith(clearSeason: true),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text('Stato', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              // "Solo gli anime in corso" e' la domanda piu' frequente dopo
              // "cerca un titolo": chi apre l'app vuole sapere cosa guardare adesso.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final status in AnimeAirStatus.values)
                    FilterChip(
                      label: Text(status.label),
                      selected: filters.status == status,
                      onSelected: (selected) => onApply(
                        selected
                            ? filters.copyWith(status: status)
                            : filters.copyWith(clearStatus: true),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text('Genere', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              genres.when(
                data: (rows) => Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  // I generi sono tanti: senza un limite allo scroll il pannello
                  // occuperebbe piu' schermo della lista e coprirebbe i risultati
                  // della ricerca appena fatta.
                  children: [
                    for (final genre in rows.take(24))
                      FilterChip(
                        label: Text(genre.name),
                        selected: filters.genres.contains(genre.name),
                        onSelected: (_) => onToggleGenre(genre.name),
                      ),
                  ],
                ),
                loading: () => const SizedBox(
                  height: 40,
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
                // I generi non disponibili non devono bloccare i filtri che
                // funzionano: formato, stagione e voto restano utilizzabili.
                error: (error, _) => Text(
                  'Generi non disponibili.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text('Voto minimo', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  for (final score in const [6.0, 7.0, 8.0, 9.0])
                    FilterChip(
                      // Il separatore e' "8+": il segno "minimo" scritto per esteso
                      // occuperebbe spazio nella pastiglia senza aggiungere
                      // informazione.
                      label: Text('${score.toInt()}+'),
                      selected: filters.minScore == score,
                      onSelected: (selected) => onApply(
                        selected
                            ? filters.copyWith(minScore: score)
                            : filters.copyWith(clearScore: true),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text('Anno', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  for (final year in const [
                    2026,
                    2025,
                    2024,
                    2020,
                    2010,
                    2000,
                    1990,
                  ])
                    FilterChip(
                      label: Text('${year}s'),
                      selected: filters.yearFrom == year,
                      onSelected: (selected) => onApply(
                        selected
                            ? filters.copyWith(yearFrom: year)
                            : filters.copyWith(clearYear: true),
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

/// Lista dei risultati con infinite scroll.
///
/// Riceve il controller dello scroll dallo stato: senza, il reset a zero dopo
/// una ricerca non avrebbe effetto e la lista resterebbe ferma a meta' dei
/// risultati precedenti, con il nuovo testo in alto e righe che non
/// corrispondono a nulla di quello che e' scritto.
class _ResultsList extends ConsumerWidget {
  const _ResultsList({
    required this.rows,
    required this.pagination,
    required this.controller,
    required this.scrollController,
    required this.onLoadMore,
    required this.onSearchRemote,
  });

  final List<AnimeEntry> rows;
  final AnimePagination pagination;
  final AnimeSearchController controller;
  final ScrollController scrollController;
  final VoidCallback onLoadMore;
  final VoidCallback onSearchRemote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(animeStatsProvider);
    final width = MediaQuery.sizeOf(context).width;
    final columns = Breakpoints.gridColumns(width);

    return CustomScrollView(
      controller: scrollController,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          sliver: SliverToBoxAdapter(child: _CatalogHeader(stats: stats)),
        ),
        // Griglia su schermi larghi, lista su telefono: le card affiancate
        // sfruttano lo spazio che su un telefono non esiste.
        if (columns > 1)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisExtent: 150,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: rows.length,
              itemBuilder: (context, index) =>
                  AnimeSearchResultCard(entry: rows[index]),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverList.separated(
              itemCount: rows.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) =>
                  AnimeSearchResultCard(entry: rows[index]),
            ),
          ),
        SliverToBoxAdapter(
          child: _ListFooter(pagination: pagination, onRetry: onLoadMore),
        ),
        // Con risultati gia' in lista Jikan non serve: proporre "cerca anche
        // online" mentre l'utente sta leggendo risultati validi lo
        // confonderebbe. Compare solo quando la ricerca locale non ha
        // prodotto nulla, ed e' [_EmptyResults] a proporlo in quel caso.
        if (rows.isNotEmpty && controller.query.isEmpty)
          SliverToBoxAdapter(child: _RemoteSuggestion(onTap: onSearchRemote)),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

/// Riga finale: spinner, errore in coda o fine della lista.
class _ListFooter extends StatelessWidget {
  const _ListFooter({required this.pagination, required this.onRetry});

  final AnimePagination pagination;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (pagination.isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final error = pagination.error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Text(
              error.message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: onRetry, child: const Text('Riprova')),
          ],
        ),
      );
    }

    if (pagination.hasMore) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Text(
        'Fine dei risultati.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Proposta di cercare su Jikan quando il catalogo locale non basta.
class _RemoteSuggestion extends StatelessWidget {
  const _RemoteSuggestion({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.cloud_download_outlined),
        label: const Text('Cerca anche su Jikan'),
      ),
    );
  }
}

/// Testata con il contatore del catalogo.
class _CatalogHeader extends StatelessWidget {
  const _CatalogHeader({required this.stats});

  final AsyncValue<AnimeCatalogStats> stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return stats.maybeWhen(
      data: (data) {
        // Il contatore serve a capire se la ricerca sta funzionando: un
        // catalogo con poche righe spiega perche' i risultati scarseggiano.
        final parts = <String>[
          if (data.totalAnime > 0) '${data.totalAnime} anime in catalogo',
          if (data.airingNow > 0) '${data.airingNow} in onda',
          if (data.currentSeason != null)
            'stagione ${data.currentSeason!.label}',
        ];

        if (parts.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            parts.join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        );
      },
      // L'assenza di statistiche non e' un errore da mostrare: e' solo un
      // contatore che non e' arrivato.
      orElse: () => const SizedBox.shrink(),
    );
  }
}

/// Scheletro durante il primo caricamento.
///
/// Tre righe grigie al posto di uno spinner a schermo intero: rendono visibile
/// che verra' una lista e quindi dove, mentre lo spinner lascia uno spazio vuoto
/// che l'utente non sa come riempire.
class _LoadingList extends StatelessWidget {
  const _LoadingList();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: 6,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) => Container(
        height: 130,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}

/// Stato vuoto.
///
/// Tre casi distinti, con messaggi distinti, perche' la soluzione e diversa per
/// ciascuno:
///
///  - il catalogo e' vuoto: conviene cercare su Jikan;
///  - ci sono filtri attivi: il problema sono i filtri, non la ricerca;
///  - la ricerca non ha proprio trovato nulla: conviene cambiare parole.
class _EmptyResults extends ConsumerWidget {
  const _EmptyResults({required this.controller, required this.pagination});

  final AnimeSearchController controller;
  final AnimePagination pagination;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final stats = ref.watch(animeStatsProvider);
    final catalogEmpty = stats.maybeWhen(
      data: (data) => data.isEmpty,
      orElse: () => false,
    );

    final hasFilters = controller.hasActiveFilters;
    final hasQuery = controller.query.isNotEmpty;

    // Se c'e' un errore di paginazione (es. ricerca Jikan fallita), mostralo
    // anche nello stato vuoto: senza feedback l'utente pensa che il tap non
    // abbia fatto nulla.
    final pageError = pagination.error;
    if (pageError != null) {
      return _ErrorView(
        message: pageError.message,
        onRetry: () => ref
            .read(animeSearchProvider.notifier)
            .searchRemote(forced: true),
      );
    }

    final message = hasFilters
        ? 'Nessun anime corrisponde ai filtri.'
        : catalogEmpty
        ? 'Il catalogo e\' ancora vuoto.'
        : hasQuery
        ? 'Nessun risultato per "${controller.query}".'
        : 'Cerca un anime per iniziare.';

    final hint = hasFilters
        ? 'Troppo stretti. Allarga i filtri o azzerali.'
        : catalogEmpty
        ? 'La prima ricerca riempir�� il catalogo: i risultati trovati '
              'restano salvati per tutti.'
        : hasQuery
        ? 'Prova col titolo giapponese, o con parole pi�� corte.'
        : 'Per esempio "Attack on Titan", oppure un genere per vedere '
              'tutto quello che c\'��.';

    // Scorre invece di essere centrato a caso: quando il pannello filtri e' aperto
    // lo spazio che resta e' poco e il blocco, se non scorre, va in overflow e
    // l'utente perde il pulsante "Azzera i filtri" proprio quando gli serve.
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasFilters ? Icons.filter_alt_off : Icons.search_off,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            if (hasFilters)
              OutlinedButton.icon(
                onPressed: controller.clearFilters,
                icon: const Icon(Icons.clear),
                label: const Text('Azzera i filtri'),
              )
            else if (hasQuery)
              FilledButton.tonalIcon(
                onPressed: () => ref
                    .read(animeSearchProvider.notifier)
                    .searchRemote(forced: true),
                icon: const Icon(Icons.cloud_download_outlined),
                label: const Text('Cerca su Jikan'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Schermata di errore iniziale.
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;

  /// `null` quando l'errore non e' recuperabile: in quel caso non viene
  /// mostrato alcun pulsante, perche' riprovare non cambierebbe nulla.
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 44,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              if (onRetry != null) ...[
                const SizedBox(height: 16),
                FilledButton.tonal(
                  onPressed: onRetry,
                  child: const Text('Riprova'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Copertina di un anime nella lista.
///
/// Esposta perche' i test la cercano per nome: verificare "la lista mostra
/// risultati" con un finder costruito su un testo qualsiasi passerebbe anche se
/// la lista non avesse card, mentre con la classe il test controlla davvero
/// quante righe sono a schermo.
class AnimeSearchResultCard extends StatelessWidget {
  const AnimeSearchResultCard({
    required this.entry,
    this.compact = false,
    super.key,
  });

  final AnimeEntry entry;

  /// Versione stretta per la striscia orizzontale: senza, le card della
  /// striscia sarebbero larghe come quelle della lista e non ci starebbero.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: compact
          ? _buildCompact(context, theme)
          : _buildRow(context, theme),
    );
  }

  Widget _buildRow(BuildContext context, ThemeData theme) {
    // Anno, tipo e votazione in una riga: sono i tre dati che servono per
    // scegliere, e metterli in un elenco a voci farebbe tre righe per card.
    final facts = entry.factsLabel;

    return InkWell(
      onTap: () => _showDetail(context),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Poster(url: entry.imageUrl, title: entry.title),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.title,
                    style: theme.textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // Il titolo giapponese aiuta chi cerca in giapponese a
                  // riconoscere subito l'opera, ma non deve spingere il titolo
                  // principale fuori dai due righe assegnati.
                  if (entry.japaneseTitle != null)
                    Text(
                      entry.japaneseTitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (facts.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      facts,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  _TrailingInfo(entry: entry),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompact(BuildContext context, ThemeData theme) {
    return InkWell(
      onTap: () => _showDetail(context),
      child: SizedBox(
        width: 110,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Poster(url: entry.imageUrl, title: entry.title, height: 96),
            const SizedBox(height: 6),
            Text(
              entry.title,
              style: theme.textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  /// Apre il dettaglio dell'anime.
  ///
  /// Durante la beta il foglio mostra i dati disponibili senza votare: votare
  /// richiede un gruppo, e la schermata di ricerca non sa quale sia.
  void _showDetail(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => AnimeDetailSheet(entry: entry),
    );
  }
}

/// Copertina con fallback.
///
/// Senza immagine non si lascia lo spazio vuoto: la prima lettera del titolo e'
/// un fallback che almeno dice di cosa si tratta, e un riquadro grigio non
/// distingue "non c'e' immagine" da "non ha ancora caricato".
class _Poster extends StatelessWidget {
  const _Poster({required this.url, required this.title, this.height = 120});

  final String? url;
  final String title;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (url == null || url!.isEmpty) {
      return SizedBox(
        width: 78,
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Text(
              title.isEmpty ? '?' : title.characters.first.toUpperCase(),
              style: theme.textTheme.headlineSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        url!,
        width: 78,
        height: height,
        // `errorBuilder` copre il caso piu' comune: copertine che non esistono
        // piu' su MyAnimeList restano nel catalogo con un URL vecchio.
        errorBuilder: (context, error, stack) => SizedBox(
          width: 78,
          height: height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.broken_image_outlined,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        fit: BoxFit.cover,
      ),
    );
  }
}

/// Generi, voto e stato, in coda alla riga.
class _TrailingInfo extends StatelessWidget {
  const _TrailingInfo({required this.entry});

  final AnimeEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;

    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (entry.status != null)
          Text(
            entry.status!.label,
            style: small?.copyWith(color: theme.colorScheme.primary),
          ),
        if (entry.score != null)
          // Il numero di voti va vicino al voto: 8,4 su 40 utenti e 8,4 su
          // 800.000 non sono la stessa informazione, e senza il conteggio
          // l'utente prende il primo per il secondo.
          Text('★ ${entry.score!.toStringAsFixed(1)}', style: small),
        ...[
          for (final genre in entry.genres.take(3))
            Text(
              genre,
              style: small?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
        ],
      ],
    );
  }
}

/// Foglio di dettaglio dell'anime.
class AnimeDetailSheet extends StatelessWidget {
  const AnimeDetailSheet({required this.entry, super.key});

  final AnimeEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final facts = entry.factsLabel;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Poster(url: entry.imageUrl, title: entry.title, height: 160),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(entry.title, style: theme.textTheme.titleLarge),
                      if (entry.japaneseTitle != null)
                        Text(
                          entry.japaneseTitle!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      if (facts.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(facts, style: theme.textTheme.bodySmall),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (!entry.canRate)
              // Dichiarazione esplicita invece di un pulsante disabilitato: un
              // bottone grigio senza spiegazione sembra un bug.
              Card(
                color: theme.colorScheme.surfaceContainerHighest,
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'Questo anime non è ancora in catalogo, quindi non si può '
                    'votare. Apri la ricerca di nuovo fra un momento: la '
                    'seconda volta sarà disponibile.',
                  ),
                ),
              ),
            if (entry.status != null || entry.score != null) ...[
              _FactRow(
                label: 'Stato',
                value: entry.status?.label ?? 'Sconosciuto',
              ),
              if (entry.score != null)
                _FactRow(
                  label: 'Voto MyAnimeList',
                  value:
                      '${entry.score!.toStringAsFixed(2)}'
                      '${entry.scoredBy != null ? ' su ${entry.scoredBy} voti' : ''}',
                ),
              if (entry.studio != null)
                _FactRow(label: 'Studio', value: entry.studio!),
              if (entry.duration != null)
                _FactRow(label: 'Durata', value: entry.duration!),
            ],
            if (entry.genres.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Generi', style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final genre in entry.genres)
                    Chip(
                      label: Text(genre),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
            if (entry.synopsis != null) ...[
              const SizedBox(height: 16),
              Text('Trama', style: theme.textTheme.labelLarge),
              const SizedBox(height: 6),
              Text(entry.synopsis!, style: theme.textTheme.bodyMedium),
            ],
          ],
        );
      },
    );
  }
}

/// Riga etichetta/valore nel dettaglio.
class _FactRow extends StatelessWidget {
  const _FactRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
