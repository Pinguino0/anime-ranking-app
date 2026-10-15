import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';

/// Testata della home: il nome del servizio e la ricerca.
///
/// Compatta di proposito. Il saluto con il nome utente c'era prima e occupava
/// due righe per dire una cosa che l'utente sa gia': qui lo spazio va al
/// contenuto, che e' quello per cui si apre la home.
///
/// E' una [SliverAppBar] perche' deve fissarsi in cima quando si scorre: senza,
/// la lente sparirebbe dopo la prima riga e per cercare bisognerebbe risalire
/// tutta la pagina.
class HomeHeader extends StatelessWidget {
  const HomeHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return SliverAppBar(
      pinned: true,
      floating: true,
      toolbarHeight: 58,
      backgroundColor: ArColors.bg,
      surfaceTintColor: Colors.transparent,
      titleSpacing: ArSpace.page(context).left,
      title: const _Wordmark(),
      actions: [
        IconButton(
          tooltip: 'Cerca',
          icon: const Icon(Icons.search),
          onPressed: () => context.push(AppRoutes.animeSearch),
        ),
        SizedBox(width: ArSpace.page(context).right - 8),
      ],
    );
  }
}

/// Il nome dell'app con il gradiente del marchio.
///
/// E' l'unico posto della home, oltre al banner, in cui il gradiente tocca il
/// testo: usarlo per il nome lo rende riconoscibile senza accendere tutta la
/// pagina.
class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Semantics(
      header: true,
      child: ShaderMask(
        shaderCallback: (bounds) => ArColors.brand.createShader(bounds),
        child: Text(
          'AnimeRank',
          style: theme.textTheme.titleLarge?.copyWith(
            color: Colors.white,
            fontVariations: const [FontVariation('wght', 800)],
          ),
        ),
      ),
    );
  }
}
