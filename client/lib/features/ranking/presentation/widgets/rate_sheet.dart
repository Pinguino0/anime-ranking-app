import 'package:flutter/material.dart';

import '../../../../core/ui/controls.dart';
import '../../domain/ranking.dart';

/// Voto formattato per la conferma a schermo.
///
/// 7 e non "7.0", 7.5 e non "7.50": il testo di un messaggio non ha bisogno di
/// due decimali, e l'allineamento a due cifree in una lista di messaggi e'
/// rumore.
String formatVote(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(1);

/// Foglio di votazione.
///
/// Un cursore a passo 0.5 da 0 a 10 con il valore grande in alto: scegliere
/// 7.5 con due cursori separati ("intero" e "mezzo punto") e' esatto ma
/// scomodo, e una griglia di 21 pulsanti occuperebbe meta' schermo.
///
/// Stateful e non `StatefulBuilder` dentro uno stateless: il valore scelto
/// deve sopravvivere al rebuild del foglio, e un campo su una classe senza
/// stato viene ricreato a ogni build.
///
/// Vive in `widgets/` e non dentro la schermata della classifica perche' anche
/// la scheda anime lo apre: votare e' la stessa azione nei due punti, e due
/// copie del cursore finirebbero per divergere sul passo o sulla scala.
class RateSheet extends StatefulWidget {
  const RateSheet({required this.entry, super.key});

  final RankingEntry entry;

  @override
  State<RateSheet> createState() => _RateSheetState();
}

class _RateSheetState extends State<RateSheet> {
  /// Voto in modifica, null finche' l'utente non tocca il cursore.
  double? _chosen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = widget.entry;

    // Parte dal voto gia' dato: riaprire il foglio non deve far partire da
    // zero un utente che sta solo correggendo un mezzo punto.
    final value = _chosen ?? entry.myScore ?? 7;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(entry.displayTitle, style: theme.textTheme.titleMedium),
            if (entry.genres.isNotEmpty)
              Text(
                entry.genres.take(3).join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 20),
            // Il voto va da 0 a 10: due estremita' in vista dicono il dominio
            // senza dover spingere il cursore in fondo per scoprire che il
            // massimo non e' 100.
            ArSlider(
              value: value,
              min: RatingValidators.min,
              max: RatingValidators.max,
              // 21 divisioni = 21 posizioni da 0 a 10: sotto il mezzo punto il
              // database rifiuterebbe il voto, quindi il cursore non lo offre.
              divisions:
                  ((RatingValidators.max - RatingValidators.min) /
                          RatingValidators.step)
                      .round(),
              // `formatVote` toglie il ".0" finale: "8" e non "8.0", che
              // sembrerebbe una media calcolata invece di un voto dato.
              format: formatVote,
              // Letto ad alta voce "8" non dice niente; "8 su 10" si'.
              semanticFormatter: (v) => '${formatVote(v)} su 10',
              caption: '0 = pessimo, 10 = capolavoro.',
              onChanged: (v) => setState(() => _chosen = v),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Annulla'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(value),
                    child: const Text('Vota'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
