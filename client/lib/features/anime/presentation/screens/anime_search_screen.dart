import 'dart:async';

import 'package:animerank/core/constants/breakpoints.dart';
import 'package:animerank/core/router/app_router.dart';
import 'package:animerank/core/theme/app_theme.dart';
import 'package:animerank/core/ui/anime_card.dart';
import 'package:animerank/core/ui/content_row.dart';
import 'package:animerank/core/ui/section_header.dart';
import 'package:animerank/features/anime/data/anime_repository.dart';
import 'package:animerank/features/anime/domain/anime.dart';
import 'package:animerank/features/anime/presentation/anime_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
///
/// I risultati sono una griglia di locandine e non una tabella. Il motivo e'
/// che qui si cerca un'immagine da ricordare, non una riga da confrontare: e
/// su schermo largo una griglia mostra molti piu' titoli per schermo, quindi
/// l'utente trova quello che cerca con meno scorrimenti.
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
      // Ogni ricerca riparte dall'alto: continuare a scorrere mentre il testo
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
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Top(
              controller: _textController,
              onChanged: _onQueryChanged,
              onRefresh: _refresh,
            ),
            _Filters(
              controller: controller,
              open: filtersOpen,
            ),
            const _RecentStrip(),
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
      loading: () => const _LoadingGrid(),
      error: (error, _) => _ErrorView(message: '$error', onRetry: _refresh),
      data: (rows) {
        if (rows.isEmpty) {
          return _EmptyResults(controller: controller, pagination: pagination);
        }

        return _ResultsGrid(
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

/// Intestazione con campo di ricerca e refresh.
///
/// Il campo e' l'elemento piu' grande della schermata perche' e' l'unica azione
/// che l'utente ha sulla pagina: metterlo alla stessa altezza di un'icona
/// significherebbe costringerlo a cercare il campo fra tre controlli uguali.
class _Top extends StatelessWidget {
  const _Top({
    required this.controller,
    required this.onChanged,
    required this.onRefresh,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final horizontal = ArSpace.page(context).left;

    return Padding(
      padding: EdgeInsets.fromLTRB(horizontal, ArSpace.sm, horizontal, ArSpace.xs),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              style: theme.textTheme.titleMedium,
              // Il focus automatico mette la tastiera subito: l'utente che ha
              // scelto "Cerca anime" dalla home vuole scrivere, non toccare
              // prima il campo per poterlo toccare dopo.
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: onChanged,
              // Invio fa la ricerca subito: rimandare di 350ms su un tocco
              // esplicito sembrerebbe che l'app abbia ignorato la richiesta.
              onSubmitted: onChanged,
              decoration: InputDecoration(
                hintText: 'Cerca anime',
                prefixIcon: const Icon(Icons.search, size: 20),
                // La X azzera il campo e rilancia la ricerca: senza, il testo
                // resterebbe e la lista continuerebbe a mostrare i risultati
                // precedenti, che non piu' corrispondono a quello che si vede.
                suffixIcon: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, value, _) => value.text.isEmpty
                      ? const SizedBox.shrink()
                      : IconButton(
                          tooltip: 'Cancella',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            controller.clear();
                            onChanged('');
                          },
                        ),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
            ),
          ),
          const SizedBox(width: ArSpace.xs),
          IconButton(
            tooltip: 'Aggiorna',
            icon: const Icon(Icons.refresh),
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }
}

/// Barra dei filtri.
///
/// Stessa forma su schermo largo e stretto, e cambia solo il posto in cui si
/// apre: su telefono il pannello e' un foglio sopra la lista, su desktop scende
/// sotto la barra. Un foglio anche da desktop coprirebbe i risultati che
/// l'utente sta confrontando con i filtri, che e' esattamente il momento in cui
/// deve poterli vedere cambiare.
class _Filters extends ConsumerWidget {
  const _Filters({required this.controller, required this.open});

  final AnimeSearchController controller;
  final bool open;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final horizontal = ArSpace.page(context).left;
    final count = controller.filters.activeCount;

    final body = _FilterPanel(
      filters: controller.filters,
      onApply: controller.applyFilters,
      onToggleGenre: controller.toggleGenre,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontal),
          child: Row(
            children: [
              // Badge sui filtri attivi: senza, l'utente non ha modo di capire
              // perche' la lista e' piu' corta di quanto si aspettava.
              ArChip(
                label: count > 0 ? 'Filtri · $count' : 'Filtri',
                icon: Icons.tune,
                selected: count > 0 || open,
                onTap: controller.toggleFiltersPanel,
              ),
              if (count > 0) ...[
                const SizedBox(width: ArSpace.xs),
                // Azzerare e' una delle azioni piu' frequenti dopo una ricerca
                // delusa: dover chiudere il pannello e azzerare le pastiglie una
                // a una e' il modo piu' rapido per far smettere di usare i filtri.
                ArChip(
                  label: 'Azzera',
                  icon: Icons.close,
                  selected: false,
                  onTap: controller.clearFilters,
                ),
              ],
              ],
          ),
        ),
        if (open) body,
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
    final horizontal = ArSpace.page(context).left;

    return Container(
      // Senza il contenitore con bordo il pannello si confonderebbe con lo
      // sfondo della lista: l'utente non capirebbe che e' una sezione che si
      // chiude.
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 18),
      // Il pannello scorre e non occupa piu' di meta' schermo: con cinque
      // gruppi di filtri su un telefono prenderebbe piu' spazio dei risultati,
      // e i risultati sono la ragione per cui l'utente ha aperto la
      // schermata. Il tetto serve perche' il pannello sta in una Column con la
      // lista: senza, cresce fino a uscire dal viewport e i filtri in fondo
      // diventano irraggiungibili.
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.45,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: horizontal),
                child: SectionHeader(
                  title: 'Filtri',
                  action: filters.activeCount == 0
                      ? null
                      : () => onApply(const AnimeFilters()),
                  actionLabel: 'Azzera',
                ),
              ),
              const SizedBox(height: ArSpace.sm),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: horizontal),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: ArSpace.xs,
                      runSpacing: ArSpace.xs,
                      children: [
                        for (final type in AnimeMediaType.values)
                          ArChip(
                            label: type.label,
                            selected: filters.mediaType == type,
                            onTap: () => onApply(
                              filters.mediaType == type
                                  ? filters.copyWith(clearMediaType: true)
                                  : filters.copyWith(mediaType: type),
                            ),
                          ),
                        for (final season in AnimeSeason.values)
                          ArChip(
                            label: season.label,
                            selected: filters.season == season,
                            onTap: () => onApply(
                              filters.season == season
                                  ? filters.copyWith(clearSeason: true)
                                  : filters.copyWith(season: season),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: ArSpace.md),
                    Text('Stato', style: theme.textTheme.labelSmall),
                    const SizedBox(height: 6),
                    // "Solo gli anime in corso" e' la domanda piu' frequente
                    // dopo "cerca un titolo": chi apre l'app vuole sapere cosa
                    // guardare adesso.
                    Wrap(
                      spacing: ArSpace.xs,
                      runSpacing: ArSpace.xs,
                      children: [
                        for (final status in AnimeAirStatus.values)
                          ArChip(
                            label: status.label,
                            selected: filters.status == status,
                            onTap: () => onApply(
                              filters.status == status
                                  ? filters.copyWith(clearStatus: true)
                                  : filters.copyWith(status: status),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: ArSpace.md),
                    Text('Genere', style: theme.textTheme.labelSmall),
                    const SizedBox(height: 6),
                    genres.when(
                      data: (rows) => Wrap(
                        spacing: ArSpace.xs,
                        runSpacing: ArSpace.xs,
                        // I generi sono tanti: senza un limite allo scroll il
                        // pannello occuperebbe piu' schermo della lista e
                        // coprirebbe i risultati della ricerca appena fatta.
                        children: [
                          for (final genre in rows.take(24))
                            ArChip(
                              label: genre.name,
                              selected: filters.genres.contains(genre.name),
                              onTap: () => onToggleGenre(genre.name),
                            ),
                        ],
                      ),
                      loading: () => const SizedBox(
                        height: 34,
                        width: 34,
                        child: Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                      // I generi non disponibili non devono bloccare i filtri
                      // che funzionano: formato, stagione e voto restano
                      // utilizzabili.
                      error: (error, _) => Text(
                        'Generi non disponibili.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(height: ArSpace.md),
                    Text('Voto minimo', style: theme.textTheme.labelSmall),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: ArSpace.xs,
                      children: [
                        for (final score in const [6.0, 7.0, 8.0, 9.0])
                          ArChip(
                            // Il separatore e' "8+": il segno "minimo" scritto
                            // per esteso occuperebbe spazio nella pastiglia
                            // senza aggiungere informazione.
                            label: '${score.toInt()}+',
                            selected: filters.minScore == score,
                            onTap: () => onApply(
                              filters.minScore == score
                                  ? filters.copyWith(clearScore: true)
                                  : filters.copyWith(minScore: score),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: ArSpace.md),
                    Text('Anno', style: theme.textTheme.labelSmall),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: ArSpace.xs,
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
                          ArChip(
                            label: '${year}s',
                            selected: filters.yearFrom == year,
                            onTap: () => onApply(
                              filters.yearFrom == year
                                  ? filters.copyWith(clearYear: true)
                                  : filters.copyWith(yearFrom: year),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
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
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: ArSpace.page(context).left,
              vertical: ArSpace.sm,
            ),
            child: Row(
              children: [
                const Icon(Icons.new_releases_outlined, size: 18),
                const SizedBox(width: ArSpace.xs),
                Text('Usciti di recente',
                    style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                AnimatedRotation(
                  turns: _open ? 0.5 : 0,
                  duration: ArMotion.base,
                  child: const Icon(Icons.expand_more, size: 20),
                ),
              ],
            ),
          ),
        ),
        if (_open)
          recent.when(
            data: (rows) => SizedBox(
              height: 196,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(
                    horizontal: ArSpace.page(context).left),
                itemCount: rows.length,
                separatorBuilder: (_, _) => const SizedBox(width: ArSpace.sm),
                itemBuilder: (context, index) =>
                    AnimeSearchResultCard(entry: rows[index], compact: true),
              ),
            ),
            loading: () => const SizedBox(
              height: 196,
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, _) => const SizedBox.shrink(),
          ),
      ],
    );
  }
}

/// Griglia dei risultati con infinite scroll.
///
/// Riceve il controller dello scroll dallo stato: senza, il reset a zero dopo
/// una ricerca non avrebbe effetto e la lista resterebbe ferma a meta' dei
/// risultati precedenti, con il nuovo testo in alto e righe che non
/// corrispondono a nulla di quello che e' scritto.
class _ResultsGrid extends ConsumerWidget {
  const _ResultsGrid({
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

    // Su telefono due colonne e non tre: a tre la locandina scende sotto i 110px
    // e il titolo su due righe non entra piu', quindi ogni card mostra solo
    // "quella li'" invece del nome.
    final columns = switch (Breakpoints.of(width)) {
      LayoutSize.compact => 2,
      LayoutSize.medium => 3,
      LayoutSize.expanded => width >= 1400 ? 6 : 5,
    };

    return CustomScrollView(
      controller: scrollController,
      slivers: [
        SliverToBoxAdapter(child: _CatalogHeader(stats: stats, found: rows.length)),
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: ArSpace.page(context).left),
          sliver: SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              // La locandina e' in 2:3 e il titolo ci va sopra, quindi
              // l'altezza e' quella della locandina piu' il margine: senza, il
              // titolo dell'ultima riga verrebbe tagliato.
              mainAxisExtent: 232,
              crossAxisSpacing: ArSpace.sm,
              mainAxisSpacing: ArSpace.sm,
            ),
            itemCount: rows.length,
            itemBuilder: (context, index) => _card(context, rows[index]),
          ),
        ),
        SliverToBoxAdapter(
          child: _ListFooter(pagination: pagination, onRetry: onLoadMore),
        ),
        // Con risultati gia' in lista Jikan non serve: proporre "cerca anche
        // online" mentre l'utente sta leggendo risultati validi lo
        // confonderebbe. Compare solo quando la ricerca locale non ha
        // prodotto nulla, ed e' [_EmptyResults] a proporlo in quel caso.
        if (controller.query.isEmpty)
          SliverToBoxAdapter(child: _RemoteSuggestion(onTap: onSearchRemote)),
        const SliverToBoxAdapter(child: SizedBox(height: ArSpace.xl)),
      ],
    );
  }

  Widget _card(BuildContext context, AnimeEntry entry) {
    return AnimeCard(
      title: entry.title,
      imageUrl: entry.imageUrl,
      score: entry.score,
      heroTag: entry.heroTag,
      subtitle: entry.factsLabel.isEmpty ? null : entry.factsLabel,
      genres: entry.genres,
      onTap: () => context.push(AppRoutes.animeDetail, extra: entry),
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
        padding: EdgeInsets.all(ArSpace.lg),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final error = pagination.error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(ArSpace.lg),
        child: Column(
          children: [
            Text(
              error.message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: ArSpace.xs),
            TextButton(onPressed: onRetry, child: const Text('Riprova')),
          ],
        ),
      );
    }

    if (pagination.hasMore) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.all(ArSpace.lg),
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
      padding: EdgeInsets.fromLTRB(
        ArSpace.page(context).left,
        ArSpace.xs,
        ArSpace.page(context).right,
        0,
      ),
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.cloud_download_outlined, size: 18),
        label: const Text('Cerca anche su Jikan'),
      ),
    );
  }
}

