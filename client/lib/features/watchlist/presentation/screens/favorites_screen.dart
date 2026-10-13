import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/anime_card.dart';
import '../../../../core/ui/content_row.dart';
import '../../domain/watchlist.dart';
import '../watchlist_anime.dart';
import '../watchlist_controller.dart';

/// Preferiti: le opere segnate con la stella, da tutte le liste.
///
/// Un posto solo per quello che piace davvero. Non e' un filtro della watchlist:
/// li' la stella serve a ritrovare una voce dentro una lista lunga, qui e' il
/// contenuto stesso, e comprende anche i preferiti segnati in un gruppo — che
/// altrimenti si vedrebbero solo entrando in quel gruppo.
class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favorites = ref.watch(favoritesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Preferiti')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(favoritesProvider),
        child: favorites.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => ListView(
            children: [
              Padding(
                padding: const EdgeInsets.only(top: ArSpace.xxl),
                child: ErrorState(
                  message: error is AppFailure
                      ? error.message
                      : 'Preferiti non disponibili. Riprova.',
                  onRetry: () => ref.invalidate(favoritesProvider),
                ),
              ),
            ],
          ),
          data: (entries) => entries.isEmpty
              ? const _Empty()
              : _FavoritesGrid(entries: entries),
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
    // `RefreshIndicator` non ha niente da tirare.
    return ListView(
      children: const [
        Padding(
          padding: EdgeInsets.only(top: ArSpace.xxl),
          child: EmptyState(
            icon: Icons.star_border,
            title: 'Nessun preferito',
            message: 'Segna un anime con la stella, dalla sua scheda o dalla tua '
                'lista, e lo ritrovi qui: da qualunque lista arrivi.',
          ),
        ),
      ],
    );
  }
}

class _FavoritesGrid extends StatelessWidget {
  const _FavoritesGrid({required this.entries});

  final List<WatchlistEntry> entries;

  @override
  Widget build(BuildContext context) {
    final spacing = ArSpace.sm;
    final padding = ArSpace.page(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - padding.left - padding.right;

        // Stesse soglie della griglia del catalogo: un numero intero di
        // locandine che arriva al bordo, senza card tagliate a meta'.
        const minCell = 120.0;
        const maxCell = 180.0;
        final fit = (width / maxCell).ceil();
        final readable = (width / minCell).floor().clamp(2, 12);
        final columns = fit.clamp(2, readable);
        final cell = (width - spacing * (columns - 1)) / columns;

        return GridView.builder(
          padding: EdgeInsets.fromLTRB(
            padding.left,
            ArSpace.md,
            padding.right,
            ArSpace.xxl,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: cell * 3 / 2,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
          ),
          itemCount: entries.length,
          itemBuilder: (context, i) {
            final entry = entries[i];
            final anime = animeEntryOf(entry);

            return AnimeCard(
              title: entry.displayTitle,
              imageUrl: entry.imageUrl,
              heroTag: anime.heroTag,
              subtitle: entry.meta.isEmpty ? null : entry.meta,
              genres: entry.genres,
              onTap: () => context.push(AppRoutes.animeDetail, extra: anime),
            );
          },
        );
      },
    );
  }
}
