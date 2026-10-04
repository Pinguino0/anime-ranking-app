import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Pastiglia di stato, con due modi.
///
/// Esiste perche' la stessa identita' — "questa cosa e' in stato X" — compariva
/// in tre schermate con tre implementazioni leggermente diverse: il ruolo nei
/// gruppi, lo stato di un torneo, lo stato di unanime nella watchlist. Tre
/// copie della stessa pastiglia significano che fra un giorno una sara' larga 4px
/// piu' dell'altra e nessuno sapra' quale.
///

/// La scelta fra [filled] e [outline] non e' decorativa.
///
/// Il bordo serve quando il colore porta un'informazione che l'occhio arriva a
/// leggere per primo (un ruolo che non si vuole nascondere); il riempimento
/// serve quando lo stato e' una nota secondaria e il testo deve restare
/// leggibile su una superficie scura. Mescolandoli a caso la pastiglia sembra
/// piu' importante o meno importante a seconda della schermata.
class StatusPill extends StatelessWidget {
  const StatusPill({
    required this.label,
    required this.color,
    this.filled = false,
    this.icon,
    super.key,
  });

  /// Testo dello stato ("In corso", "Admin").
  final String label;

  /// Colore semantico dello stato: viene dal tema, mai scelto qui.
  final Color color;

  /// Riempimento colorato invece che bordo.
  final bool filled;

  /// Icona facoltativa davanti al testo.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: filled ? color.withValues(alpha: 0.12) : null,
        border: filled ? null : Border.all(color: color),
        borderRadius: BorderRadius.circular(ArRadii.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
