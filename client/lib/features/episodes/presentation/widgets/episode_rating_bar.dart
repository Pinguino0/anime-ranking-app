import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/transitions.dart';

/// Voto su un singolo episodio, da 1 a 10.
///
/// Dieci pulsanti invece di uno slider perche' un episodio si vota una volta e
/// poi si dimentica: il costo di un tap e' minimo e il vantaggio e' che non si
/// puo' sbagliare a metà e lasciare il voto a 6,3.
///
/// Il voto non parte da [onChanged] ma viene salvato solo quando l'utente
/// preme "Salva". Un voto che si scrive a ogni passaggio su un numero
/// riempirebbe la tabella di righe e mostrerebbe un numero che cambia mentre
/// si guarda, il che e' fastidioso perche' non si sa piu' quanto si e' dato.
class EpisodeRatingBar extends StatelessWidget {
  const EpisodeRatingBar({
    required this.value,
    required this.onSave,
    this.onClear,
    this.enabled = true,
    this.saving = false,
    super.key,
  });

  /// Voto corrente, `null` se non ancora assegnato.
  final double? value;

  /// Chiamata con il voto da registrare, `null` per cancellarlo.
  final Future<void> Function(double? score) onSave;
  final VoidCallback? onClear;

  final bool enabled;
  final bool saving;

  /// Passo del voto.
  ///
  /// Mezzo punto come sull'opera: e' la stessa scala e l'utente che ha gia'
  /// votato un anime con 7,5 non deve ritrovarsi con una scala diversa quando
  /// passa all'episodio.
  static const double step = 0.5;

  /// Numero di voti proposti: 1,0 / 1,5 / … / 10,0.
  static const int count = 19;

  static double scoreAt(int index) => 1 + index * step;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final current = value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Vota questo episodio', style: theme.textTheme.titleSmall),
            const Spacer(),
            Text(
              current == null ? '—' : current.toStringAsFixed(1),
              style: theme.textTheme.titleMedium?.copyWith(
                color: current == null
                    ? colors.onSurfaceVariant
                    : ArColors.gold,
                fontVariations: const [FontVariation('wght', 600)],
              ),
            ),
          ],
        ),
        const SizedBox(height: ArSpace.sm),
        // Dieci cifre non entrano in una riga stretta: vanno a capo, e ognuna
        // occupa la stessa cella della griglia cosi' la barra di selezione non
        // cambia larghezza passando da 1 a 10.
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 10,
            mainAxisSpacing: ArSpace.xxs,
            crossAxisSpacing: ArSpace.xxs,
            childAspectRatio: 1.15,
          ),
          itemCount: count,
          itemBuilder: (context, index) {
            final score = scoreAt(index);
            final picked = current != null && score <= current;

            return ArPressable(
              onTap: enabled ? () => onSave(score) : null,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: picked
                      ? ArColors.gold.withValues(alpha: 0.16)
                      : colors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(ArRadii.chip),
                  border: Border.all(
                    color: picked
                        ? ArColors.gold.withValues(alpha: 0.5)
                        : colors.outlineVariant,
                  ),
                ),
                child: Center(
                  child: Text(
                    score.toStringAsFixed(1),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: picked ? ArColors.gold : colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        if (current != null) ...[
          const SizedBox(height: ArSpace.xs),
          // Il voto si scrive subito, ma cancellarlo e' un atto deliberato e
          // deve stare vicino al numero per non confondersi con "salva".
          ArPressable(
            onTap: enabled && !saving ? () => onClear?.call() : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: ArSpace.xxs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.close_rounded,
                      size: 15, color: colors.onSurfaceVariant),
                  const SizedBox(width: ArSpace.xxs),
                  Text(
                    'Togli il voto',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}