/// Testata con il contatore del catalogo.
///
/// Il contatore serve a capire se la ricerca sta funzionando: un catalogo con
/// poche righe spiega perche' i risultati scarseggiano.
class _CatalogHeader extends StatelessWidget {
  const _CatalogHeader({required this.stats, required this.found});

  final AsyncValue<AnimeCatalogStats> stats;
  final int found;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = <String>['$found risultati'];

    stats.maybeWhen(
      data: (data) {
        // Il totale del catalogo viene per primo perche' e' il numero che
        // spiega la ricerca: se la lista e' vuota e il catalogo ne ha 1250,
        // il problema e' il testo cercato; se ne ha tre, il problema e' che il
        // catalogo non e' ancora stato riempito.
        if (data.totalAnime > 0) parts.insert(0, '${data.totalAnime} in catalogo');
        if (data.airingNow > 0) parts.add('${data.airingNow} in onda');
        if (data.currentSeason != null) {
          parts.add('stagione ${data.currentSeason!.label}');
        }
      },
      // L'assenza di statistiche non e' un errore da mostrare: e' solo un
      // contatore che non e' arrivato.
      orElse: () => {},
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        ArSpace.page(context).left,
        ArSpace.sm,
        ArSpace.page(context).right,
        ArSpace.xs,
      ),
      child: Text(
        parts.join(' · '),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Scheletro durante il primo caricamento.
///
/// Le caselle grigie al posto di uno spinner a schermo intero: rendono visibile
/// che verra' una griglia e quindi dove, mentre lo spinner lascia uno spazio
/// vuoto che l'utente non sa come riempire.
class _LoadingGrid extends StatelessWidget {
  const _LoadingGrid();

  @override
  Widget build(BuildContext context) {
    final columns = switch (Breakpoints.fromContext(context)) {
      LayoutSize.compact => 2,
      LayoutSize.medium => 3,
      LayoutSize.expanded => 5,
    };

    return PosterGridSkeleton(
      columns: columns,
      itemCount: 10,
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
        onRetry: () =>
            ref.read(animeSearchProvider.notifier).searchRemote(forced: true),
      );
    }

    // Mostra caricamento durante la ricerca remota (Jikan): senza feedback
    // l'utente non capisce se il tap ha fatto qualcosa.
    if (pagination.isLoadingMore && hasQuery) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(ArSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(height: ArSpace.md),
              Text('Cerco su Jikan...'),
            ],
          ),
        ),
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
            ? 'La prima ricerca riempira\' il catalogo: i risultati trovati '
                'restano salvati per tutti.'
            : hasQuery
                ? 'Prova col titolo giapponese, o con parole piu\' corte.'
                : 'Per esempio "Attack on Titan", oppure un genere per vedere '
                    'tutto quello che c\'e\'.';

