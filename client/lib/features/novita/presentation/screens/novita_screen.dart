import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/anime_card.dart';
import '../../../../core/ui/content_row.dart';
import '../../../anime/domain/anime.dart';
import '../../../history/domain/watch_history.dart';
import '../../../history/presentation/history_controller.dart';
import '../../../history/presentation/widgets/continue_watching_card.dart';
import '../../novita_controller.dart';

/// Pagina "Novita'": cosa c'e' di nuovo, in tre righe.
///
/// E' una pagina a se' e non una sezione della home. La home risponde a "cosa
/// guardo", con banner e righe di catalogo; questa risponde a "cos'e' cambiato",
/// con solo cio' che e' appena uscito (in uscita, nuovi episodi) e cio' che si
/// stava guardando. Tenerle separate evita che le due domande si mescolino.
class NovitaScreen extends ConsumerWidget {
  const NovitaScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final upcoming = ref.watch(upcomingAnimeProvider);
    final recent = ref.watch(recentEpisodesProvider);
    final continueWatching = ref.watch(continueWatchingProvider);

    // Il primo caricamento mostra lo scheletro; dopo, un aggiornamento tira le
    // righe vecchie invece di far sparire la pagina.
    final firstLoad = upcoming.isLoading && recent.isLoading;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () => _refresh(ref),
        child: CustomScrollView(
          // Il tiro verso il basso resta possibile anche quando la pagina e'
          // piu' corta dello schermo: senza, l'aggiornamento sarebbe
          // irraggiungibile proprio nel caso piu' probabile (poco di nuovo).
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppBar(
              pinned: true,
              floating: true,
              toolbarHeight: 62,
              backgroundColor: ArColors.bg,
              titleSpacing: ArSpace.page(context).left,
              title: Text(
                'Novita\'',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (firstLoad)
              const SliverToBoxAdapter(child: RowsSkeleton())
            else
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ..._sections(
                      context,
                      ref,
                      upcoming,
                      recent,
                      continueWatching,
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(upcomingAnimeProvider);
    ref.invalidate(recentEpisodesProvider);
    ref.invalidate(continueWatchingProvider);
    await Future.wait([
      ref.read(upcomingAnimeProvider.future),
      ref.read(recentEpisodesProvider.future),
    ]);
  }

  List<Widget> _sections(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<AnimeEntry>> upcoming,
    AsyncValue<List<AnimeEntry>> recent,
    AsyncValue<List<ContinueWatchingItem>> continueWatching,
  ) {
    final widgets = <Widget>[];

    final upcomingEntries = upcoming.asData?.value ?? const <AnimeEntry>[];
    if (upcomingEntries.isNotEmpty) {
      widgets.add(_animeRow(
        'In uscita',
        'Le uscite della stagione corrente',
        upcomingEntries,
      ));
    }

    final recentEntries = recent.asData?.value ?? const <AnimeEntry>[];
    if (recentEntries.isNotEmpty) {
      widgets.add(_animeRow(
        'Nuovi episodi',
        'Le ultime puntate aggiunte',
        recentEntries,
      ));
    }

    final items =
        continueWatching.asData?.value ?? const <ContinueWatchingItem>[];
    if (items.isNotEmpty) {
      widgets.add(_continueRow(ref, items));
    }

    if (widgets.isNotEmpty) return widgets;

    // Niente da mostrare: se e' un guasto di rete lo si dice e si offre il
    // riprova; altrimenti si spiega che non c'e' nulla di nuovo, che e'
    // un'informazione e non un errore.
    final page = ArSpace.page(context).left;
    final hasError = upcoming.hasError || recent.hasError;
    return [
      Padding(
        padding: EdgeInsets.symmetric(horizontal: page),
        child: hasError
            ? ErrorState(
                message:
                    'Non riesco a leggere le novita\'. Controlla la rete e riprova.',
                onRetry: () => _refresh(ref),
              )
            : const EmptyState(
                icon: Icons.new_releases_outlined,
                title: 'Nessuna novita\'',
                message: 'Per ora non c\'e\' niente di nuovo. Torna piu\' '
                    'tardi: qui compaiono le uscite e le puntate appena aggiunte.',
              ),
      ),
    ];
  }

  Widget _animeRow(String title, String subtitle, List<AnimeEntry> entries) {
    return ContentRow(
      title: title,
      subtitle: subtitle,
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final entry = entries[i];
        return AnimeCard(
          title: entry.displayTitle,
          imageUrl: entry.imageUrl,
          score: entry.score,
          onTap: () => context.push(AppRoutes.animeDetail, extra: entry),
        );
      },
    );
  }

  /// Riga "Continua a guardare".
  ///
  /// Il tocco riprende l'episodio, non apre la scheda: e' quello che si vuole
  /// fare da una card di riprendi. Al ritorno la riga si rilegge, perche'
  /// l'episodio e' avanzato.
  Widget _continueRow(WidgetRef ref, List<ContinueWatchingItem> items) {
    return ContentRow(
      title: 'Continua a guardare',
      subtitle: 'Riprendi dall\'episodio dove eri rimasto',
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        return ContinueWatchingCard(
          item: item,
          onTap: () async {
            await context.push(
              AppRoutes.episode(item.animeId, item.episodeId),
              extra: item.animeTitle,
            );
            ref.invalidate(continueWatchingProvider);
          },
        );
      },
    );
  }
}
