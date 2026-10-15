import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/anime_card.dart';
import '../../../core/ui/section_header.dart';
import '../../../core/ui/transitions.dart';
import '../../anime/domain/anime.dart';
import '../../history/domain/watch_history.dart';
import '../../history/presentation/history_controller.dart';
import '../../history/presentation/widgets/continue_watching_card.dart';
import '../../novita/novita_controller.dart';
import '../../ranking/domain/ranking.dart';
import '../../ranking/presentation/ranking_controller.dart';
import '../../watchlist/domain/watchlist.dart';
import '../../watchlist/presentation/watchlist_controller.dart';
import '../domain/friend_activity.dart';
import '../home_controller.dart';
import '../widgets/home_header.dart';
import '../widgets/home_hero.dart';
import '../widgets/home_sections.dart';

/// Home di AnimeRank.
///
/// Le sezioni sono nell'ordine in cui si affrontano le domande di chi apre
/// l'app: "cosa stavo guardando", "cosa ho visto", "cosa c'e' di nuovo", "cosa
/// guardano gli altri", "cosa potrei guardare". Ognuna e' un widget a se' che
/// osserva i propri provider: un caricamento lento del feed social non ricostruisce
/// il catalogo, e un suo errore non spegne il resto della pagina.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: RefreshIndicator(
        // La home si aggiorna quando lo si chiede, non a ogni ritorno da
        // un'altra schermata: altrimenti uscire da una scheda e rientrare
        // rifarebbe le stesse richieste. Il gesto di tirare e' quello che
        // l'utente si aspetta aggiorni i numeri.
        onRefresh: () => _refresh(ref),
        child: const CustomScrollView(
          slivers: [
            HomeHeader(),
            SliverToBoxAdapter(child: HomeHero()),
            SliverToBoxAdapter(child: _ContinueSection()),
            SliverToBoxAdapter(child: _RecentSection()),
            SliverToBoxAdapter(child: _LatestSection()),
            SliverToBoxAdapter(child: _PopularSection()),
            SliverToBoxAdapter(child: _CommunitySection()),
            SliverToBoxAdapter(child: _WatchlistSection()),
            SliverToBoxAdapter(child: _RecommendedSection()),
            SliverToBoxAdapter(child: _SeasonSection()),
            SliverToBoxAdapter(child: _FriendsSection()),
            SliverToBoxAdapter(child: _RandomSection()),
            SliverToBoxAdapter(child: SizedBox(height: ArSpace.xl)),
          ],
        ),
      ),
    );
  }

  /// Rilegge tutte le fonti della home.
  ///
  /// Si invalidano i provider e non si aspetta ciascuno: le sezioni mostrano da
  /// sole il proprio stato, e bloccare l'indicatore su dodici richieste lo
  /// farebbe girare a lungo senza motivo. Si aspettano le due del banner, che
  /// sono quelle la cui assenza si nota di piu'.
  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(continueWatchingProvider);
    ref.invalidate(watchHistoryProvider);
    ref.invalidate(upcomingAnimeProvider);
    ref.invalidate(recentEpisodesProvider);
    ref.invalidate(popularAnimeProvider);
    ref.invalidate(featuredAnimeProvider);
    ref.invalidate(friendActivityProvider);
    ref.invalidate(recommendedAnimeProvider);
    ref.invalidate(myListProvider);
    ref.invalidate(randomAnimeProvider);

    final group = ref.read(primaryGroupProvider).asData?.value;
    if (group != null) {
      ref.invalidate(
        specialRankingProvider((group.id, SpecialRankingKind.top)),
      );
      ref.invalidate(rankingProvider(group.id));
    }

    try {
      await ref.read(featuredAnimeProvider.future);
      await ref.read(popularAnimeProvider.future);
    } on Exception {
      // Un guasto a questo livello non deve far fallire il gesto: la sezione
      // interessata mostrera' il proprio messaggio, e le altre restano in
      // piedi.
    }
  }
}

