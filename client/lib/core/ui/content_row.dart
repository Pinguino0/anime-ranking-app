import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'poster_card.dart';

/// Riga di contenuto scorrevole in orizzontale, con intestazione.
///
/// E' il blocco con cui e' costruita la home. Il nome "riga" e' quello delle
/// home dei servizi di streaming perche' e' esattamente la metafora: la schermata
/// non e' una lista da scorrere in verticale, ma uno zampillo di viste
/// affiancate che si esplorano a scorrimento orizzontale.
///
/// La larghezza dell'intestazione e' il segnaposto piu' importante: senza, a
/// fine carosello l'utente vede che il contenuto continua e puo' continuare a
/// scorrere per capirlo. Con, e' chiaro che va a lato.
class ContentRow extends StatelessWidget {
  const ContentRow({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    this.subtitle,
    this.onSeeAll,
    this.height,
    this.padding = const EdgeInsets.symmetric(vertical: 20),
  });

  final String title;

  /// Il criterio con cui i titoli sono stati scelti.
  ///
  /// Conta piu' del titolo: "I piu' votati" non dice nulla su un campione
  /// piccolo, mentre "voto medio del catalogo" dice subito quanto pesano questi
  /// titoli rispetto al resto.
  final String? subtitle;

  final int itemCount;
  final Widget Function(BuildContext, int) itemBuilder;
  final VoidCallback? onSeeAll;
  final EdgeInsets padding;

  /// Altezza della riga. Se manca si usa quella delle celle standard, cosi' le
  /// righe della stessa schermata hanno la stessa altezza anche se una usa
  /// poster piu' grandi dell'altra.
  final double? height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleLarge),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(subtitle!, style: theme.textTheme.bodySmall),
                      ],
                    ],
                  ),
                ),
                if (onSeeAll != null)
                  TextButton(
                    onPressed: onSeeAll,
                    child: const Text('Vedi tutto'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: height ?? PosterCard.rowHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: itemCount,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: itemBuilder,
            ),
          ),
        ],
      ),
    );
  }
}

/// Stato vuoto di una sezione.
///
/// Un'area vuota con dentro solo la parola "vuoto" sembra un errore. Qui si dice
/// cosa manca e cosa fare, che e' la differenza fra un'app che sembra rotta e
/// una che sembra in attesa.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(ArRadii.control),
              ),
              child: Icon(icon, size: 30, color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: 24),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}