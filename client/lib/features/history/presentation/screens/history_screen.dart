import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/content_row.dart';
import '../../domain/watch_history.dart';
import '../history_controller.dart';

/// Cronologia: tutto quello che l'utente ha aperto, dal piu' recente.
///
/// Non e' "Continua a guardare": li' c'e' un anime lasciato a meta', qui ogni
/// episodio toccato, compresi quelli finiti. Serve a ritrovare un episodio visto
/// giorni fa di cui non si ricorda piu' la stagione.
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  bool _loadingMore = false;

  Future<void> _refresh() =>
      ref.read(watchHistoryProvider.notifier).refresh();

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      await ref.read(watchHistoryProvider.notifier).loadMore();
    } catch (error) {
      if (!mounted) return;
      final message = error is AppFailure
          ? error.message
          : 'Non si riesce a caricare altro. Riprova.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(watchHistoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Cronologia')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: history.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => ListView(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: ArSpace.xxl),
                child: ErrorState(
                  message: error is AppFailure
                      ? error.message
                      : 'Cronologia non disponibile. Riprova.',
                  onRetry: _refresh,
                ),
              ),
            ],
          ),
          data: (items) => items.isEmpty
              ? const _Empty()
              : _HistoryList(
                  items: items,
                  hasMore: ref.read(watchHistoryProvider.notifier).hasMore,
                  loadingMore: _loadingMore,
                  onLoadMore: _loadMore,
                ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    // `ListView` e non `Center`: senza un figlio scorrevole il
    // `RefreshIndicator` non ha niente da tirare e non parte.
    return ListView(
      children: const [
        Padding(
          padding: EdgeInsets.only(top: ArSpace.xxl),
          child: EmptyState(
            icon: Icons.history,
            title: 'Ancora niente da ricordare',
            message: 'Gli episodi che apri compaiono qui, '
                'dal piu\' recente, cosi\' ritrovi quello che avevi lasciato.',
          ),
        ),
      ],
    );
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({
    required this.items,
    required this.hasMore,
    required this.loadingMore,
    required this.onLoadMore,
  });

  final List<WatchHistoryItem> items;
  final bool hasMore;
  final bool loadingMore;
  final Future<void> Function() onLoadMore;

  @override
  Widget build(BuildContext context) {
    final page = ArSpace.page(context);

    // Raggruppamento per giorno: una lista piatta di cinquanta righe con la
    // stessa data sotto ognuna e' illeggibile, mentre "Oggi" / "Ieri" dice subito
    // quanto indietro si sta scavando.
    final groups = <String, List<WatchHistoryItem>>{};
    for (final item in items) {
      groups.putIfAbsent(_dayLabel(item.updatedAt), () => []).add(item);
    }

    return ListView(
      padding: EdgeInsets.fromLTRB(page.left, ArSpace.md, page.right, ArSpace.xxl),
      children: [
        for (final entry in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: ArSpace.sm, bottom: ArSpace.sm),
            child: Text(
              entry.key,
              style: const TextStyle(
                fontFamily: AppTheme.displayFont,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                fontVariations: [FontVariation('wght', 700)],
                color: ArColors.textMid,
                letterSpacing: -0.2,
              ),
            ),
          ),
          for (final item in entry.value) ...[
            _HistoryTile(item: item),
            const SizedBox(height: ArSpace.sm),
          ],
        ],
        const SizedBox(height: ArSpace.xs),
        if (hasMore)
          Center(
            child: OutlinedButton.icon(
              onPressed: loadingMore ? null : onLoadMore,
              icon: loadingMore
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.expand_more),
              label: Text(loadingMore ? 'Carico...' : 'Carica altri'),
            ),
          ),
      ],
    );
  }
}

class _HistoryTile extends ConsumerWidget {
  const _HistoryTile({required this.item});

  final WatchHistoryItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Material(
      color: ArColors.containerLow,
      borderRadius: BorderRadius.circular(ArRadii.card),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // Al ritorno dall'episodio la riga e' cambiata — posizione, o segnata
        // finita: la cronologia si rilegge invece di restare a com'era quando
        // si e' partiti.
        onTap: () async {
          await context.push(
            AppRoutes.episode(item.animeId, item.episodeId),
            extra: item.animeTitle,
          );
          await ref.read(watchHistoryProvider.notifier).refresh();
        },
        child: Padding(
          padding: const EdgeInsets.all(ArSpace.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Thumbnail(url: item.imageUrl, title: item.animeTitle),
              const SizedBox(width: ArSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.animeTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.episodeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: ArSpace.xs),
                    Row(
                      children: [
                        Icon(
                          item.completed
                              ? Icons.check_circle_outline
                              : Icons.play_circle_outline,
                          size: 14,
                          color: item.completed
                              ? ArColors.success
                              : ArColors.textLow,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          item.progressLabel,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: item.completed
                                ? ArColors.success
                                : ArColors.textLow,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: ArSpace.xs),
              const Icon(Icons.chevron_right, color: ArColors.textLow, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

/// Locandina in miniatura 2:3.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.url, required this.title});

  final String? url;
  final String title;

  static const double _width = 54;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    final placeholder = ColoredBox(
      color: colors.surfaceContainerHigh,
      child: Center(
        child: Text(
          title.isEmpty ? '?' : title.characters.first.toUpperCase(),
          style: TextStyle(
            fontFamily: AppTheme.displayFont,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            fontVariations: const [FontVariation('wght', 700)],
            color: colors.onSurfaceVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(ArRadii.control - 4),
      child: SizedBox(
        width: _width,
        height: _width * 3 / 2,
        child: url == null || url!.isEmpty
            ? placeholder
            : CachedNetworkImage(
                imageUrl: url!,
                fit: BoxFit.cover,
                placeholder: (_, _) => placeholder,
                errorWidget: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}

/// Etichetta del giorno per una voce della cronologia.
///
/// "Oggi" e "Ieri" invece della data: sono i due giorni in cui si cerca quasi
/// sempre qualcosa, e chiamarli per nome e' piu' veloce che leggere un numero.
String _dayLabel(DateTime? at) {
  if (at == null) return 'Meno recenti';

  final local = at.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diff = today.difference(day).inDays;

  if (diff <= 0) return 'Oggi';
  if (diff == 1) return 'Ieri';
  return _historyDateFormat.format(local);
}

/// Costruito una volta: `DateFormat` non e' banale da creare a ogni build.
final DateFormat _historyDateFormat = _italianDateFormat();

DateFormat _italianDateFormat() {
  // Senza questa inizializzazione `intl` conosce solo l'inglese e chiamare
  // `DateFormat` con una locale non caricata solleva.
  initializeDateFormatting('it');
  return DateFormat('d MMMM y', 'it');
}