/// 3. Continua a guardare.
class _ContinueSection extends ConsumerWidget {
  const _ContinueSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return HomeSection<ContinueWatchingItem>(
      title: 'Continua a guardare',
      subtitle: 'Riprendi esattamente da dove eri rimasto',
      value: ref.watch(continueWatchingProvider),
      onRetry: () => ref.invalidate(continueWatchingProvider),
      // Il tocco riprende l'episodio invece di aprire la scheda: e' l'azione
      // che l'utente stava per fare, e la scheda resta a un tocco dalla lista.
      itemBuilder: (context, item) => ContinueWatchingCard(
        item: item,
        onTap: () async {
          await context.push(
            AppRoutes.episode(item.animeId, item.episodeId),
            extra: item.animeTitle,
          );
          // Guardato qualcosa, il punto di ripresa e' cambiato: si rileggono
          // solo le due righe che ne dipendono.
          if (context.mounted) {
            ref.invalidate(continueWatchingProvider);
            ref.invalidate(watchHistoryProvider);
          }
        },
      ),
    );
  }
}

/// 4. Guardati di recente.
class _RecentSection extends ConsumerWidget {
  const _RecentSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(watchHistoryProvider);
    final inProgress = {
      for (final item
          in ref.watch(continueWatchingProvider).asData?.value ??
              const <ContinueWatchingItem>[])
        item.animeId,
    };

    return HomeSection<WatchHistoryItem>(
      title: 'Guardati di recente',
      subtitle: 'Un anime per riga: gli episodi aperti o completati',
      onSeeAll: () => context.push(AppRoutes.watchHistory),
      value: history.whenData(
        (rows) => recentlyWatched(rows, excludeAnimeIds: inProgress),
      ),
      onRetry: () => ref.read(watchHistoryProvider.notifier).refresh(),
      itemBuilder: (context, item) => HomePosterCard(
        title: item.animeTitle,
        imageUrl: item.imageUrl,
        subtitle: _recentSubtitle(item),
        badge: HomeBadge(
          label: item.completed ? 'Visto' : 'Aperto',
          color: item.completed ? ArColors.completed : ArColors.watching,
          icon: item.completed ? Icons.check_rounded : Icons.play_arrow_rounded,
        ),
        onTap: () => context.push(
          AppRoutes.episode(item.animeId, item.episodeId),
          extra: item.animeTitle,
        ),
      ),
    );
  }

  /// "Episodio 7 · 2 g": il numero dice cosa, la data dice quanto e' recente.
  static String _recentSubtitle(WatchHistoryItem item) {
    final at = item.updatedAt;
    if (at == null) return item.episodeLabel;
    return '${item.episodeLabel} · ${relativeDate(at)}';
  }
}

/// 5. Ultime novita'.
class _LatestSection extends ConsumerWidget {
  const _LatestSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return HomeSection<AnimeEntry>(
      title: 'Ultime novità',
      subtitle: 'Le puntate entrate per ultime nel catalogo',
      onSeeAll: () => context.push(AppRoutes.novita),
      value: ref.watch(recentEpisodesProvider),
      onRetry: () => ref.invalidate(recentEpisodesProvider),
      itemBuilder: (context, entry) => AnimeCard(
        title: entry.displayTitle,
        imageUrl: entry.imageUrl,
        score: entry.score,
        subtitle: entry.factsLabel.isEmpty ? null : entry.factsLabel,
        genres: entry.genres,
        badge: entry.status == null
            ? null
            : HomeBadge(
                label: entry.status!.label,
                color: airStatusColor(entry.status!),
              ),
        onTap: () => context.push(AppRoutes.animeDetail, extra: entry),
      ),
    );
  }
}

/// 6. Piu' popolari.
class _PopularSection extends ConsumerWidget {
  const _PopularSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return HomeSection<AnimeEntry>(
      title: 'Più popolari',
      subtitle: 'Quante persone li hanno in lista, non quanto valgono',
      value: ref.watch(popularAnimeProvider),
      onRetry: () => ref.invalidate(popularAnimeProvider),
      itemBuilder: (context, entry) => AnimeCard(
        title: entry.displayTitle,
        imageUrl: entry.imageUrl,
        // Nessun voto: il dato che ordina questa riga e' la popolarita', e la
        // stella mostrerebbe il voto esterno, che e' un'altra classifica.
        score: null,
        subtitle: entry.popularity == null
            ? null
            : '${compactNumber(entry.popularity!)} in lista',
        genres: entry.genres,
        onTap: () => context.push(AppRoutes.animeDetail, extra: entry),
      ),
    );
  }
}

/// 7. Piu' votati dalla community.
class _CommunitySection extends ConsumerWidget {
  const _CommunitySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final group = ref.watch(primaryGroupProvider).asData?.value;

