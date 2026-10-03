import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/breakpoints.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/transitions.dart';
import '../../../anime/domain/anime.dart';
import '../../../auth/presentation/widgets/auth_scaffold.dart';
import '../../domain/ranking.dart';
import '../ranking_controller.dart';
import '../widgets/rank_podium.dart';

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
    return DecoratedBox(
      // Un bordo in alto invece di un'ombra: la striscia si appoggia a
      // qualcosa di scuro, e un'ombra su fondo scuro non si vede. Il bordo e'
      // l'unico modo di dire "qui comincia un piano diverso".
      decoration: const BoxDecoration(
        color: ArColors.containerLow,
        border: Border(top: BorderSide(color: ArColors.borderSoft)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: ArSpace.md, vertical: ArSpace.sm),
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              _Stat(label: 'Membri', value: stats.memberCount.toDouble(), format: _group),
              const _Divider(),
              _Stat(label: 'Anime votati', value: stats.animeRated.toDouble(), format: _group),
              const _Divider(),
              _Stat(label: 'Voti', value: stats.totalVotes.toDouble(), format: _group),
              const _Divider(),
              _Stat(label: 'Media', value: stats.groupMean, format: _trim),
            ],
          ),
        ),
      ),
    );
  }

  static String _trim(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');

  /// Numeri con il punto come separatore delle migliaia.
  ///
  /// "1.234" e non "1,234" ne' "1.2K": nella scrittura italiana il punto e' il
  /// separatore, e un conteggio abbreviato su un totale che si aggiorna spesso
  /// fa perdere il conto di quanto e' cresciuto.
  static String _group(double value) {
    final digits = value.round().abs().toString();
    final buffer = StringBuffer(value < 0 ? '-' : '');
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write('.');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }
}

