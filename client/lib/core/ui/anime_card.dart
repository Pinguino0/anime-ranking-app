import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../constants/breakpoints.dart';
import '../theme/app_theme.dart';
import '../theme/section_accent.dart';
import 'transitions.dart';

/// Card di un anime per griglie e caroselli.
///
/// Succede a `PosterCard`, che restava valida ma aveva due difetti rispetto a
/// quello che il catalogo chiede.
///
/// Il primo e' il testo: metteva il titolo sopra la locandina e i metadati
/// sotto, in due blocchi separati da una riga di sfondo. Il risultato e' che il
/// titolo si leggeva a fatica su un'immagine variabile e la riga sotto sembrava
/// un'altra parte della card. Qui il titolo e' sempre sull'immagine, con
/// l'ombra che ne garantisce il contrasto.
///
/// Il secondo e' l'assenza di un comportamento al puntatore. Su desktop
/// l'utente non tocca: passa il mouse. Una card che risponde solo al tocco e'
/// un'immagine, non un collegamento, e su un monitor l'utente la guarda e passa
/// oltre senza capire che e' apribile. Da qui l'hover.
///
/// La larghezza e' fissata dal chiamante e non dal layout: i caroselli devono
/// avere celle identiche, altrimenti scorrendo l'occhio perde il filo.
class AnimeCard extends StatefulWidget {
  const AnimeCard({
    super.key,
    required this.title,
    required this.imageUrl,
    this.subtitle,
    this.genres = const [],
    this.score,
    this.heroTag,
    this.onTap,
    this.trailing,
    this.badge,
    this.hoverEnabled = true,
  });

  final String title;
  final String? imageUrl;

  /// Riga sotto il titolo: anno, episodi, stato.
  final String? subtitle;

  /// Generi dell'opera, gia' in italiano.
  ///
  /// Stanno sulla card e non solo nella scheda perche' il genere e' il primo
  /// dato con cui si sceglie cosa guardare: una griglia di locandini senza
  /// genere obbliga ad aprire ogni opera per capire se interessa.
  ///
  /// Si mostrano i primi [genresShown] e non tutti: sotto il titolo c'e' una
  /// riga sola e un elenco di sei generi andrebbe tagliato a meta', che e'
  /// peggio che non mostrarlo.
  final List<String> genres;

  /// Quanti generi restano visibili sulla card.
  static const int genresShown = 2;

  /// Voto medio. Quando manca non viene mostrata pastiglia: una stella con
  /// "0.0" su un anime senza voti e' un dato falso, e la sua assenza e'
  /// informazione piu' utile.
  final double? score;

  /// Tag dell'hero verso la scheda.
  ///
  /// Deve identificare l'opera e non la sua posizione nella griglia: con lo
  /// stesso tag su due card diverse, a meta' del volo l'occhio vedrebbe
  /// l'immagine saltare dal posto sbagliato.
  final Object? heroTag;

  final VoidCallback? onTap;

  /// Elemento in basso a destra: voto del gruppo, badge di stato.
  final Widget? trailing;

  /// Elemento in alto a sinistra: posizione in classifica o stato.
  ///
  /// Sta a sinistra e non a destra perche' il voto ha gia' quel posto: due
  /// pastiglie sullo stesso angolo si coprirebbero, e un titolo che e' sia
  /// "N. 1" sia "In corso" ha bisogno di entrambe.
  final Widget? badge;

  /// Disattiva l'hover.
  ///
  /// Serve su schermi touch, dove non esiste un puntatore: l'animazione si
  /// innescherebbe al tocco e la card si deformerebbe mentre l'utente la
  /// preme, sembrando che l'interfaccia abbia registrato due eventi.
  final bool hoverEnabled;

  @override
  State<AnimeCard> createState() => _AnimeCardState();
}