    // Scorre invece di essere centrato a caso: quando il pannello filtri e'
    // aperto lo spazio che resta e' poco e il blocco, se non scorre, va in
    // overflow e l'utente perde il pulsante "Azzera i filtri" proprio quando
    // gli serve.
    return SingleChildScrollView(
      child: EmptyState(
        icon: hasFilters ? Icons.filter_alt_off : Icons.search_off,
        title: message,
        message: hint,
        action: hasFilters
            ? OutlinedButton.icon(
                onPressed: controller.clearFilters,
                icon: const Icon(Icons.clear),
                label: const Text('Azzera i filtri'),
              )
            : hasQuery
                ? FilledButton.tonalIcon(
                    onPressed: () => ref
                        .read(animeSearchProvider.notifier)
                        .searchRemote(forced: true),
                    icon: const Icon(Icons.cloud_download_outlined),
                    label: const Text('Cerca su Jikan'),
                  )
                : null,
      ),
    );
  }
}

/// Schermata di errore iniziale.
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, this.onRetry});

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
          padding: const EdgeInsets.all(ArSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 44,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: ArSpace.sm),
              Text(message, textAlign: TextAlign.center),
              if (onRetry != null) ...[
                const SizedBox(height: ArSpace.md),
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

/// Copertina di un anime nella striscia pieghevole.
///
/// Esposta perche' i test la cercano per nome: verificare "la lista mostra
/// risultati" con un finder costruito su un testo qualsiasi passerebbe anche se
/// la lista non avesse card, mentre con la classe il test controlla davvero
/// quante righe sono a schermo.
///
/// E' una versione senza stato dell'[AnimeCard] perche' nella striscia l'hover
/// non esiste e la cella ha dimensioni fisse: il doppio `HoverRegion` e il
/// bordo che si accende costerebbero animazioni su una lista che si scorre
/// solo col dito.
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
    if (compact) return _compact(context);

    return AnimeCard(
      title: entry.title,
      imageUrl: entry.imageUrl,
      score: entry.score,
      heroTag: entry.heroTag,
      subtitle: entry.factsLabel.isEmpty ? null : entry.factsLabel,
      genres: entry.genres,
      onTap: () => _showDetail(context),
    );
  }

  Widget _compact(BuildContext context) {
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: () => _showDetail(context),
      child: SizedBox(
        width: 124,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _HeroPoster(
              url: entry.imageUrl,
              title: entry.title,
              tag: entry.heroTag,
            ),
            const SizedBox(height: ArSpace.xs),
            Text(
              entry.title,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.3),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  /// Apre la scheda dell'anime.
  ///
  /// Va sulla rotta e non su un foglio perche' l'opera ha troppo contenuto per
  /// stare in mezzo schermo: synopsis, generi, voto e metadati fanno una
  /// pagina. Il foglio, inoltre, non ha un indirizzo: con il "indietro" del
  /// sistema tornerebbe alla ricerca ma senza ricaricare i filtri impostati.
  ///
  /// L'opera viaggia in `extra` perche' la Edge Function non ha una rotta di
  /// dettaglio: l'unica copia dei dati e' quella che la ricerca ha gia'
  /// ricevuto, e perderla significherebbe mostrare una pagina vuota.
  void _showDetail(BuildContext context) {
    context.push(AppRoutes.animeDetail, extra: entry);
  }
}

/// Locandina 2:3 con segnaposto.
///
/// Senza immagine non si lascia lo spazio vuoto: la prima lettera del titolo
/// e' un fallback che almeno dice di cosa si tratta, e un riquadro grigio non
/// distingue "non c'e' immagine" da "non ha ancora caricato".
class _HeroPoster extends StatelessWidget {
  const _HeroPoster({
    required this.url,
    required this.title,
    this.tag,
  });

  final String? url;
  final String title;
  final Object? tag;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    Widget image;
    if (url == null || url!.isEmpty) {
      image = DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(ArRadii.card),
        ),
        child: Center(
          child: Text(
            title.isEmpty ? '?' : title.characters.first.toUpperCase(),
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
          ),
        ),
      );
    } else {
      image = ClipRRect(
        borderRadius: BorderRadius.circular(ArRadii.card),
        child: Image.network(
          url!,
          // `errorBuilder` copre il caso piu' comune: copertine che non esistono
          // piu' su MyAnimeList restano nel catalogo con un URL vecchio.
          errorBuilder: (context, error, stack) => DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(ArRadii.card),
            ),
            child: Icon(
              Icons.broken_image_outlined,
              color: colors.onSurfaceVariant,
            ),
          ),
          fit: BoxFit.cover,
        ),
      );
    }

    // L'hero sta solo sull'immagine. Se avvolgesse anche il segnaposto, la
    // transizione su un anime senza copertina mostrerebbe un rettangolo vuoto
    // che si trasforma in un'immagine: peggio di non avere nulla.
    if (tag == null) return image;

    return AspectRatio(
      aspectRatio: 2 / 3,
      child: Hero(
        tag: tag!,
        flightShuttleBuilder: (context, animation, direction, from, to) =>
            ScaleTransition(scale: animation, child: image),
        child: image,
      ),
    );
  }
}
