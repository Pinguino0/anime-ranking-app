import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'section_header.dart';
import 'transitions.dart';

/// Riga di contenuto scorrevole in orizzontale, con intestazione.
///
/// E' il blocco con cui e' costruita la home, e il nome e' quello dei servizi di
/// streaming perche' e' esattamente la metafora: la schermata non e' una lista da
/// scorrere in verticale, ma uno zampillo di viste affiancate che si esplorano a
/// scorrimento orizzontale.
///
/// Lo snap e' quello che distingue questa riga da una lista orizzontale generica.
/// Senza, l'utente trascina di tre locandine e vede tre locandine a meta':
/// nessuna e' centrata, nessuna e' in primo piano, e la riga sembra scorrere
/// senza mai fermarsi. Con lo snap ogni riga si ferma con una card intera al
/// centro, ed e' l'unico modo per sapere che si e' arrivati in fondo.
class ContentRow extends StatefulWidget {
  const ContentRow({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    this.subtitle,
    this.onSeeAll,
    this.itemWidth,
    this.height,
    this.padding = const EdgeInsets.symmetric(vertical: ArSpace.lg),
  });

  final String title;
  final String? subtitle;
  final int itemCount;
  final Widget Function(BuildContext, int) itemBuilder;
  final VoidCallback? onSeeAll;

  /// Larghezza di una card. Se manca, la riga la calcola dalla larghezza
  /// disponibile: e' il caso della home, dove le card devono riempirlo senza
  /// lasciare spazio morto a destra.
  final double? itemWidth;

  final double? height;
  final EdgeInsets padding;

  @override
  State<ContentRow> createState() => _ContentRowState();
}

class _ContentRowState extends State<ContentRow> {
  final ScrollController _scroll = ScrollController();

