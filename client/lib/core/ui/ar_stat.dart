import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/section_accent.dart';
import 'section_header.dart';

/// Una cifra con la sua etichetta.
///
/// E' il blocco "12 · Membri" che compare nelle intestazioni di gruppo, nel
/// profilo e nei riepiloghi. Non e' solo `MetricLabel` piu' un numero: tiene
/// insieme la geometria (etichetta sopra, valore sotto, uno spazio sempre
/// uguale in mezzo), la tipografia del valore e l'icona facoltativa, che era la
/// parte che saltava da una schermata all'altra.
///
/// L'etichetta sta sopra al valore, non sotto: e' l'ordine con cui si legge un
/// dato in quest'app, ed e' lo stesso che usa [MetricLabel] da solo. Un
/// "12 / Voti" e un "Voti / 12" affiancati nello stesso riquadro sembrerebbero
/// due statistiche di natura diversa.
class ArStat extends StatelessWidget {
  const ArStat({
    required this.label,
    required this.value,
    this.icon,
    this.color,
    this.dense = false,
    this.align = CrossAxisAlignment.start,
    super.key,
  });

  /// Etichetta maiuscola sopra il valore ("VOTI", "MEMBRI").
  final String label;

  /// Il valore gia' formattato ("8.4", "128").
  final String value;

  /// Icona accanto al valore, tinta con [color].
  final IconData? icon;

  /// Tinta del valore e dell'icona. Se manca, il valore resta chiaro e l'icona
  /// prende l'accento della sezione.
  final Color? color;

  /// Versione compatta: valore piu' piccolo e passi ridotti, per le righe.
  final bool dense;

  /// Allineamento orizzontale del blocco.
  final CrossAxisAlignment align;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? SectionAccentScope.of(context).base;

    return Column(
      crossAxisAlignment: align,
      mainAxisSize: MainAxisSize.min,
      children: [
        MetricLabel(label),
        SizedBox(height: dense ? 2 : 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: dense ? 15 : 18, color: tint),
              const SizedBox(width: 5),
            ],
            Text(
              value,
              style: TextStyle(
                fontFamily: AppTheme.displayFont,
                fontSize: dense ? 19 : 25,
                fontWeight: FontWeight.w700,
                fontVariations: const [FontVariation('wght', 700)],
                letterSpacing: -0.6,
                height: 1,
                color: color ?? ArColors.textHigh,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
