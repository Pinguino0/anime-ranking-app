import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/breakpoints.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/content_row.dart';
import '../../../core/ui/hero_banner.dart';
import '../../../core/ui/transitions.dart';
import '../home_controller.dart';
import 'home_sections.dart';

/// Banner in evidenza, con le due azioni reali.
///
/// Il pulsante principale apre i dettagli e non la riproduzione: dalla home non
/// si sa quale episodio riprendere, e un "Guarda" che porta a una lista non
/// aperta prometterebbe una cosa che non mantiene. La riproduzione resta a un
/// tocco di distanza, dalla scheda.
class HomeHero extends ConsumerWidget {
  const HomeHero({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final featured = ref.watch(featuredAnimeProvider);

    final entry = featured.asData?.value;
    if (entry == null) {
      // In caricamento lo scheletro; a caricamento finito (errore oppure
      // catalogo vuoto) l'invito alla ricerca, che e' di per se' una cosa da
      // fare. Un guasto qui non diventa un banner di errore.
      return featured.isLoading
          ? const HomeHeroSkeleton()
          : const _HeroEmpty();
    }

    final community = ref.watch(featuredCommunityScoreProvider);
    final meta = [
      if (entry.factsLabel.isNotEmpty) entry.factsLabel,
      if (community != null) 'Voto AnimeRank ${community.valueLabel.$2}',
    ].join(' · ');

    return ArReveal(
      // Nessun ritardo: e' la prima cosa che si vede e deve esserci subito.
      child: HeroBanner(
        title: entry.displayTitle,
        imageUrl: entry.imageUrl,
        eyebrow: 'In evidenza',
        meta: meta.isEmpty ? null : meta,
        subtitle: shortSynopsis(entry.synopsis),
        primaryLabel: 'Dettagli',
        primaryIcon: Icons.info_outline_rounded,
        onTap: () => context.push(AppRoutes.animeDetail, extra: entry),
        trailing: entry.id == null
            ? null
            : HomeWatchlistButton(animeId: entry.id!),
      ),
    );
  }
}

/// Scheletro del banner: stessa altezza del banner vero.
class HomeHeroSkeleton extends StatelessWidget {
  const HomeHeroSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    // Stessa altezza che prendera' il banner vero e nessun margine: uno
    // scheletro piu' corto farebbe assestare la pagina di colpo quando i dati
    // arrivano, e quella scossa e' quello che si percepisce come "l'app
    // sta pensando".
    final height = Breakpoints.fromContext(context).isExpanded ? 380.0 : 300.0;
    return SkeletonBox(height: height, radius: 0);
  }
}

/// Nessuna opera in evidenza: invito alla ricerca.
///
/// Non e' un errore ed e' scritto come un invito: il catalogo puo' essere vuoto
/// perche' nessuno ha ancora cercato nulla, e la ricerca e' esattamente la cosa
/// da fare.
class _HeroEmpty extends StatelessWidget {
  const _HeroEmpty();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final padding = ArSpace.page(context);

    return Container(
      width: double.infinity,
      margin: EdgeInsets.fromLTRB(
        padding.left,
        ArSpace.md,
        padding.right,
        ArSpace.md,
      ),
      padding: const EdgeInsets.all(ArSpace.lg),
      decoration: BoxDecoration(
        gradient: ArColors.subtle,
        borderRadius: BorderRadius.circular(ArRadii.card),
        border: Border.all(color: ArColors.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Benvenuto su AnimeRank', style: theme.textTheme.titleLarge),
          const SizedBox(height: ArSpace.xs),
          Text(
            'Cerca un anime per riempire il catalogo: dalla scheda, quella che '
            'salvi riempie la tua lista e il resto della home.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: ArColors.textMid,
            ),
          ),
          const SizedBox(height: ArSpace.md),
          Align(
            alignment: Alignment.centerLeft,
            child: ArGradientButton(
              label: 'Cerca un anime',
              icon: Icons.search,
              onPressed: () => context.push(AppRoutes.animeSearch),
            ),
          ),
        ],
      ),
    );
  }
}
