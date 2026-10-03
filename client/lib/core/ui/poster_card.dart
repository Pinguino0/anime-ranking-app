import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'transitions.dart';

/// Poster di un anime, con titolo e voto.
///
/// Il poster e' il contenuto piu' importante di una app di anime, quindi
/// occupa tutto lo spazio disponibile e il testo sta sopra l'immagine con un
/// gradiente: su una locandina scura o colorata un testo nero sparirebbe.
///
/// Le proporzioni sono quelle delle locandine anime (2:3), non un quadrato:
/// un poster stirato in un quadrato sembra una foto schiacciata.
class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.title,
    this.imageUrl,
    this.score,
    this.subtitle,
    this.width = cellWidth,
    this.onTap,
    this.trailing,
    this.heroTag,
  });

  /// Larghezza della cella.
  ///
  /// Pubblica perche' anche l'altezza della riga di caroselli si ricava da
  /// questa: se i due numeri stanno in posti diversi, cambiando la larghezza
  /// della cella i titoli sotto i poster vengono tagliati.
  static const double cellWidth = 132;

  /// Altezza totale di una cella: poster in 2:3 piu' la riga di testo.
  static const double rowHeight = cellWidth * 3 / 2 + 44;

  final String title;
  final String? imageUrl;
  final double? score;
  final String? subtitle;

  /// Larghezza fissa: i caroselli devono avere celle identiche, altrimenti
  /// scorrendo l'occhio perde il filo di dove si e' arrivati.
  final double width;

  final VoidCallback? onTap;
  final Widget? trailing;

  /// Tag della transizione condivisa verso la scheda.
  ///
  /// Se e' presente, l'immagine vola dalla card alla scheda invece di essere
  /// semplicemente sostituita: e' il dettaglio che fa sembrare l'apertura di
  /// una pagina come un continuo e non come un caricamento.
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    final poster = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(ArRadii.card),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        splashColor: ArColors.primary.withValues(alpha: 0.12),
        highlightColor: Colors.white.withValues(alpha: 0.04),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _PosterImage(url: imageUrl, title: title, heroTag: heroTag),
                  // Il gradiente copre solo il terzo basso: sopra deve restare
                  // l'immagine, che e' la ragione per cui la scheda esiste.
                  const DecoratedBox(
                    decoration: BoxDecoration(gradient: ArColors.posterScrim),
                  ),
                  if (score != null)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: _ScoreBadge(score: score!),
                    ),
                  Positioned(
                    left: 10,
                    right: 10,
                    bottom: 10,
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        // Ombra sull'immagine: garantisce il contrasto anche
                        // su una locandina bianca, dove il nero del testo
                        // sparirebbe.
                        shadows: const [
                          Shadow(color: Colors.black87, blurRadius: 6),
                        ],
                        height: 1.25,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              height: 44,
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              color: colors.surfaceContainerLow,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      subtitle ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return SizedBox(
      width: width,
      child: ArPressable(
        onTap: onTap,
        child: DecoratedBox(
          // Bordo chiarissimo: su nero puro la sagoma della card si perdeva,
          // e una griglia di poster sembrava un blocco unico.
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(ArRadii.card),
            border: Border.all(
              color: colors.onSurface.withValues(alpha: 0.06),
            ),
          ),
          child: poster,
        ),
      ),
    );
  }
}

class _PosterImage extends StatelessWidget {
  const _PosterImage({required this.url, required this.title, this.heroTag});

  final String? url;
  final String title;
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    // Senza immagine resta un blocco con l'iniziale: una cella vuota in un
    // carosello sembrerebbe un'immagine che non si carica, e l'utente
    // aspetterebbe un errore che invece non c'e'.
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.surfaceContainerHigh,
            colors.surfaceContainerLow,
          ],
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

    // L'hero avvolge solo l'immagine, non la card intera: un hero che
    // cambia dimensione tra partenza e arrivo produce un'immagine che
    // "scivola" dentro il riquadro e una vibrazione fastidiosa sul bordo.
    if (heroTag == null) return image;

    return Hero(
      tag: heroTag!,
      // Il volo e' breve e non ruota: una rotazione in 3D su un'immagine piatta
      // si legge come un errore di rendering, non come un effetto.
      flightShuttleBuilder: (context, animation, direction, from, to) =>
          ScaleTransition(scale: animation, child: image),
      child: image,
    );
  }
}

/// Pastiglia del voto.
///
/// L'oro e' riservato ai voti: e' l'unico elemento dell'app che usa il
/// giallo, cosi' l'occhio lo trova subito in una griglia.
///
/// Il fondo e' scuro e non trasparente perche' l'oro su una locandina chiara
/// sparirebbe, e il bordo dorato stacca il numero dal poster senza dover
/// ricorrere a un'etichetta di testo.
class _ScoreBadge extends StatelessWidget {
  const _ScoreBadge({required this.score});

  final double score;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(ArRadii.chip),
        border: Border.all(color: ArColors.gold.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, size: 14, color: ArColors.gold),
          const SizedBox(width: 3),
          Text(
            score.toStringAsFixed(1),
            style: const TextStyle(
              fontFamily: AppTheme.bodyFont,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              fontVariations: [FontVariation('wght', 700)],
              color: ArColors.gold,
            ),
          ),
        ],
      ),
    );
  }
}