/// Filetto verticale fra due statistiche.
///
/// Altezza fissa e non "quanto il vicino": e' un separatore, non una colonna,
/// e se si allineasse al numero piu' alto sembrerebbe parte dei numeri.
class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 26,
      margin: const EdgeInsets.symmetric(horizontal: ArSpace.sm),
      color: ArColors.borderSoft,
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    required this.format,
  });

  final String label;

  /// Valore iniziale dell'animazione, non quello da mostrare subito.
  ///
  /// E' un [double] anche per i conteggi perche' e' il tipo che sa interpolare:
  /// far salire un intero da 0 a 1.234 a passi interi mostrerebbe uno zero per
  /// metta animazione.
  final double value;

  final String Function(double) format;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // I totali del gruppo sono l'unico dato della pagina che cresce senza
          // che l'utente abbia toccato niente: dopo una serata di voti il
          // numero e' salito sotto gli occhi di chi guarda. Contarlo e' il
          // modo piu' economico di dire che il gruppo e' vivo.
          ArCountUp(
            value: value,
            builder: (context, animated) => Text(
              format(animated),
              maxLines: 1,
              style: theme.textTheme.titleMedium?.copyWith(
                color: ArColors.textHigh,
                fontVariations: const [FontVariation('wght', 700)],
              ),
            ),
          ),
          const SizedBox(height: ArSpace.xxs),
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: ArColors.textLow,
              fontVariations: const [FontVariation('wght', 600)],
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
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
    // Il podio si disegna solo se i tre posti ci sono davvero: con una o due
    // righe mostrerebbe una o due colonne sole al centro dello schermo, che non
    // e' un podio. Sotto la soglia restano righe normali.
    final start = rows.length >= RankPodium.places ? RankPodium.places : 0;
    // Il podio mostra i primi tre e la lista li ripeterebbe: due copie della
    // stessa posizione nella stessa schermata si leggono subito come un errore.
    final rest = rows.sublist(start);

    return CustomScrollView(
      controller: _scroll,
      slivers: [
        if (start > 0)
          SliverToBoxAdapter(
            child: RankPodium(
              entries: [
                for (final entry in rows.take(start)) _podiumOf(context, entry),
              ],
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(ArSpace.md, ArSpace.sm, ArSpace.md, ArSpace.lg),
          sliver: SliverList.separated(
            itemCount: rest.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: ArSpace.xs),
            itemBuilder: (context, i) {
              if (i < rest.length) {
                return RankingRow(
                  entry: rest[i],
                  groupId: widget.groupId,
                  // La barra e' relativa al punteggio migliore della pagina:
                  // con il valore assoluto tutte le barre sarebbero lunghe
                  // uguali, perche' i voti stanno tutti dentro una fascia
                  // stretta e non si distinguerebbe nulla.
                  best: _bestScore(rows),
                  // L'onda riparte dal quarto posto: i primi tre sono gia'
                  // arrivati col podio, e rianimarli insieme al resto
                  // cancellerebbe l'effetto del gradino.
                  revealMs: (i * 35).clamp(0, 280),
                );
              }

              return _LoadMore(groupId: widget.groupId, controller: widget.controller);
            },
          ),
        ),
      ],
    );
  }

  /// Il punteggio piu' alto della pagina, base delle barre.
  static double _bestScore(List<RankingEntry> rows) {
    var best = 0.0;
    for (final entry in rows) {
      final score = entry.rankingScore;
      if (score != null && score > best) best = score;
    }
    return best;
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
          padding: const EdgeInsets.fromLTRB(ArSpace.md, ArSpace.sm, ArSpace.md, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              kind.description.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: ArColors.textLow,
                letterSpacing: 0.7,
                fontVariations: const [FontVariation('wght', 600)],
              ),
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

              // Come nella classifica principale: il podio prende i primi tre e
              // la lista riprende dal quarto, ma solo se i tre posti esistono.
              final start = rows.length >= RankPodium.places ? RankPodium.places : 0;
              final rest = rows.sublist(start);

              return RefreshIndicator(
                onRefresh: () =>
                    ref.read(specialRankingProvider((groupId, kind)).notifier).refresh(),
                child: CustomScrollView(
                  slivers: [
                    if (start > 0)
                      SliverToBoxAdapter(
                        child: RankPodium(
                          entries: [
                            for (final entry in rows.take(start))
                              _specialPodiumOf(context, entry),
                          ],
                        ),
                      ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(
                        ArSpace.md,
                        ArSpace.sm,
                        ArSpace.md,
                        ArSpace.lg,
                      ),
                      sliver: SliverList.separated(
                        itemCount: rest.length,
                        separatorBuilder: (_, _) => const SizedBox(height: ArSpace.xs),
                        itemBuilder: (context, i) => SpecialRankingRow(
                          entry: rest[i],
                          revealMs: (i * 35).clamp(0, 280),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// La riga di una classifica speciale come posizione di podio.
///
/// Qui le due metriche non sono media e voti come nella classifica principale ma
/// cambiano a seconda della scheda, quindi non c'e' un numero da mettere in
/// evidenza e uno da no: sul podio la coppia sta sotto il titolo, come in una
/// classifica a due criteri.
PodiumEntry _specialPodiumOf(BuildContext context, SpecialRankingEntry entry) {
  final (valueTitle, valueText) = entry.valueLabel;
  final (secondaryTitle, secondaryText) = entry.secondaryLabel;
  final anime = AnimeEntry(
    externalId: entry.animeId,
    title: entry.title,
    imageUrl: entry.imageUrl,
  );

  return PodiumEntry(
    position: entry.position,
    title: entry.title,
    imageUrl: entry.imageUrl,
    valueText: valueText,
    valueTitle: valueTitle,
    secondaryText: secondaryText,
    secondaryTitle: secondaryTitle,
    heroTag: anime.heroTag,
    onTap: () => context.push(AppRoutes.animeDetail, extra: anime),
  );
}

/// La riga di classifica principale come posizione di podio.
PodiumEntry _podiumOf(BuildContext context, RankingEntry entry) {
  final anime = _animeOf(entry);

  return PodiumEntry(
    position: entry.position,
    title: entry.title,
    imageUrl: entry.imageUrl,
    // Sul podio la media e' il numero grande e i voti vanno sotto con la loro
    // etichetta: la barra di sotto, che nella lista tiene conto di quanto e'
    // vicina al primo posto, qui sarebbe ridondante perche' il gradino del
    // podio dice gia' la stessa cosa.
    valueText: entry.meanScoreLabel ?? '—',
    valueTitle: 'media',
    secondaryText: '${entry.voteCount} ${entry.voteCount == 1 ? 'voto' : 'voti'}',
    secondaryTitle: '',
    heroTag: anime.heroTag,
    onTap: () => context.push(AppRoutes.animeDetail, extra: anime),
  );
}

/// Scheda anime ricostruita da una riga di classifica.
///
/// La riga porta l'id interno di `public.anime` e il minimo dei dati, quindi
/// l'opera viene composta solo con quelli: la scheda mostra la realta' dei dati
/// che ha, senza riempirsi i buchi. Un voto di MyAnimeList o una copertina
/// inventati per far sembrare la scheda completa sarebbero peggio di un
/// dettaglio assente, che almeno si vede che manca.
AnimeEntry _animeOf(RankingEntry entry) => AnimeEntry(
      externalId: entry.animeId,
      title: entry.title,
      japaneseTitle: entry.japaneseTitle,
      imageUrl: entry.imageUrl,
      episodes: entry.episodes,
      year: entry.year,
      genres: entry.genres,
    );

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
  const RankingRow({
    required this.entry,
    required this.groupId,
    this.best,
    this.revealMs = 0,
    super.key,
  });

  final RankingEntry entry;
  final String groupId;

  /// Punteggio piu' alto della pagina, con cui confrontare la barra.
  ///
  /// `null` quando non si conosce: senza riferimento una barra e' una riga di
  /// colore che non dice niente, quindi non si disegna.
  final double? best;

  /// Ritardo di comparsa, per l'onda della lista.
  final int revealMs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final anime = _animeOf(entry);
    final card = _RankingCard(
      entry: entry,
      best: best,
      anime: anime,
      voteButton: _VoteButton(entry: entry, groupId: groupId),
    );

    return ArReveal(
      delayMs: revealMs,
      child: ArPressable(
        onTap: () => context.push(AppRoutes.animeDetail, extra: anime),
        child: Hero(
          tag: anime.heroTag,
          flightShuttleBuilder: (_, animation, _, from, to) =>
              ScaleTransition(scale: animation, child: from.widget),
          child: card,
        ),
      ),
    );
  }
}

/// Il corpo della riga.
///
/// Dentro [RankingRow] e non al suo posto perche' il tocco e' dell'involucro
/// che porta il volo dell'immagine, mentre tutto il resto e' disegno: dividerli
/// evita di dover passare il contesto di navigazione dentro il widget che sa
/// solo come appare una riga.
class _RankingCard extends StatelessWidget {
  const _RankingCard({
    required this.entry,
    required this.best,
    required this.anime,
    required this.voteButton,
  });

  final RankingEntry entry;
  final double? best;
  final AnimeEntry anime;
  final Widget voteButton;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final score = entry.rankingScore;
    // La percentuale si calcola sul punteggio pesato e non sulla media: e' il
    // valore su cui la classifica e' ordinata, quindi la barra e' lunga esattamente
    // quanto lontano l'opera e' dal primo posto.
    final factor = (best == null || best! <= 0 || score == null)
        ? null
        : (score / best!).clamp(0.06, 1.0);

    return Container(
      padding: const EdgeInsets.all(ArSpace.sm),
      decoration: BoxDecoration(
        color: ArColors.container,
        borderRadius: BorderRadius.circular(ArRadii.card),
        // Filo, non ombra: sono venti righe una sotto l'altra, e venti ombre
        // farebbero una parete di grigi invece di una lista.
        border: Border.all(
          color: ArColors.rank(entry.position).withValues(alpha: 0.10),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PositionBadge(entry: entry),
          const SizedBox(width: ArSpace.sm),
          AnimeThumb(
            url: entry.imageUrl,
            title: entry.title,
            size: 52,
            radius: ArRadii.chip,
          ),
          const SizedBox(width: ArSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  _metaOf(entry),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: ArColors.textMid),
                ),
                if (factor != null) ...[
                  const SizedBox(height: ArSpace.xs),
                  _ScoreBar(factor: factor),
                ],
              ],
            ),
          ),
          const SizedBox(width: ArSpace.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                entry.meanScoreLabel ?? '—',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: ArColors.rank(entry.position),
                  fontVariations: const [FontVariation('wght', 700)],
                ),
              ),
              Text(
                '${entry.voteCount} ${entry.voteCount == 1 ? 'voto' : 'voti'}',
                style: theme.textTheme.labelSmall?.copyWith(color: ArColors.textLow),
              ),
            ],
          ),
          voteButton,
        ],
      ),
    );
  }

  /// Dettagli secondari: anno, episodi, generi.
  ///
  /// Uno solo e non un elenco di pastiglie: in una lista di venti righe i
  /// generi ripetuti a ogni riga diventano rumore, e il pezzo utile — l'anno —
  /// finisce in fondo.
  static String _metaOf(RankingEntry entry) {
    final parts = <String>[
      if (entry.year != null) '${entry.year}',
      if (entry.episodes != null) '${entry.episodes} episodi',
      if (entry.genres.isNotEmpty) entry.genres.first,
    ];

    return parts.join(' · ');
  }
}

