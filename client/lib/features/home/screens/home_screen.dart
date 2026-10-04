import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/breakpoints.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/anime_card.dart';
import '../../../core/ui/content_row.dart';
import '../../../core/ui/hero_banner.dart';
import '../../../core/ui/section_header.dart';
import '../../../core/ui/transitions.dart';
import '../../anime/domain/anime.dart';
import '../../auth/presentation/auth_controller.dart';
import '../home_controller.dart';

/// Home dell'app: banner in evidenza, righe da sfogliare, catalogo.
///
/// La struttura e' quella dei servizi di streaming per una ragione precisa: la
/// prima domanda di chi apre un'app di anime non e' "voglio filtrare per
/// genere", e' "cosa c'e' da guardare stasera". Un elenco verticale di righe di
/// tabella risponde alla seconda domanda.
///
/// Il banner viene prima di tutto perche' risponde a quella domanda in modo
/// istantaneo: l'utente non deve nemmeno iniziare a scorrere per vedere il
/// titolo consigliato.
///
/// La sezione per gruppo resta sotto tutto e non e' un carosello: scegliere un
/// gruppo e' una decisione, non un contenuto da sfogliare.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(homeFeedProvider);
    final email = ref.watch(authStatusProvider).user?.email;
    final page = ArSpace.page(context);

    return Scaffold(
      body: RefreshIndicator(
        // La ricarica esplicita e' l'unico modo di aggiornare la home: si
        // ricarica quando lo si chiede, non a ogni visita, altrimenti tornare
        // dal profilo rifarebbe la stessa richiesta.
        onRefresh: () => ref.read(homeFeedProvider.notifier).refresh(),
        child: CustomScrollView(
          slivers: [
            _TopBar(email: email, padding: page),
            ...feed.when(
              // Errore e caricamento hanno la stessa struttura: una schermata
              // vuota durante il caricamento e' indistinguibile da una home
              // rotta, e lo scheletro dice subito "sta arrivando".
              loading: () => const [
                SliverToBoxAdapter(child: _HeroSkeleton()),
                SliverToBoxAdapter(child: _RowsSkeleton()),
              ],
              error: (error, _) => [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: Icons.cloud_off,
                    title: 'Home non disponibile',
                    message: 'Non si e\' riusciti a caricare i titoli. '
                        'Tira verso il basso per riprovare.',
                    action: FilledButton.icon(
                      onPressed: () =>
                          ref.read(homeFeedProvider.notifier).refresh(),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Riprova'),
                    ),
                  ),
                ),
              ],
              data: (data) => _content(context, ref, data),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }

  List<Widget> _content(BuildContext context, WidgetRef ref, HomeFeed feed) {
    final usable = feed.rows
        .where((row) => row.entries.length >= _minRow)
        .toList();

    // Catalogo ancora vuoto: non e' un errore, e' una base da popolare. Il
    // testo lo dice, invece di lasciare una pagina nera che sembra rotta.
    if (usable.isEmpty && feed.feature == null) {
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
      if (feed.feature != null)
        SliverToBoxAdapter(
          child: _Banner(entry: feed.feature!),
        ),

      for (final row in usable)
        SliverToBoxAdapter(child: _row(row)),

      if (feed.catalog.isNotEmpty)
        SliverToBoxAdapter(child: _catalog(context, feed.catalog)),
    ];
  }

  Widget _row(HomeRow row) {
    return ContentRow(
      title: row.title,
      subtitle: row.subtitle,
      itemCount: row.entries.length,
      itemBuilder: (context, i) => _card(context, row.entries[i]),
    );
  }

  /// Griglia dell'intero catalogo.
  ///
  /// Va in fondo e non in cima perche' risponde a una domanda diversa da
  /// quella delle righe: le righe dicono "cosa guardo", questa dice "cosa c'e'
  ///". Metterla in testa costringerebbe a scorrerla tutta per arrivare alle
  /// righe.
  Widget _catalog(BuildContext context, List<AnimeEntry> entries) {
    final columns = Breakpoints.gridColumns(
      MediaQuery.sizeOf(context).width,
      min: 2,
      max: 6,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: ArSpace.xs),
        SectionHeader(
          title: 'Tutti gli anime',
          subtitle: '${entries.length} titoli in catalogo',
          action: () => context.push(AppRoutes.animeSearch),
          actionLabel: 'Cerca',
        ),
        const SizedBox(height: ArSpace.sm),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.symmetric(horizontal: ArSpace.page(context).left),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            // 2:3 del poster piu' lo spazio del titolo: senza, l'ultima riga
            // verrebbe tagliata dal bordo inferiore.
            mainAxisExtent: 200,
            crossAxisSpacing: ArSpace.sm,
            mainAxisSpacing: ArSpace.sm,
          ),
          itemCount: entries.length,
          itemBuilder: (context, i) => _card(context, entries[i]),
        ),
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
      // Toccando un poster si apre la scheda dell'opera, non la ricerca con il
      // titolo come testo: riaprire la ricerca scopriva di nuovo gli stessi
      // risultati quando l'utente voleva solo guardare i dettagli di quello che
      // aveva sotto gli occhi.
      onTap: () => context.push(AppRoutes.animeDetail, extra: entry),
    );
  }
}

