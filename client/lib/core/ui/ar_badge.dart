import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/section_accent.dart';

/// Riquadro con un'icona, tinto con l'accento della sezione.
///
/// E' il "segno" che accompagna una voce o un numero: nei fogli di scelta, nei
/// blocchi statistici, accanto a un titolo. Esiste perche' la stessa idea —
/// un'icona dentro un riquadro tinto — compariva in tre punti disegnata a mano,
/// e ogni copia aveva un raggio e un'alpha leggermente diversi.
///
/// Il colore non e' un parametro obbligatorio: se manca, prende l'accento della
/// sezione corrente da [SectionAccentScope]. E' il caso piu' comune, cosi' una
/// voce dei gruppi si tinge di teal anche se nessuno gliel'ha detto.
class ArBadge extends StatelessWidget {
  const ArBadge({
    required this.icon,
    this.color,
    this.size = 42,
    this.radius,
    this.filled = true,
    this.outline = false,
    this.iconSize,
    super.key,
  });

  /// Icona al centro del riquadro.
  final IconData icon;

  /// Tinta del riquadro e dell'icona. Se manca, l'accento della sezione.
  final Color? color;

  /// Lato del riquadro quadrato.
  final double size;

  /// Raggio degli angoli. Se manca, segue la taglia del badge.
  final double? radius;

  /// Riempimento tenue invece che solo bordo.
  ///
  /// Il riempimento serve quando il badge apre un blocco ed e' la prima cosa
  /// che l'occhio incontra; il solo bordo quando e' una nota accanto al testo,
  /// dove un fondo colorato peserebbe quanto il testo stesso.
  final bool filled;

  /// Bordo tenue anche quando il riquadro e' pieno.
  ///
  /// Il solo riempimento al 14% su una superficie gia' tinta — una card, un
  /// foglio — si perde: il bordo ridisegna il contorno e il badge resta
  /// leggibile senza alzare l'alpha del fondo, che coprirebbe l'icona.
  final bool outline;

  /// Dimensione dell'icona. Se manca, e' meta' del riquadro.
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? SectionAccentScope.of(context).base;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: filled ? tint.withValues(alpha: 0.14) : null,
        border: (filled && !outline)
            ? null
            : Border.all(
                // Pieno con bordo: contorno appena visibile, perche' il fondo
                // c'e' gia'. Solo bordo: piu' netto, altrimenti il riquadro
                // vuoto scomparirebbe sulla superficie.
                color: tint.withValues(alpha: filled ? 0.28 : 0.45),
              ),
        borderRadius: BorderRadius.circular(radius ?? ArRadii.chip),
      ),
      child: Icon(icon, size: iconSize ?? size * 0.5, color: tint),
    );
  }
}