  /// Le frecce laterali si accendono solo quando c'e' qualcosa da scorrere in
  /// quella direzione. Una freccia sempre accesa che non fa niente e' peggio di
  /// nessuna freccia: promette un movimento che non avviene.
  bool _canGoBack = false;
  bool _canGoForward = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_syncArrows);
    // Il primo ricalcolo avviene dopo il primo layout: nel `initState` la
    // lista non ha ancora dimensioni, e `hasClients` sarebbe falso.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncArrows();
    });
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_syncArrows)
      ..dispose();
    super.dispose();
  }

  void _syncArrows() {
    if (!_scroll.hasClients) return;

    final position = _scroll.position;
    final back = position.pixels > 8;
    final forward = position.pixels < position.maxScrollExtent - 8;

    // Il confronto evita di chiamare `setState` a ogni frame dello scorrimento
    // quando le frecce non sono cambiate di stato: su un carosello lungo
    // ricostruire l'intestazione a 60Hz non serve a nulla.
    if (back != _canGoBack || forward != _canGoForward) {
      setState(() {
        _canGoBack = back;
        _canGoForward = forward;
      });
    }
  }

  void _scrollBy(double dx) {
    if (!_scroll.hasClients) return;
    final target = (_scroll.offset + dx).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(
      target,
      duration: ArMotion.base,
      curve: ArMotion.enter,
    );
  }

  @override
  Widget build(BuildContext context) {
    final horizontal = ArSpace.page(context).left;
    final width = widget.itemWidth ?? _widthFor(context, horizontal);
    // La card e' in 2:3 con sotto il titolo: si aggiunge lo spazio del blocco
    // testo. Senza, l'ultima card verrebbe tagliata dal bordo inferiore.
    final height = widget.height ?? width * 3 / 2 + 52;

    return Padding(
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: widget.title,
            subtitle: widget.subtitle,
            action: widget.onSeeAll,
            actionLabel: widget.onSeeAll == null ? null : 'Vedi tutto',
          ),
          const SizedBox(height: ArSpace.sm),
          Stack(
            children: [
              SizedBox(
                height: height,
                // `ListView.builder` e non `separated`: lo snap ha bisogno di
                // `itemExtent`, e solo il builder lo accetta. Il separatore
                // diventa un elemento pari agli altri e occupa la stessa
                // ampiezza, cosi' l'estensione resta costante.
                child: ListView.builder(
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.symmetric(horizontal: horizontal),
                  itemCount: widget.itemCount * 2 - 1,
                  itemExtent: width + ArSpace.sm,
                  itemBuilder: (context, i) {
                    if (i.isOdd) return const SizedBox(width: ArSpace.sm);

                    final index = i ~/ 2;
                    return ArReveal(
                      // Il ritardo cresce con la posizione e si ferma: oltre il
                      // limite, le card piu' a destra arriverebbero cosi' tardi
                      // che l'utente le cercherebbe gia' come se mancassero.
                      delayMs: (index * 40).clamp(0, 320),
                      child: SizedBox(
                        width: width,
                        child: widget.itemBuilder(context, index),
                      ),
                    );
                  },
                ),
              ),
              // Le frecce stanno sopra la lista e coprono la card parziale:
              // e' la posizione in cui l'occhio si trova gia', perche' sta
              // guardando il bordo.
              if (widget.itemCount > 1) ...[
                if (_canGoBack)
                  _Arrow(
                    left: true,
                    onTap: () => _scrollBy(-width * 2),
                  ),
                if (_canGoForward)
                  _Arrow(
                    left: false,
                    onTap: () => _scrollBy(width * 2),
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// Larghezza della card calcolata sullo spazio disponibile.
  ///
  /// L'obiettivo e' mostrare un numero intero di card che arrivi al bordo
  /// destro: una card in piu' tagliata a meta' fa pensare che la riga vada
  /// avanti anche quando e' gia' finita, ed e' l'effetto opposto di quello che
  /// si vuole.
  double _widthFor(BuildContext context, double horizontal) {
    final available = MediaQuery.sizeOf(context).width - horizontal * 2;
    const gap = ArSpace.sm;

    // Da 2 a 6 card: sotto due la riga sembra un pannello, sopra sei le
    // locandine diventano troppo piccole per leggere il titolo.
    final count = switch (available) {
      < 320 => 2,
      < 520 => 3,
      < 760 => 4,
      < 1040 => 5,
      _ => 6,
    };

    return (available - gap * (count - 1)) / count;
  }
}

/// Freccia di scorimento.
///
/// Sul lato sinistro e' appoggiata al bordo, su quello destro e' distanziata:
/// non per un effetto, ma perche' la freccia sinistra e' "torna indietro" e
/// quella destra e' "avanti" — mettendole alla stessa distanza dal bordo
/// sembrerebbero due controlli equivalenti della stessa cosa.
class _Arrow extends StatelessWidget {
  const _Arrow({required this.left, required this.onTap});

  final bool left;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PositionedDirectional(
      start: left ? 2 : null,
      end: left ? null : 2,
      top: 0,
      bottom: 52,
      child: Center(
        child: ArPressable(
          onTap: onTap,
          scale: 0.9,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: ArColors.containerHigh.withValues(alpha: 0.92),
              shape: BoxShape.circle,
              border: Border.all(color: ArColors.border),
              boxShadow: ArShadows.panel,
            ),
            child: SizedBox(
              width: 38,
              height: 38,
              child: Icon(
                left ? Icons.chevron_left : Icons.chevron_right,
                size: 22,
                color: ArColors.textHigh,
              ),
            ),
          ),
        ),
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
            // L'icona ha alone colorato e non un semplice riquadro grigio: e'
            // l'unico elemento "vivo" di una pagina vuota, e con un bordo
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

/// Stato di errore.
///
/// Esiste perche' sette schermate ne avevano una copia identica: uno stesso
/// errore mostrato con sette componenti leggermente diversi fa pensare che il
/// guasto sia a intermittenza.
///
/// Il testo non e' mai un'eccezione: arriva gia' tradotto dalla failure del
/// provider, e quello che si stampa qui e' la frase che l'utente puo' usare per
/// capire cosa fare.
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.message,
    this.onRetry,
    this.icon = Icons.cloud_off,
    this.retryLabel = 'Riprova',
  });

  final String message;

  /// Azione di recupero.
  ///
  /// Senza, l'errore e' mostrato senza bottone: e' il caso degli errori che non
  /// si risolvono ripetendo la richiesta, dove un "Riprova" prometterebbe una
  /// cosa che l'app non puo' fare.
  final VoidCallback? onRetry;

  final IconData icon;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: icon,
      title: 'Qualcosa non ha funzionato',
      message: message,
      action: onRetry == null
          ? null
          : FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 19),
              label: Text(retryLabel),
            ),
    );
  }
}

/// Scheletro che pulsa.
///
/// Un rettangolo grigio fisso sembra un elemento provvisorio dimenticato; lo
/// stesso rettangolo che pulsa leggermente si legge come "sta arrivando". Il
/// contrasto fra scheletro e superficie e' volutamente basso: uno scheletro che
/// si stacca nettamente dal fondo ruba l'attenzione al contenuto che sta
/// sostituendo.
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height = 16,
    this.radius = ArRadii.chip,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: Color.lerp(
              ArColors.containerLow,
              ArColors.containerHigh,
              _controller.value,
            ),
            borderRadius: BorderRadius.circular(widget.radius),
          ),
        );
      },
    );
  }
}

/// Scheletro di una griglia di locandine.
///
/// Esposto perche' lo usano tre schermate diverse (home, ricerca, watchlist) e
/// ognuna rifacendolo avrebbe finito per dare tre geometrie leggermente diverse
/// alla stessa attesa.
class PosterGridSkeleton extends StatelessWidget {
  const PosterGridSkeleton({
    super.key,
    this.columns = 4,
    this.itemWidth = 132,
    this.itemCount = 8,
  });

  final int columns;
  final double itemWidth;
  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: ArSpace.md),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisExtent: itemWidth * 3 / 2 + 52,
        crossAxisSpacing: ArSpace.sm,
        mainAxisSpacing: ArSpace.sm,
      ),
      itemCount: itemCount,
      itemBuilder: (_, _) => const SkeletonBox(height: double.infinity, radius: ArRadii.card),
    );
  }
}