class _AnimeCardState extends State<AnimeCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // L'hover si calcola una volta per build: sotto i 900px non esiste
    // puntatore, quindi il controllo sarebbe sempre falso e costerebbe un
    // `MediaQuery` per schermata senza mai cambiare risultato.
    final canHover = widget.hoverEnabled &&
        Breakpoints.fromContext(context) == LayoutSize.expanded;

    final active = canHover && _hovered;

    // Il bordo dell'hover prende la tinta della sezione: nella classifica si
    // accende d'oro, nella watchlist di blu. Fuori da una shell resta il viola
    // del marchio, che e' quello di prima.
    final tint = SectionAccentScope.of(context).base;

    final poster = AspectRatio(
      aspectRatio: 2 / 3,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _Image(url: widget.imageUrl, title: widget.title, tag: widget.heroTag),

          // Due veli, non uno. Quello in bassi serve al titolo e va sempre; quello
          // che copre tutta la card compare solo all'hover e serve a far
          // leggere il pannello informativo. Senza il primo il titolo
          // sparirebbe; senza il secondo il pannello emergerebbe da una
          // superficie non schermata e sembrerebbe un errore di composizione.
          const DecoratedBox(
            decoration: BoxDecoration(gradient: ArColors.posterScrim),
          ),
          if (active)
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.center,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.62),
                    Colors.black.withValues(alpha: 0.88),
                  ],
                ),
              ),
            ),

          if (widget.score != null)
            Positioned(
              top: 8,
              right: 8,
              child: ScoreBadge(score: widget.score!),
            ),

          if (widget.badge != null)
            Positioned(top: 8, left: 8, child: widget.badge!),

          // Il pannello sale di poco e appare dopo: l'insieme racconta
          // "questa card si puo' aprire", mentre la comparsa del solo testo
          // sembrerebbe un'aggiornamento dei dati.
          Positioned(
            left: 10,
            right: 10,
            bottom: 10,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // I generi stanno sopra il titolo, non sotto: e' il dato che
                // serve per capire se aprire la card, quindi deve precedere
                // il titolo nell'ordine di lettura.
                if (widget.genres.isNotEmpty) ...[
                  _GenreStrip(genres: widget.genres),
                  const SizedBox(height: ArSpace.xs),
                ],
                Text(
                  widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    // Ombra sull'immagine: su una locandina chiara il nero
                    // del testo sparirebbe, e qui non si controlla l'immagine.
                    shadows: const [Shadow(color: Colors.black87, blurRadius: 6)],
                    height: 1.25,
                  ),
                ),
                if (widget.subtitle != null && widget.subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    widget.subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.72),
                    ),
                  ),
                ],
                // Il riquadro sotto il titolo c'e' solo all'hover: i metadati
                // ci sono anche senza, ma questo e' lo spazio che dice "tocca
                // per i dettagli" e sta zitto finche' non serve.
                AnimatedSize(
                  duration: ArMotion.fast,
                  curve: ArMotion.enter,
                  alignment: Alignment.topLeft,
                  child: active
                      ? Padding(
                          padding: const EdgeInsets.only(top: ArSpace.xs),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.info_outline,
                                size: 13,
                                color: Colors.white70,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Dettagli',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: Colors.white70,
                                  letterSpacing: 0.4,
                                ),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    final card = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ArRadii.card),
        // Il bordo si accende all'hover con il gradiente del brand: e' il
        // segnale piu' economico di "questa scheda e' viva", e non sposta
        // nessun pixel quindi non muove le card vicine.
        border: Border.all(
          color: active
              ? tint.withValues(alpha: 0.7)
              : ArColors.borderSoft,
        ),
        boxShadow: active ? ArShadows.glow(tint, strength: 0.22) : null,
      ),
      child: poster,
    );

    return MouseRegion(
      onEnter: canHover ? (_) => setState(() => _hovered = true) : null,
      onExit: canHover ? (_) => setState(() => _hovered = false) : null,
      cursor: widget.onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      child: ArPressable(onTap: widget.onTap, child: card),
    );
  }
}

