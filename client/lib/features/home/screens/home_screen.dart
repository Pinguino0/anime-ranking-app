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
                'Apri la ricerca e fai partire una ricerca online: '
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
      itemBuilder: (context, i) => _card(context, row.entries[i], hero: false),
    );
  }

  /// Griglia dell'intero catalogo.
  ///
  /// Va in fondo e non in cima perche' risponde a una domanda diversa da
  /// quella delle righe: le righe dicono "cosa guardo", questa dice "cosa c'e'
  ///". Metterla in testa costringerebbe a scorrerla tutta per arrivare alle
  /// righe.
  Widget _catalog(BuildContext context, List<AnimeEntry> entries) {
    final spacing = ArSpace.sm;
    final padding = EdgeInsets.symmetric(horizontal: ArSpace.page(context).left);

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
        // Le colonne si contano sulla larghezza davvero disponibile e non su un
        // numero fisso per schermata: su un monitor largo un `crossAxisCount`
        // calato a mano lascia celle enormi, e la locandina 2:3 si riduce a
        //ritratto stretto al centro di un guscio vuoto. Qui la cella resta
        // entro [minCell, maxCell] e l'altezza segue la cella, quindi la griglia
        // riempie la larghezza senza buchi.
        LayoutBuilder(
          builder: (context, constraints) {
            const minCell = 132.0;
            const maxCell = 176.0;

            final width = constraints.maxWidth - padding.horizontal;
            // Due limiti, non uno: `maxCell` decide quante colonne ci stanno
            // senza che la cella si allarghi troppo, `minCell` impedisce che su
            // uno schermo enormouse le colonne diventino cosi' tante da rendere
            // la locandina illeggibile. Il secondo e' il tetto.
            final fit = (width / maxCell).ceil();
            final readable = (width / minCell).floor().clamp(2, 12);
            final columns = fit.clamp(2, readable);
            final cell =
                (width - spacing * (columns - 1)) / columns;

            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: padding,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                // La card e' solo la locandina 2:3, quindi l'altezza della
                // cella non e' un numero inventato: e' la cella per 3/2.
                mainAxisExtent: cell * 3 / 2,
                crossAxisSpacing: spacing,
                mainAxisSpacing: spacing,
              ),
              itemCount: entries.length,
              itemBuilder: (context, i) => _card(context, entries[i], hero: true),
            );
          },
        ),
      ],
    );
  }

  Widget _card(BuildContext context, AnimeEntry entry, {required bool hero}) {
    return AnimeCard(
      title: entry.displayTitle,
      imageUrl: entry.imageUrl,
      score: entry.score,
      // Solo la griglia catalogo mette l'Hero. Lo stesso anime puo' comparire
      // in piu' righe in alto (per esempio "in corso" e "piu' votati"): due
      // Hero con lo stesso tag nella stessa rotta fanno fallire l'animazione
      // con "multiple heroes that share the same tag" e portano via la
      // schermata intera. Un Hero per anime e' il limite, non uno per sezione.
      heroTag: hero ? entry.heroTag : null,
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
        title: entry.displayTitle,
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
  /// Non un troncamento con i puntini: la sinossi del catalogo esterno spesso
  /// finisce a meta' frase e il "..." su un periodo interrotto fa pensare a un
  /// testo corrotto. Meglio chiudere sull'ultimo punto fermo trovato.
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
    // Stessa altezza a piena larghezza del banner vero (380 su desktop, 300
    // altrove). Il banner non ha padding ne' angoli smussati, quindi nemmeno lo
    // scheletro ne ha: con un riquadro rientrato, al primo arrivo dei dati la
    // pagina si assestava di colpo.
    final isDesktop = Breakpoints.fromContext(context).isExpanded;
    return SkeletonBox(
      height: isDesktop ? 380 : 300,
      radius: 0,
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
    final horizontal = ArSpace.page(context).left;
    final available = MediaQuery.sizeOf(context).width - horizontal * 2;
    // Stesse soglie di `ContentRow._widthFor`: cosi' numero di caselle e
    // larghezza combaciano con le card che compaiono al posto loro.
    final count = switch (available) {
      < 320 => 2,
      < 520 => 3,
      < 760 => 4,
      < 1040 => 5,
      _ => 6,
    };
    final cardWidth = (available - ArSpace.sm * (count - 1)) / count;
    final cardHeight = cardWidth * 3 / 2;

    // Un blocco per riga, con lo stesso padding verticale del `ContentRow`
    // vero: l'intestazione scorre sotto il padding orizzontale di pagina, come
    // fa il `SectionHeader`.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var row = 0; row < 3; row++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: ArSpace.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: horizontal),
                  child: const SkeletonBox(width: 170, height: 20),
                ),
                const SizedBox(height: ArSpace.sm),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: horizontal),
                  child: Row(
                    children: [
                      for (var i = 0; i < count; i++) ...[
                        Expanded(
                          child: SkeletonBox(
                            height: cardHeight,
                            radius: ArRadii.card,
                          ),
                        ),
                        if (i < count - 1) const SizedBox(width: ArSpace.sm),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
