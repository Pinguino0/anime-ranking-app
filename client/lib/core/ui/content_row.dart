import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'poster_card.dart';
import 'transitions.dart';

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
    final horizontal = ArSpace.page(context).left;

    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontal),
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
          const SizedBox(height: ArSpace.sm),
          SizedBox(
            height: height ?? PosterCard.rowHeight,
            // Le celle appaiono a ondate. Su una riga lunga, senza, tutte le
            // locandine comparirebbero insieme quando arriva la pagina e la
            // pagina sembrerebbe un salto di contenuto.
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: horizontal),
              itemCount: itemCount,
              separatorBuilder: (_, _) => const SizedBox(width: ArSpace.sm),
              itemBuilder: (context, i) => ArReveal(
                // Il ritardo cresce con la posizione e si ferma: oltre il
                // limite, le card piu' a destra arriverebbero cosi' tardi che
                // l'utente le cercherebbe gia' come se mancassero.
                delayMs: (i * 40).clamp(0, 320),
                child: itemBuilder(context, i),
              ),
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
        padding: const EdgeInsets.all(ArSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // L'icona ha alone colorato e non un semplice riquadro grigio:
            // e' l'unico elemento "vivo" di una pagina vuota, e con un bordo
            // neutro sembrerebbe un'immagine rotta.
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    colors.primary.withValues(alpha: 0.18),
                    colors.secondary.withValues(alpha: 0.08),
                  ],
                ),
                borderRadius: BorderRadius.circular(ArRadii.control),
                border: Border.all(
                  color: colors.primary.withValues(alpha: 0.25),
                ),
              ),
              child: Icon(icon, size: 32, color: colors.primary),
            ),
            const SizedBox(height: ArSpace.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: ArSpace.xs),
            // Il testo non supera una misura: a schermo largo una riga sola
            // porterebbe il messaggio a 1400px di larghezza e l'occhio non
            // saprebbe dove iniziare.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: ArSpace.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}