/// Pastiglie dei generi sulla card.
///
/// Solo i primi [AnimeCard.genresShown]: sotto il titolo c'e' una riga sola e
/// un elenco completo andrebbe tagliato a meta', che e' peggio che non
/// mostrarlo. Il resto si velta aprendo la scheda.
class _GenreStrip extends StatelessWidget {
  const _GenreStrip({required this.genres});

  final List<String> genres;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = genres.take(AnimeCard.genresShown);

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final genre in visible)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              // Fondo trasparente e non pieno: sopra una locandina colorata un
              // riempido coprirebbe l'immagine, e la riga diventerebbe un
              // blocco di testo che nasconde il poster.
              color: Colors.white.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(ArRadii.chip - 4),
            ),
            child: Text(
              genre,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.92),
                fontSize: 10,
                letterSpacing: 0.2,
                shadows: const [Shadow(color: Colors.black87, blurRadius: 4)],
              ),
            ),
          ),
      ],
    );
  }
}

/// Immagine del poster con segnaposto.
///
/// Il segnaposto e' un blocco con l'iniziale e non un'icona: in un carosello
/// una cella grigia vuota sembra un'immagine che non ha caricato, mentre
/// l'iniziale dice subito di che opera si tratta anche senza rete.
class _Image extends StatelessWidget {
  const _Image({required this.url, required this.title, this.tag});

  final String? url;
  final String title;
  final Object? tag;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.surfaceContainerHigh, colors.surfaceContainerLow],
        ),
      ),
      child: Center(
        child: Text(
          title.isEmpty ? '?' : title.characters.first.toUpperCase(),
          style: TextStyle(
            fontFamily: AppTheme.displayFont,
            fontSize: 34,
            fontWeight: FontWeight.w700,
            fontVariations: const [FontVariation('wght', 700)],
            color: colors.onSurfaceVariant.withValues(alpha: 0.35),
          ),
        ),
      ),
    );

    Widget image;
    if (url == null || url!.isEmpty) {
      image = placeholder;
    } else {
      image = CachedNetworkImage(
        imageUrl: url!,
        fit: BoxFit.cover,
        placeholder: (_, _) => placeholder,
        errorWidget: (_, _, _) => placeholder,
      );
    }

    // L'hero avvolge solo l'immagine. Se avvolgesse la card, al cambio di
    // dimensione fra partenza e arrivo l'immagine scivolerebbe dentro il
    // riquadro: su una card che cambia dimensione il bordo vibra.
    if (tag == null) return image;

    return Hero(
      tag: tag!,
      flightShuttleBuilder: (context, animation, direction, from, to) =>
          ScaleTransition(scale: animation, child: image),
      child: image,
    );
  }
}

/// Pastiglia del voto.
///
/// L'oro e' l'unico giallo dell'app e resta riservato ai voti: e' il motivo per
/// cui in una griglia di venti locandine l'occhio trova subito i quattro titoli
/// che valgono di piu'. Il fondo e' scuro e non trasparente perche' l'oro su
/// una locandina chiara sparirebbe.
class ScoreBadge extends StatelessWidget {
  const ScoreBadge({super.key, required this.score, this.dense = false});

  final double score;

  /// Versione stretta, senza icona: per le liste fitte dove la pastiglia deve
  /// stare in poco spazio accanto al titolo.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 8,
        vertical: dense ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.66),
        borderRadius: BorderRadius.circular(ArRadii.chip),
        border: Border.all(color: ArColors.gold.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!dense) ...[
            const Icon(Icons.star_rounded, size: 14, color: ArColors.gold),
            const SizedBox(width: 3),
          ],
          Text(
            score.toStringAsFixed(1),
            style: TextStyle(
              fontFamily: AppTheme.bodyFont,
              fontSize: dense ? 11 : 12,
              fontWeight: FontWeight.w700,
              fontVariations: const [FontVariation('wght', 700)],
              color: ArColors.gold,
            ),
          ),
        ],
      ),
    );
  }
}
