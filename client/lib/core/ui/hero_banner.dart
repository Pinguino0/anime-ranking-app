import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../constants/breakpoints.dart';
import '../theme/app_theme.dart';
import 'transitions.dart';

/// Banner in evidenza in testa alla home.
///
/// Il primo schermo di un'app di anime risponde a una domanda sola: "cosa
/// guardo stasera?". Un carosello di locandine la rimanda, perche' fra il
/// titolo e l'utente c'e' uno scroll. Qui l'opera in evidenza e' gia' li, con
/// titolo, trama e due azioni.
///
/// Il testo non e' appoggiato a una riga bianca: sta nell'angolo in basso
/// sinistro, sopra un gradiente che sale dal fondo. Il motivo e' che un blocco
/// di testo con sfondo su un'immagine arbitraria si legge come un banner
/// pubblicitario, mentre il testo che emerge dal buio fa sembrare l'immagine
/// parte della pagina.
///
/// L'altezza non e' fissa in pixel ma derivata dalla larghezza: il banner deve
/// essere largo due volte e mezzo quanto alto su qualunque schermo, altrimenti
/// su un tablet diventa una fascia e su un portatile una macchia.
class HeroBanner extends StatelessWidget {
  const HeroBanner({
    super.key,
    required this.title,
    required this.imageUrl,
    required this.onTap,
    this.subtitle,
    this.eyebrow,
    this.meta,
    this.trailing,
  });

  final String title;
  final String? imageUrl;

  /// Anima su cui mettere "Guarda" e su cui chiudere il banner.
  final VoidCallback? onTap;

  /// Seconda riga: il criterio ("il piu' votato di questa stagione").
  final String? subtitle;

  /// Etichetta sopra il titolo ("In evidenza", "N. 1 del gruppo").
  final String? eyebrow;

  /// Riga di dati: voto, episodi, anno.
  final String? meta;

  /// Azione secondaria a destra delle due principali.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isDesktop = Breakpoints.of(width) == LayoutSize.expanded;

    return SizedBox(
      height: isDesktop ? 380 : 300,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Su schermo largo il testo occupa una colonna a sinistra e la
          // locandina sta a destra: affiancate si leggono come una copertina
          // con la scheda. Impilate, invece, il testo finisce sopra la faccia
          // del personaggio, che e' la parte dell'immagine che l'utente cerca.
          final side = isDesktop && constraints.maxWidth >= 720;

          return Stack(
            fit: StackFit.expand,
            children: [
              _Backdrop(url: imageUrl, title: title),
              if (!side) const DecoratedBox(decoration: BoxDecoration(gradient: ArColors.heroScrim)),

              if (side)
                // Da sinistra a destra: l'immagine resta visibile a destra, il
                // testo prende la colonna sinistra. Il gradiente e' orizzontale
                // perche' il confine fra le due zone e' verticale.
                const DecoratedBox(
                  decoration: BoxDecoration(gradient: ArColors.heroScrimSide),
                ),

              Align(
                alignment: side ? Alignment.centerLeft : Alignment.bottomLeft,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    ArSpace.page(context).left,
                    ArSpace.lg,
                    side ? ArSpace.xl : ArSpace.page(context).right,
                    ArSpace.xl,
                  ),
                  child: ConstrainedBox(
                    // Il blocco di testo ha una larghezza massima: a tutta
                    // pagina la trama arriverebbe a 120 caratteri per riga e
                    // l'occhio perderebbe il punto di fine frasea.
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: _Text(
                      eyebrow: eyebrow,
                      title: title,
                      subtitle: subtitle,
                      meta: meta,
                      onTap: onTap,
                      trailing: trailing,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.url, required this.title});

  final String? url;
  final String title;

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) {
      return const DecoratedBox(decoration: BoxDecoration(gradient: ArColors.subtle));
    }

    return CachedNetworkImage(
      imageUrl: url!,
      fit: BoxFit.cover,
      // L'immagine e' grande e viene ricaricata a ogni rotazione del telefono:
      // senza cache ogni giro scarica di nuovo qualche megabyte e si vede un
      // lampo grigio al centro dell'app.
      fadeInDuration: ArMotion.slow,
      placeholder: (_, _) =>
          const DecoratedBox(decoration: BoxDecoration(gradient: ArColors.subtle)),
      errorWidget: (_, _, _) =>
          const DecoratedBox(decoration: BoxDecoration(gradient: ArColors.subtle)),
    );
  }
}

class _Text extends StatelessWidget {
  const _Text({
    required this.title,
    required this.onTap,
    this.eyebrow,
    this.subtitle,
    this.meta,
    this.trailing,
  });

  final String? eyebrow;
  final String title;
  final String? subtitle;
  final String? meta;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (eyebrow != null) ...[
          // L'occhiello ha il gradiente del brand applicato al testo: e' l'unico
          // punto della pagina in cui un accento cosi' forte ha senso, perche' e'
          // l'etichetta che dice "questa e' la cosa da guardare".
          ShaderMask(
            shaderCallback: (bounds) => ArColors.brand.createShader(bounds),
            child: Text(
              eyebrow!.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: Colors.white,
                letterSpacing: 1.6,
                fontVariations: const [FontVariation('wght', 700)],
              ),
            ),
          ),
          const SizedBox(height: ArSpace.xs),
        ],
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.displaySmall?.copyWith(
            // Ombra piu' forte del normale perche' qui il testo e' grande e
            // passa sopra una parte chiara dell'immagine.
            shadows: const [Shadow(color: Colors.black, blurRadius: 18)],
          ),
        ),
        if (meta != null && meta!.isNotEmpty) ...[
          const SizedBox(height: ArSpace.xs),
          Text(
            meta!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.white.withValues(alpha: 0.78),
              shadows: const [Shadow(color: Colors.black87, blurRadius: 8)],
            ),
          ),
        ],
        if (subtitle != null && subtitle!.isNotEmpty) ...[
          const SizedBox(height: ArSpace.sm),
          Text(
            subtitle!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.88),
              height: 1.5,
              shadows: const [Shadow(color: Colors.black87, blurRadius: 10)],
            ),
          ),
        ],
        const SizedBox(height: ArSpace.lg),
        Row(
          children: [
            ArGradientButton(
              label: 'Guarda',
              icon: Icons.play_arrow_rounded,
              onPressed: onTap,
            ),
            if (trailing != null) ...[
              const SizedBox(width: ArSpace.sm),
              trailing!,
            ],
          ],
        ),
      ],
    );
  }
}
