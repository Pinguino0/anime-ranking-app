import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/section_accent.dart';

/// Intestazione di una sezione di contenuto.
///
/// Il titolo da solo non basta mai: una riga che dice "I piu' votati" senza
/// altro e' un'affermazione, e su un campione piccolo puo' essere falsa. Il
/// sottotitolo dice il criterio con cui i titoli sono stati scelti, ed e' quello
/// che distingue una sezione informativa da unadesivo.
///
/// Il filetto a sinistra e' l'elemento che tiene insieme le sezioni di una
/// pagina lunga: senza, scorrendo due schermate di caroselli l'occhio non trova
/// piu' il punto in cui la sezione comincia.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
    this.actionLabel,
    this.padding,
  });

  final String title;
  final String? subtitle;

  /// Azione a destra, mostrata solo se [actionLabel] c'e' o se [action] e' dato.
  final VoidCallback? action;

  /// Etichetta dell'azione. Se manca ma [action] c'e', si mostra la freccia
  /// da sola: il pulsante senza testo e' comunque cliccabile, e su schermi
  /// stretti il testo ruberebbe spazio al titolo.
  final String? actionLabel;

  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Il filetto prende la tinta della sezione corrente: entrando nella
    // classifica le intestazioni diventano oro, nei gruppi teal. Fuori da una
    // shell resta il gradiente del marchio, che e' quello di prima.
    final accent = SectionAccentScope.of(context);

    return Padding(
      padding: padding ?? EdgeInsets.symmetric(horizontal: ArSpace.page(context).left),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Filetto: due pixel che staccano l'intestazione dal contenuto che
          // segue. Alto quanto il titolo e non di piu': se arrivasse al fondo
          // del blocco sembrerebbe un bordo della card.
          Container(
            width: 3,
            height: 20,
            margin: const EdgeInsets.only(right: ArSpace.sm),
            decoration: BoxDecoration(
              gradient: accent.gradient,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: ArSpace.sm),
            if (actionLabel != null)
              TextButton(
                onPressed: action,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(actionLabel!),
                    const SizedBox(width: 2),
                    const Icon(Icons.chevron_right, size: 18),
                  ],
                ),
              )
            else
              IconButton(
                onPressed: action,
                tooltip: 'Vedi tutto',
                icon: const Icon(Icons.chevron_right),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ],
      ),
    );
  }
}

/// Etichetta piccola sopra un valore.
///
/// "Voti", "Membri", "Episodi". Va in maiuscolo e con spaziatura fra le
/// lettere: e' quello che distingue un'etichetta da un testo solo piu' piccolo,
/// e senza la differenza la cifra sembra parte della riga sopra.
class MetricLabel extends StatelessWidget {
  const MetricLabel(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: AppTheme.bodyFont,
        fontSize: 10.5,
        fontVariations: const [FontVariation('wght', 600)],
        letterSpacing: 0.8,
        color: color ?? ArColors.textLow,
      ),
    );
  }
}

/// Pastiglia selezionabile per filtri e stati.
///
/// Non il `FilterChip` di Material perche' quello ha due problemi in questa
/// app: il bordo sparisce in quello stato e il raggio e' piccolo rispetto al
/// resto del sistema. Qui il testo selezionato resta leggibile sopra il
/// riempimento colorato e il raggio segue [ArRadii.chip] come tutto il resto.
class ArChip extends StatelessWidget {
  const ArChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.iconColor,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  /// Colore dell'icona, quando il colore porta un significato.
  ///
  /// Senza questo parametro l'icona seguirebbe la selezione (viola o grigio),
  /// che va bene per i filtri ma non per i pallini di stato della watchlist:
  /// li, il colore e' l'informazione — "in visione" e "completato" hanno lo
  /// stesso testo e si distinguono solo per la tinta.
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    // La selezione prende la tinta della sezione corrente: nella watchlist i
    // filtri si accendono di blu, nella classifica di oro. Fuori da una shell
    // resta il viola del marchio, che e' quello di prima.
    final tint = SectionAccentScope.of(context).base;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: ArMotion.fast,
        curve: ArMotion.enter,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? tint.withValues(alpha: 0.18)
              : ArColors.containerLow,
          borderRadius: BorderRadius.circular(ArRadii.chip),
          border: Border.all(
            color: selected ? tint : ArColors.borderSoft,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 15,
                color: iconColor ??
                    (selected ? tint : ArColors.textLow),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontFamily: AppTheme.bodyFont,
                fontSize: 12.5,
                fontVariations: [
                  FontVariation('wght', selected ? 700 : 500),
                ],
                color: selected ? ArColors.textHigh : ArColors.textMid,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
