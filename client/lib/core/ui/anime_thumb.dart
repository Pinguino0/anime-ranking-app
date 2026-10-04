import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Copertina quadrata dell'anime con fallback sull'iniziale.
///
/// Sta in `core/ui` e non dentro la schermata della classifica perche' lo
/// usano quattro schermate diverse — classifica, watchlist, duelli e tornei —
/// e definirlo in una sola di esse significava che le altre tre lo importassero da
/// una feature che non c'entra: una modifica alla classifica avrebbe potuto
/// rompere i tornei.
///
/// E' quadrata e non in 2:3 perche' qui la copertina e' un segnalino accanto
/// al titolo, non l'elemento principale della riga: l'area che le serve e'
/// quella di un'icona grande, e obbligarla alle proporzioni del poster
/// allungherebbe ogni riga senza aggiungere informazione.
class AnimeThumb extends StatelessWidget {
  const AnimeThumb({
    required this.title,
    this.url,
    this.size = 40,
    this.radius = 8,
    this.heroTag,
    super.key,
  });

  final String title;
  final String? url;
  final double size;

  /// Angoli della copertina.
  ///
  /// Parametro e non costante perche' la stessa copertina compare a due
  /// scale: arrotondata forte nella card, dove e' piccola e gli angoli vivi
  /// sembrerebbero un taglio, e quasi piatta nella tabella, dove la griglia
  /// chiede celle che si allineino.
  final double radius;

  /// Tag della transizione condivisa verso la scheda.
  ///
  /// Facoltativo perche' la stessa copertina compare anche dentro una tabella
  /// dove il riquadro e' piccolo: l'hero su una cella da 32px che raddoppia
  /// durante il volo si legge come uno scatto.
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final fallback = ColoredBox(
      color: ArColors.containerHighest,
      child: Center(
        child: Text(
          title.trim().isEmpty ? '?' : title.trim()[0].toUpperCase(),
          style: theme.textTheme.titleSmall?.copyWith(
            color: ArColors.textMid,
            fontVariations: const [FontVariation('wght', 700)],
          ),
        ),
      ),
    );

    Widget image = SizedBox(
      width: size,
      height: size,
      child: (url == null || url!.isEmpty)
          ? fallback
          : Image.network(
              url!,
              fit: BoxFit.cover,
              // Senza gestione dell'errore, un URL rotto mostrerebbe il
              // riquadro grigio di Image.network senza dire nulla: peggio
              // del fallback, che almeno mostra di che anime si tratta.
              errorBuilder: (_, _, _) => fallback,
            ),
    );

    // L'hero avvolge solo l'immagine, non il ritaglio: se avvolgesse tutto, al
    // volo il bordo passerebbe dall'interno all'esterno e la copertina
    // "scoprirebbe" uno spigolo durante il movimento.
    if (heroTag != null) {
      image = Hero(
        tag: heroTag!,
        flightShuttleBuilder: (context, animation, direction, from, to) =>
            ScaleTransition(scale: animation, child: image),
        child: image,
      );
    }

    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: image);
  }
}