    return HomeSection<SpecialRankingEntry>(
      title: 'Più votati dalla community',
      subtitle: group == null ? null : 'La media dei voti di ${group.name}',
      onSeeAll: group == null
          ? null
          : () => context.push(AppRoutes.ranking(group.id)),
      value: ref.watch(communityTopProvider),
      onRetry: group == null
          ? null
          : () => ref.invalidate(
              specialRankingProvider((group.id, SpecialRankingKind.top)),
            ),
      itemBuilder: (context, row) => AnimeCard(
        title: row.displayTitle,
        imageUrl: row.imageUrl,
        // La media sta scritta per esteso nel sottotitolo, insieme ai voti:
        // e' un voto del gruppo, e va detto che lo e'.
        subtitle:
            '${row.valueLabel.$2} di media · ${row.secondaryLabel.$2} voti',
        badge: HomeBadge(
          label: '#${row.position}',
          color: ArColors.rank(row.position),
        ),
        onTap: () =>
            context.push(AppRoutes.animeDetail, extra: _entryOfSpecial(row)),
      ),
    );
  }
}

/// 8. Riprendi dalla Watchlist.
class _WatchlistSection extends ConsumerWidget {
  const _WatchlistSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return HomeSection<WatchlistEntry>(
      title: 'Riprendi dalla Watchlist',
      subtitle: 'Da vedere e in visione, senza i titoli finiti o lasciati',
      onSeeAll: () => context.push(AppRoutes.myList),
      value: ref.watch(myListProvider).whenData(watchlistResume),
      onRetry: () => ref.read(myListProvider.notifier).refresh(),
      itemBuilder: (context, entry) => HomePosterCard(
        title: entry.displayTitle,
        imageUrl: entry.imageUrl,
        subtitle: entry.hasStarted
            ? 'Episodio ${entry.episodeLabel}'
            : entry.status.label,
        badge: HomeBadge(
          label: entry.status.label,
          color: watchStatusColor(entry.status),
        ),
        // La barra compare solo se il totale degli episodi e' noto: altrove
        // sarebbe una percentuale inventata.
        progress: entry.progress,
        onTap: () =>
            context.push(AppRoutes.animeDetail, extra: _entryOfWatchlist(entry)),
      ),
    );
  }
}

/// 9. Consigliati per te.
class _RecommendedSection extends ConsumerWidget {
  const _RecommendedSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final genre = ref.watch(recommendationSignalProvider).genre;

    return HomeSection<AnimeEntry>(
      title: 'Consigliati per te',
      subtitle: genre == null
          ? null
          : 'Altri titoli $genre, come quelli che segui',
      value: ref.watch(recommendedAnimeProvider),
      onRetry: () => ref.invalidate(recommendedAnimeProvider),
      itemBuilder: (context, entry) => AnimeCard(
        title: entry.displayTitle,
        imageUrl: entry.imageUrl,
        score: entry.score,
        subtitle: entry.factsLabel.isEmpty ? null : entry.factsLabel,
        genres: entry.genres,
        onTap: () => context.push(AppRoutes.animeDetail, extra: entry),
      ),
    );
  }
}

/// 10. Stagione corrente.
class _SeasonSection extends ConsumerWidget {
  const _SeasonSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // L'opera in evidenza e' gia' nel banner qui sopra: ripeterla come prima
    // card della riga sembrerebbe un contenuto duplicato.
    final featuredId = ref.watch(featuredAnimeProvider).asData?.value?.id;

    return HomeSection<AnimeEntry>(
      title: 'Stagione corrente',
      subtitle: currentSeasonLabel(DateTime.now()),
      value: ref.watch(upcomingAnimeProvider).whenData(
        (rows) => [
          for (final entry in rows)
            if (entry.id != featuredId) entry,
        ],
      ),
      onRetry: () => ref.invalidate(upcomingAnimeProvider),
      itemBuilder: (context, entry) => AnimeCard(
        title: entry.displayTitle,
        imageUrl: entry.imageUrl,
        score: entry.score,
        subtitle: entry.factsLabel.isEmpty ? null : entry.factsLabel,
        genres: entry.genres,
        badge: entry.status == null
            ? null
            : HomeBadge(
                label: entry.status!.label,
                color: airStatusColor(entry.status!),
              ),
        onTap: () => context.push(AppRoutes.animeDetail, extra: entry),
      ),
    );
  }
}

