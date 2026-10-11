import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/transitions.dart';

/// Una posizione mostrata sul podio.
///
/// Il podio e' la parte di una classifica che l'occhio cerca per prima, ma non
/// e' una tabella piu' corta: e' un'altra lettura degli stessi dati, dove la
/// posizione si legge dalla forma prima ancora che dal numero.
class PodiumEntry {
  const PodiumEntry({
    required this.position,
    required this.title,
    this.imageUrl,
    required this.valueText,
    required this.valueTitle,
    this.secondaryText,
    this.secondaryTitle,
    this.heroTag,
    this.onTap,
  });

  final int position;
  final String title;
  final String? imageUrl;

  /// Numero in grande e la sua etichetta.
  ///
  /// Sono due campi e non uno composto: nella classifica principale il numero
  /// e' una media, nelle classifiche speciali e' un conteggio o una
  /// dispersione. Chi chiama sa cosa sta mostrando e lo dichiara.
  final String valueText;
  final String valueTitle;

  /// Seconda metrica, dove serve.
  final String? secondaryText;
  final String? secondaryTitle;

  /// Tag dell'animazione condivisa con la scheda anime.
  final Object? heroTag;

  /// Apre la scheda dell'opera.
  final VoidCallback? onTap;
}

/// I primi tre posti.
///
/// L'ordine a schermo e' secondo, primo, terzo: il vincente al centro e le due
/// posizioni ai lati piu' in basso e' la forma che l'occhio ha gia' visto mille
/// volte, e fa capire chi ha vinto senza leggere nessun numero.
///
/// Le colonne sono allineate in basso e non in alto perche' e' l'altezza del
/// poster a dire il podio: il primo sporge verso l'alto mentre il secondo e il
/// terzo restano sotto, e il gradino e' la gerarchia.
class RankPodium extends StatelessWidget {
  const RankPodium({required this.entries, super.key});

  final List<PodiumEntry> entries;

  /// Quanti posti mostra.
  ///
  /// Tre e non uno di piu': e' la regola del podio. Un quarto posto sul podio
  /// non e' un quarto posto, e' solo una riga come le altre.
  ///
  /// Pubblica perche' la lista deve sapere dove finisce il podio e da dove
  /// riprendono le righe: se le due cifre non concordassero, le prime tre
  /// comparirebbero due volte.
  static const int places = 3;