/// Sotto i tre titoli una riga e' solo rumore.
///
/// Con due locandine la sezione sembra un caricamento fallito: l'utente prova
/// a scorrere e non succede nulla. Meglio non mostrarla.
const int _minRow = 3;

/// Barra in alto con il nome dell'utente.
///
/// Il nome del servizio da solo occuperebbe una riga intera senza dire nulla,
/// mentre il nome di chi e' collegato e' l'informazione che rende la pagina
/// personale. Il segno dell'app e' la parte che resta nel gradiente: da solo
/// sarebbe una riga di testo che compete con il nome per la stessa importanza.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.email, required this.padding});

  final String? email;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SliverAppBar(
      pinned: true,
      floating: true,
      toolbarHeight: 62,
      backgroundColor: ArColors.bg,
      titleSpacing: padding.left,
      title: Row(
        children: [
          if (email != null) ...[
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ciao, ${email!.split('@').first}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                  Text(
                    'Cosa guardi stasera',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ] else
            Text('AnimeRank', style: theme.textTheme.titleLarge),
          const Spacer(),
          IconButton(
            tooltip: 'Cerca',
            icon: const Icon(Icons.search),
            onPressed: () => context.push(AppRoutes.animeSearch),
          ),
        ],
      ),
    );
  }
}

/// Banner con l'opera in evidenza.
class _Banner extends StatelessWidget {
  const _Banner({required this.entry});

  final AnimeEntry entry;

  @override
  Widget build(BuildContext context) {
    final facts = [
      if (entry.mediaType != null) entry.mediaType!.label,
      if (entry.episodes != null) '${entry.episodes} episodi',
      if (entry.year != null) '${entry.year}',
    ].join(' · ');

    return ArReveal(
      // Nessun ritardo: e' il primo elemento dello schermo e deve comparire
      // subito. Un banner che arriva dopo mezzo secondo sembra un caricamento.
      child: HeroBanner(
        title: entry.title,
        imageUrl: entry.imageUrl,
        eyebrow: 'In evidenza',
        meta: facts.isEmpty ? null : facts,
        // La trama si taglia a due righe: il banner ha altezza fissa e una
        // sinossi lunga spingerebbe le azioni fuori dal riquadro.
        subtitle: _shorten(entry.synopsis),
        onTap: () => context.push(AppRoutes.animeDetail, extra: entry),
      ),
    );
  }

  /// Prima frase, limitata.
  ///
  /// Non un troncamento con i puntini: la sinossi di MyAnimeList spesso finisce
  /// a meta' frase e il "..." su un periodo interrotto fa pensare a un testo
  /// corrotto. Meglio chiudere sull'ultimo punto fermo trovato.
  String? _shorten(String? text) {
    if (text == null || text.trim().isEmpty) return null;

    const limit = 220;
    final clean = text.trim();
    if (clean.length <= limit) return clean;

    final cut = clean.substring(0, limit);
    final stop = cut.lastIndexOf(RegExp(r'[.!?]'));
    return stop > limit ~/ 2 ? cut.substring(0, stop + 1) : '$cut...';
  }
}

/// Scheletro del banner.
///
/// La stessa altezza del banner vero: uno scheletro piu' basso farebbe salire
/// tutto il resto della pagina e poi tornare indietro al primo arrivo dei dati.
class _HeroSkeleton extends StatelessWidget {
  const _HeroSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(ArSpace.md),
      child: const SkeletonBox(height: 260, radius: ArRadii.card),
    );
  }
}

/// Scheletro delle righe.
///
/// Le caselle grigie sono piu' vicine al risultato di uno spinner: mostrano
/// gia' la forma della pagina, quindi quando arriva il contenuto non cambia la
/// geometria e la vista non "salta" sotto gli occhi.
class _RowsSkeleton extends StatelessWidget {
  const _RowsSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var r = 0; r < 3; r++) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(ArSpace.md, ArSpace.sm, ArSpace.md, 0),
            child: SkeletonBox(width: 170, height: 20),
          ),
          const SizedBox(height: ArSpace.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: ArSpace.md),
            child: Row(
              children: [
                for (var i = 0; i < 4; i++) ...[
                  const Expanded(
                    child: SkeletonBox(height: 190, radius: ArRadii.card),
                  ),
                  if (i < 3) const SizedBox(width: ArSpace.sm),
                ],
              ],
            ),
          ),
          const SizedBox(height: ArSpace.md),
        ],
      ],
    );
  }
}