/// 11. Attivita' degli amici.
class _FriendsSection extends ConsumerWidget {
  const _FriendsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return HomeSection<FriendActivity>(
      title: 'Attività degli amici',
      subtitle: 'Gli ultimi voti e salvataggi dei membri dei tuoi gruppi',
      value: ref.watch(friendActivityProvider),
      onRetry: () => ref.invalidate(friendActivityProvider),
      itemBuilder: (context, activity) => FriendActivityCard(
        activity: activity,
        onTap: () =>
            context.push(AppRoutes.animeDetail, extra: activity.anime),
      ),
    );
  }
}

/// 12. Anime casuale.
class _RandomSection extends ConsumerWidget {
  const _RandomSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = ref.watch(randomAnimeProvider);
    // Catalogo vuoto: nessuna card, e nessuna sezione vuota da riempire.
    if (entry == null) return const SizedBox.shrink();

    return _RandomCard(
      entry: entry,
      onShuffle: () => ref.read(randomAnimeProvider.notifier).shuffle(),
    );
  }
}

/// Card larga dell'anime estratto a caso.
///
/// Non una card del carosello: e' l'ultima sezione e invita a fermarsi, quindi
/// ha spazio per la sinossi e due azioni. La disposizione a riga (locandina a
/// sinistra, testo a destra) regge anche su schermo stretto, dove impilare
/// costringerebbe a scorrere per arrivare ai pulsanti.
class _RandomCard extends StatelessWidget {
  const _RandomCard({required this.entry, required this.onShuffle});

  final AnimeEntry entry;
  final VoidCallback onShuffle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final padding = ArSpace.page(context);
    final genres = entry.genres.take(3).join(' · ');
    final synopsis = shortSynopsis(entry.synopsis, limit: 260);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Anime casuale',
          subtitle: 'Un titolo estratto dal catalogo',
          action: onShuffle,
          actionLabel: 'Un altro',
        ),
        const SizedBox(height: ArSpace.sm),
        Padding(
          padding: EdgeInsets.fromLTRB(
            padding.left,
            0,
            padding.right,
            ArSpace.md,
          ),
          child: Container(
            padding: const EdgeInsets.all(ArSpace.md),
            decoration: BoxDecoration(
              color: ArColors.containerLow,
              borderRadius: BorderRadius.circular(ArRadii.card),
              border: Border.all(color: ArColors.borderSoft),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 104,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(ArRadii.control),
                    child: AspectRatio(
                      aspectRatio: 2 / 3,
                      child: HomePosterImage(
                        url: entry.imageUrl,
                        title: entry.displayTitle,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: ArSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.displayTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      if (genres.isNotEmpty) ...[
                        const SizedBox(height: ArSpace.xxs),
                        Text(
                          genres,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: ArColors.textLow,
                          ),
                        ),
                      ],
                      if (synopsis != null) ...[
                        const SizedBox(height: ArSpace.xs),
                        Text(
                          synopsis,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: ArColors.textMid,
                          ),
                        ),
                      ],
                      const SizedBox(height: ArSpace.md),
                      Wrap(
                        spacing: ArSpace.sm,
                        runSpacing: ArSpace.xs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          ArGradientButton(
                            label: 'Scopri',
                            icon: Icons.explore_outlined,
                            onPressed: () => context.push(
                              AppRoutes.animeDetail,
                              extra: entry,
                            ),
                          ),
                          if (entry.id != null)
                            HomeWatchlistButton(
                              animeId: entry.id!,
                              onSurface: true,
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
      ],
    );
  }
}

/// Scheda anime ricostruita da una riga di watchlist.
///
/// Come `animeEntryOf`, ma con l'`id` interno valorizzato: la scheda lo usa per
/// il pulsante "Guarda", e senza resterebbe un'opera su cui non si puo' fare
/// nulla.
AnimeEntry _entryOfWatchlist(WatchlistEntry entry) => AnimeEntry(
  id: entry.animeId,
  externalId: entry.animeId,
  title: entry.title,
  italianTitle: entry.italianTitle,
  imageUrl: entry.imageUrl,
  episodes: entry.episodes,
  year: entry.year,
  genres: entry.genres,
  status: entry.airing ? AnimeAirStatus.airing : null,
);

/// Scheda anime ricostruita da una riga di classifica speciale.
AnimeEntry _entryOfSpecial(SpecialRankingEntry row) => AnimeEntry(
  id: row.animeId,
  externalId: row.animeId,
  title: row.title,
  italianTitle: row.italianTitle,
  imageUrl: row.imageUrl,
);