/// Barra che mostra quanto l'opera e' vicina al primo posto.
///
/// La traccia resta in un colore spento perche' e' il massimo possibile, e il
/// riempimento e' quello del valore: senza la traccia intera la barra perderebbe
/// il punto di riferimento e sembrerebbe un indicatore di caricamento.
class _ScoreBar extends StatelessWidget {
  const _ScoreBar({required this.factor});

  final double factor;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 3,
        child: Stack(
          children: [
            const Positioned.fill(
              child: ColoredBox(color: ArColors.containerHighest),
            ),
            FractionallySizedBox(
              widthFactor: factor,
              child: const DecoratedBox(
                decoration: BoxDecoration(gradient: ArColors.brand),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Riga di una classifica speciale.
class SpecialRankingRow extends StatelessWidget {
  const SpecialRankingRow({required this.entry, this.revealMs = 0, super.key});

  final SpecialRankingEntry entry;

  /// Ritardo di comparsa, per l'onda della lista.
  final int revealMs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (valueTitle, valueText) = entry.valueLabel;
    final (secondaryTitle, secondaryText) = entry.secondaryLabel;
    final anime = AnimeEntry(
      externalId: entry.animeId,
      title: entry.title,
      imageUrl: entry.imageUrl,
    );

    return ArReveal(
      delayMs: revealMs,
      child: ArPressable(
        onTap: () => context.push(AppRoutes.animeDetail, extra: anime),
        child: Container(
          padding: const EdgeInsets.all(ArSpace.sm),
          decoration: BoxDecoration(
            color: ArColors.container,
            borderRadius: BorderRadius.circular(ArRadii.card),
            border: Border.all(
              color: ArColors.rank(entry.position).withValues(alpha: 0.10),
            ),
          ),
          child: Row(
            children: [
              _SimplePosition(position: entry.position),
              const SizedBox(width: ArSpace.sm),
              AnimeThumb(
                url: entry.imageUrl,
                title: entry.title,
                size: 52,
                radius: ArRadii.chip,
              ),
              const SizedBox(width: ArSpace.sm),
              Expanded(
                child: Text(
                  entry.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              const SizedBox(width: ArSpace.sm),
              // Entrambe le metriche hanno etichetta: "8.5" e "3" senza sapere
              // cosa sia ciascuno fanno leggere a indovinare. Le etichette
              // stanno sotto il numero e non accanto, perche' su una riga stretta
              // l'etichetta verrebbe troncata mentre il numero no.
              _Metric(title: valueTitle, text: valueText, highlight: true),
              const SizedBox(width: ArSpace.md),
              _Metric(title: secondaryTitle, text: secondaryText),
            ],
          ),
        ),
      ),
    );
  }
}

/// Numero di posizione delle classifiche speciali.
///
/// Senza variazione e senza medaglia tonda: qui la posizione non e' un premio,
/// e' un indice di lettura. Il riquadro e' quello della classifica principale per
/// non far capire che la pagina e' cambiata.
class _SimplePosition extends StatelessWidget {
  const _SimplePosition({required this.position});

  final int position;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final medal = ArColors.rank(position);
    final top = position <= RankPodium.places;

    return SizedBox(
      width: 30,
      child: Container(
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: top ? medal.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(ArRadii.chip - 2),
          border: Border.all(
            color: top ? medal.withValues(alpha: 0.45) : ArColors.borderSoft,
          ),
        ),
        child: Text(
          '$position',
          style: theme.textTheme.titleSmall?.copyWith(
            color: top ? medal : ArColors.textMid,
            fontVariations: const [FontVariation('wght', 700)],
          ),
        ),
      ),
    );
  }
}

/// Numero con la sua etichetta sotto.
class _Metric extends StatelessWidget {
  const _Metric({
    required this.title,
    required this.text,
    this.highlight = false,
  });

  final String title;
  final String text;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          style: highlight
              ? theme.textTheme.titleMedium?.copyWith(
                  color: ArColors.textHigh,
                  fontVariations: const [FontVariation('wght', 700)],
                )
              : theme.textTheme.bodyLarge?.copyWith(color: ArColors.textMid),
        ),
        Text(
          title.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: ArColors.textLow,
            letterSpacing: 0.6,
          ),
        ),
      ],
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
    final medal = ArColors.rank(entry.position);
    // Il colore della medaglia resta anche sotto il quarto posto, dove diventa
    // grigio: e' lo stesso sistema di colori e non un colore diverso, quindi
    // l'occhio smette di cercare dove finisce il podio e riprende a leggere i
    // numeri.
    final top = entry.position <= RankPodium.places;

    return SizedBox(
      width: 30,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: top ? medal.withValues(alpha: 0.14) : Colors.transparent,
              borderRadius: BorderRadius.circular(ArRadii.chip - 2),
              border: Border.all(
                color: top ? medal.withValues(alpha: 0.45) : ArColors.borderSoft,
              ),
            ),
            child: Text(
              '${entry.position}',
              style: theme.textTheme.titleSmall?.copyWith(
                color: top ? medal : ArColors.textMid,
                fontVariations: const [FontVariation('wght', 700)],
              ),
            ),
          ),
          if (delta != 0) ...[
            const SizedBox(height: ArSpace.xxs),
            // Freccia oltre il segno: il "+3" da solo dice che il numero e'
            // cambiato, la freccia dice in che verso.
            Text(
              '${delta > 0 ? '↑' : '↓'}${delta.abs()}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: delta > 0 ? ArColors.success : ArColors.danger,
                fontVariations: const [FontVariation('wght', 600)],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Nome e immagine di un anime, con i dettagli sotto.
///
/// Usata solo dalla tabella di [RankingTable]: la lista compatta ha la sua
/// [_RankingCard], che ha il proprio ordine — prima la posizione, poi la
/// copertina — e non riuserebbero a stare nella stessa cella.
class _AnimeCell extends StatelessWidget {
  const _AnimeCell({required this.entry});

  final RankingEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = _meta();

    return Row(
      children: [
        AnimeThumb(url: entry.imageUrl, title: entry.title),
        const SizedBox(width: ArSpace.sm),
        Expanded(
          child: Column(
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
                  style: theme.textTheme.bodySmall?.copyWith(color: ArColors.textMid),
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
    final parts = <String>[
      if (entry.year != null) '${entry.year}',
      if (entry.episodes != null) '${entry.episodes} episodi',
      ...entry.genres.take(2),
    ];

    return parts.join(' · ');
  }
}

/// Copertina dell'anime con fallback sull'iniziale.
class AnimeThumb extends StatelessWidget {
  const AnimeThumb({
    this.url,
    required this.title,
    this.size = 40,
    this.radius = 8,
    super.key,
  });

  final String? url;
  final String title;
  final double size;

  /// Angoli della copertina.
  ///
  /// Parametro e non costante perche' la stessa copertina compare a due
  /// scale: arrotondata forte nella card, dove e' piccola e gli angoli vivi
  /// sembrerebbero un taglio, e quasi piatta nella tabella, dove la griglia
  /// chiede celle che si allineino.
  final double radius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final fallback = ColoredBox(
      color: ArColors.containerHighest,
      child: Center(
        child: Text(
          title.trim().isEmpty ? '?' : title.trim()[0].toUpperCase(),
          style: theme.textTheme.titleSmall?.copyWith(
            color: ArColors.textMid,
            fontVariations: const [FontVariation('wght', 700)],
          ),
        ),
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
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