  @override
  Widget build(BuildContext context) {
    // Difesa sul chiamante: se la classifica ha meno di tre righe il podio
    // mostra quello che c'e'. Sotto una riga non si inventa niente.
    final placed = entries.take(places).toList();
    if (placed.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        // La larghezza dei poster viene calcolata dalla spazio disponibile e non
        // fissata: su un telefono stretto tre colonne con poster da 104px
        // sborderebbero, e su desktop un podio minuscolo sembrerebbe un
        // dettaglio dimenticato in alto.
        const gap = ArSpace.sm;
        final unit = (constraints.maxWidth - gap * 2) / 3;
        // Il vincente e' piu' grande degli altri due, quindi la base si ricava
        // dividendo per il suo fattore: altrimenti la colonna centrale, che e'
        // anche la piu' larga, sfonderebbe proprio sul telefono stretto.
        final base = ((unit - ArSpace.xs) / 1.16).clamp(48.0, 100.0);

        // Riordina per il posto a schermo: con una sola riga la mette al
        // centro, con due la seconda a sinistra e la prima a destra, con tre
        // l'ordine del podio.
        final order = switch (placed.length) {
          1 => [0],
          2 => [1, 0],
          _ => [1, 0, 2],
        };

        return Padding(
          padding: const EdgeInsets.fromLTRB(
            ArSpace.md,
            ArSpace.md,
            ArSpace.md,
            ArSpace.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final index in order)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      right: index == order.last ? 0 : gap,
                    ),
                    child: ArReveal(
                      // Il vincente arriva per primo e gli altri lo seguono
                      // con un piccolo scarto: l'attenzione va dove deve
                      // andare, e l'attesa per il secondo posto e' la parte
                      // piu' lenta dell'animazione.
                      delayMs: index == order.length - 1 ? 0 : 55 + index * 65,
                      child: _PodiumColumn(
                        entry: placed[index],
                        posterWidth: placed[index].position == 1
                            ? base * 1.16
                            : base,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Una colonna del podio: copertina, medaglia, titolo e numeri.
class _PodiumColumn extends StatelessWidget {
  const _PodiumColumn({required this.entry, required this.posterWidth});

  final PodiumEntry entry;
  final double posterWidth;

  bool get _isWinner => entry.position == 1;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final medal = ArColors.rank(entry.position);

    final poster = Stack(
      // Il badge della medaglia sta fuori dal bordo della copertina, quindi lo
      // stack non puo' ritagliare: senza questo la mezzaluna del numero
      // verrebbe tagliata via.
      clipBehavior: Clip.none,
      children: [
        // Alone dietro la copertina, solo sul vincente. Sul secondo e sul
        // terzo l'alone compete con la medaglia vicina e rende ambigui due
        // posti che devono restare distinguibili.
        if (_isWinner)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(ArRadii.poster),
                boxShadow: ArShadows.glow(medal, strength: 0.42),
              ),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(ArRadii.poster),
            border: Border.all(
              color: medal.withValues(alpha: _isWinner ? 0.85 : 0.4),
              width: _isWinner ? 2 : 1.5,
            ),
          ),
          // Il bordo e' dentro il box della colonna: l'immagine ha il
          // gradiente fino al bordo esterno, e senza il padding finirebbe
          // sopra la cornice metallica.
          child: Padding(
            padding: EdgeInsets.all(_isWinner ? 2.5 : 1.5),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(ArRadii.poster - 4),
              child: _PosterImage(
                url: entry.imageUrl,
                title: entry.title,
                width: posterWidth,
              ),
            ),
          ),
        ),
        Positioned(
          left: -2,
          bottom: ArSpace.xs,
          child: _Medal(position: entry.position, color: medal, large: _isWinner),
        ),
      ],
    );

    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        poster,
        SizedBox(height: _isWinner ? ArSpace.md : ArSpace.sm),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: ArSpace.xxs),
          child: Text(
            entry.title,
            // Due righe e non una: un titolo troncato a meta' parola e' peggio
            // di due righe intere, e il podio ha spazio per entrambe.
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleSmall?.copyWith(
              height: 1.25,
              fontWeight: _isWinner ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: ArSpace.xxs),
        Text(
          entry.valueText,
          style: theme.textTheme.titleLarge?.copyWith(
            color: medal,
            fontVariations: const [FontVariation('wght', 700)],
          ),
        ),
        Text(
          entry.valueTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (entry.secondaryText != null) ...[
          const SizedBox(height: ArSpace.xxs),
          Text(
            '${entry.secondaryText} ${entry.secondaryTitle ?? ''}'.trim(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );

    if (entry.onTap == null) return column;

    return ArPressable(
      onTap: entry.onTap,
      // Il podio e' decorativo: il tap apre la scheda e basta. Non mette
      // l'Hero perche' la stessa rotta mostra anche la tabella del ranking, che
      // invece lo mette, e un anime presente in entrambe avrebbe due Hero con
      // lo stesso tag. Il tag del podio era anche gia' ambiguo: con
      // `heroTag` non nullo il fallback `podium-<posizione>` non entrava mai.
      child: column,
    );
  }
}

/// Dischetto con il numero della posizione.
class _Medal extends StatelessWidget {
  const _Medal({
    required this.position,
    required this.color,
    this.large = false,
  });

  final int position;
  final Color color;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final size = large ? 30.0 : 25.0;

    return Container(
      width: size,
      height: size,
      // Il dischetto ha il colore dello sfondo della app, non quello della
      // pagina: e' cosi' che sembra sovrapposto alla copertina e non incastonato
      // dentro di essa.
      decoration: BoxDecoration(
        color: ArColors.bg,
        shape: BoxShape.circle,
        border: Border.all(color: color, width: large ? 2 : 1.5),
      ),
      child: Center(
        child: Text(
          '$position',
          style: TextStyle(
            fontFamily: AppTheme.displayFont,
            fontSize: large ? 14 : 12,
            color: color,
            fontVariations: [FontVariation('wght', 700)],
          ),
        ),
      ),
    );
  }
}

/// Copertina del podio con l'iniziale come riserva.
///
/// Il widget e' suo e non riusato [AnimeThumb] perche' quello misura sul lato
/// e qui serve un poster in verticale: un'immagine quadrata dentro un riquadro
/// 3:2 lascerebbe bande vuote sopra e sotto.
class _PosterImage extends StatelessWidget {
  const _PosterImage({
    required this.url,
    required this.title,
    required this.width,
  });

  final String? url;
  final String title;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Le copertine sono sempre in 3:2 in verticale: la differenza rispetto a
    // un'immagine quadrata si vede, e il riquadro sbagliato farebbe notare il
    // taglio al posto giusto.
    final height = width * 1.48;

    Widget poster() {
      final fallback = ColoredBox(
        color: theme.colorScheme.surfaceContainerHighest,
        child: Center(
          child: Text(
            title.trim().isEmpty ? '?' : title.trim()[0].toUpperCase(),
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );

      return (url == null || url!.isEmpty)
          ? fallback
          : Image.network(
              url!,
              width: width,
              height: height,
              fit: BoxFit.cover,
              // Senza gestione dell'errore un URL rotto mostrerebbe il
              // riquadro grigio di Image.network senza dire nulla di quale
              // opera sia: sul podio la posizione conta piu' dell'immagine,
              // quindi il numero resta leggibile accanto.
              errorBuilder: (_, _, _) => fallback,
            );
    }

    final image = SizedBox(width: width, height: height, child: poster());

    return image;
  }
}