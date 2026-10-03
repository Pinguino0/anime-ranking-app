import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/content_row.dart';
import '../../../core/ui/poster_card.dart';
import '../../anime/domain/anime.dart';
import '../../auth/presentation/auth_controller.dart';
import '../home_controller.dart';

/// Home dell'app: righe di poster da sfogliare.
///
/// La struttura e' quella dei servizi di streaming per una ragione precisa: la
/// prima domanda di chi apre un'app di anime non e' "voglio filtrare per
/// genere", e' "cosa c'e' da guardare stasera". Un elenco verticale di righe di
/// tabella risponde alla seconda domanda.
///
/// La sezione per gruppo resta sotto tutto e non e' un carosello: scegliere un
/// gruppo e' una decisione, non un contenuto da sfogliare.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(homeFeedProvider);
    final theme = Theme.of(context);
    final email = ref.watch(authStatusProvider).user?.email;
    final pagePadding = ArSpace.page(context);

    return Scaffold(
      body: RefreshIndicator(
        // La ricarica esplicita e' l'unico modo di aggiornare la home: si
        // ricarica quando lo si chiede, non a ogni visita, altrimenti tornare
        // dal profono rifarebbe la stessa richiesta.
        onRefresh: () => ref.read(homeFeedProvider.notifier).refresh(),
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              floating: true,
              expandedHeight: 168,
              // Il titolo e' su due righe e la seconda e' il nome dell'utente:
              // il nome del servizio da solo ("AnimeRank") occupa una riga
              // intera senza dire nulla, mentre il nome di chi e' collegato e'
              // l'informazione che rende la pagina personale.
              flexibleSpace: FlexibleSpaceBar(
                titlePadding: EdgeInsets.only(
                  left: pagePadding.left,
                  right: pagePadding.right,
                  bottom: 18,
                ),
                title: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'AnimeRank',
                      style: theme.textTheme.titleLarge?.copyWith(
                        // Sotto il ritratto non si legge: la barra scorre e il
                        // titolo viaggia con lei, restando sul nero pieno.
                        color: theme.brightness == Brightness.dark
                            ? Colors.white
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                    if (email != null)
                      Text(
                        email.split('@').first,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                      ),
                  ],
                ),
                background: const DecoratedBox(
                  decoration: BoxDecoration(gradient: ArColors.subtle),
                ),
              ),
            ),
            ...feed.when(
              // Errore e caricamento hanno lo stesso scheletro: una schermata
              // vuota durante il caricamento e' indistinguibile da una home
              // rotta, e lo scheletro dice subito "sta arrivando".
              loading: () => const [SliverToBoxAdapter(child: _Skeleton())],
              error: (error, _) => [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: Icons.cloud_off,
                    title: 'Home non disponibile',
                    message: "Non si e' riusciti a caricare i titoli. "
                        "Tira verso il basso per riprovare.",
                    action: FilledButton.icon(
                      onPressed: () => ref.read(homeFeedProvider.notifier).refresh(),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Riprova'),
                    ),
                  ),
                ),
              ],
              data: (data) => _rows(context, data),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    );
  }

  List<Widget> _rows(BuildContext context, HomeFeed feed) {
    final usable = feed.rows.where((row) => !row.isEmpty).toList();

    // Catalogo ancora vuoto: non e' un errore, e' una base da popolare. Il
    // testo lo dice, invece di lasciare una pagina bianca che sembra rotta.
    if (usable.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.inventory_2_outlined,
            title: 'Catalogo ancora vuoto',
            message: 'Non c\'e\' ancora nessun anime salvato. '
                'Apri la ricerca e fai partire una ricerca su Jikan: '
                'quello che trovi viene salvato qui e resta disponibile offline.',
          ),
        ),
      ];
    }

    return [
      for (final row in usable)
        SliverToBoxAdapter(child: _row(context, row)),
    ];
  }

  Widget _row(BuildContext context, HomeRow row) {
    return ContentRow(
      title: row.title,
      subtitle: row.subtitle,
      itemCount: row.entries.length,
      itemBuilder: (context, i) => _poster(context, row.entries[i]),
    );
  }

  Widget _poster(BuildContext context, AnimeEntry entry) {
    return PosterCard(
      title: entry.title,
      imageUrl: entry.imageUrl,
      score: entry.score,
      heroTag: entry.heroTag,
      subtitle: [
        if (entry.year != null) '${entry.year}',
        if (entry.episodes != null) '${entry.episodes} ep',
      ].join(' · '),
      // Toccando un poster si apre la scheda dell'opera, non la ricerca con il
      // titolo come testo: riaprire la ricerca scopriva di nuovo gli stessi
      // risultati quando l'utente voleva solo guardare i dettagli di quello che
      // aveva sotto gli occhi.
      onTap: () => context.push(AppRoutes.animeDetail, extra: entry),
    );
  }
}

/// Scheletro di caricamento.
///
/// Le caselle grigie sono piu' vicine al risultato di uno spinner: mostrano
/// gia' la forma della pagina, quindi quando arriva il contenuto non cambia la
/// geometria e la vista non "salta" sotto gli occhi.
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var r = 0; r < 3; r++) ...[
            _bar(context, width: 160, height: 18),
            const SizedBox(height: 14),
            SizedBox(
              height: PosterCard.rowHeight,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: 5,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (_, _) => _bar(
                  context,
                  width: PosterCard.cellWidth,
                  height: PosterCard.rowHeight,
                  radius: ArRadii.card,
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ],
      ),
    );
  }

  Widget _bar(
    BuildContext context, {
    required double width,
    required double height,
    double radius = 8,
  }) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}