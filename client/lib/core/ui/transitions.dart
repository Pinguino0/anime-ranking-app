import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/app_theme.dart';

/// Transizioni e micro-animazioni condivise.
///
/// Sono qui, e non in ogni schermata, perche' una transizione scritta due volte
/// con due durate diverse e' la ragione per cui un'app sembra " assemblata":
/// il salto fra schermate deve essere sempre lo stesso, come il modo in cui
/// una card risponde a una pressione.
///
/// Il trucco comune a tutte e' la stessa: l'elemento parte leggermente
/// ridotto e spostato, e si assesta. Su schermo scuro un'animazione di
/// solo opacita' sembra un cambiamento di luminosita' — la scala e' quello che
/// si percepisce come " movimento".

/// Transizione della rotta: scorrimento laterale.
///
/// E' la scelta standard su telefono perche' comunica "sei andato avanti" e
/// non "e' apparsa una pagina nuova". Il ritorno usa il verso opposto: senza,
/// andare avanti e tornare indietro sembrerebbero lo stesso gesto.
///
/// Restituisce una [CustomTransitionPage] e non una `PageRoute` perche'
/// `GoRouter.pageBuilder` chiede una `Page`: e' il tipo con cui il router
/// costruisce il proprio stack di navigazione.
CustomTransitionPage<T> arRoute<T>({
  required Widget child,
  String? name,
  Object? arguments,
}) {
  return CustomTransitionPage<T>(
    name: name,
    arguments: arguments,
    transitionDuration: ArMotion.base,
    reverseTransitionDuration: ArMotion.fast,
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, page) {
      // `secondaryAnimation` parte da 1 quando la pagina precedente e' ancora
      // in primo piano ed e' a 0 quando e' gia' uscita: e' il segnale che
      // distingue "sto andando avanti" da "sto tornando indietro".
      final isForward = secondaryAnimation.value == 0.0;
      final begin = Offset(isForward ? 0.06 : -0.06, 0);
      final end = Offset(isForward ? -0.06 : 0.06, 0);

      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: const Interval(0, 0.7, curve: ArMotion.enter),
          reverseCurve: ArMotion.exit,
        ),
        child: SlideTransition(
          position: Tween<Offset>(begin: begin, end: end).animate(
            CurvedAnimation(parent: animation, curve: ArMotion.enter),
          ),
          child: ScaleTransition(
            // Leggera: sotto il 2% si nota come "approssimazione", sopra il 4%
            // sembra uno zoom. 1.5% e' appena percettibile e da' profondita'.
            scale: Tween<double>(begin: 1.015, end: 1).animate(
              CurvedAnimation(parent: animation, curve: ArMotion.enter),
            ),
            child: page,
          ),
        ),
      );
    },
  );
}

/// Transizione della rotta per la scheda a tutta pagina.
///
/// Diversa da [arRoute] per un motivo preciso: la scheda anime ha un'immagine
/// di sfondo che copre tutta la pagina. Se l'immagine attraversasse lo
/// schermo scorrendosi, l'occhio la seguirebbe e sembrerebbe che la pagina
/// "scivola via". Qui l'immagine resta al suo posto e il testo sale dal basso: si
/// capisce che ci si e' avvicinati al contenuto.
///
/// Il ritardo di 0.15 sull'ingresso serve a una cosa precisa: se tutto
/// appare insieme, l'occhio legge il titolo solo dopo che la pagina ha
/// smesso di muoversi. Con il ritardo il titolo e' gia' fermo mentre il resto
/// della pagina si asseta.
CustomTransitionPage<T> arDetailRoute<T>({
  required Widget child,
  String? name,
  Object? arguments,
}) {
  return CustomTransitionPage<T>(
    name: name,
    arguments: arguments,
    transitionDuration: ArMotion.slow,
    reverseTransitionDuration: ArMotion.base,
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, page) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: const Interval(0, 0.6, curve: ArMotion.enter),
        ),
        // Sale di poco piu' di 6% dell'altezza: abbastanza da sembrare un
        // ingresso, poco da far aspettare.
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.06),
            end: Offset.zero,
          ).animate(
            CurvedAnimation(
              parent: animation,
              curve: const Interval(0.15, 1, curve: ArMotion.enter),
            ),
          ),
          child: page,
        ),
      );
    },
  );
}

/// Sorgente condivisa di un'animazione di comparsa.
///
/// Il parametro `stagger` e' quello che trasforma una lista di elementi che
/// appaiono insieme in una lista che appare a ondate: ogni elemento parte un
/// po' dopo il precedente. Su una griglia di poster l'effetto e' quello che
/// fa capire che gli elementi sono stati caricati e non disegnati a caso.
///
/// Il ritardo e' volutamente corto (35ms): con 60ms l'ultima card di una riga
/// da sei aspetterebbe quasi un terzo di secondo, e l'attesa si sente come un
/// ritardo dell'app invece che come un effetto.
class ArReveal extends StatefulWidget {
  const ArReveal({
    required this.child,
    this.delayMs = 0,
    this.offset = 18,
    this.duration = ArMotion.slow,
    super.key,
  });

  final Widget child;

  /// Ritardo di questo elemento rispetto all'inizio della sequenza.
  final int delayMs;

  /// Quanto l'elemento sale, in pixel logici.
  final double offset;

  final Duration duration;

  @override
  State<ArReveal> createState() => _ArRevealState();
}

class _ArRevealState extends State<ArReveal> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  late final Animation<double> _opacity = CurvedAnimation(
    parent: _controller,
    curve: ArMotion.enter,
  );

  late final Animation<Offset> _slide = Tween<Offset>(
    begin: Offset(0, widget.offset / 100),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _controller, curve: ArMotion.enter));

  @override
  void initState() {
    super.initState();
    if (widget.delayMs == 0) {
      _controller.forward();
    } else {
      // Il ritardo parte dopo il primo frame: avviarlo dentro `initState`
      // metterebbe in pausa il timer del framework, e l'animazione partirebbe
      // insieme al resto dello schermo o non partirebbe.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Future<void>.delayed(
          Duration(milliseconds: widget.delayMs),
          () {
            if (mounted) _controller.forward();
          },
        );
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

/// Card che risponde alla pressione con un leggero restringimento.
///
/// Il motivo per cui il tocco "scava" la card invece di sollevarla: su fondo
/// scuro la crescita si legge come un'allungamento, mentre l'affossamento si
/// legue come una pressione vera, e il ritorno elastico conferma che il tocco
/// e' stato registrato.
///
/// Il tocco e' tenuto in un controller e non in `setState` perche' il valore
/// cambia a ogni frame: ricostruire tutto l'albero a 60Hz per un'animazione di
/// mezzo secondo e' il modo piu' semplice di far scattare un'app.
class ArPressable extends StatefulWidget {
  const ArPressable({
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.965,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Fattore di riduzione alla pressione.
  final double scale;

  @override
  State<ArPressable> createState() => _ArPressableState();
}

class _ArPressableState extends State<ArPressable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: ArMotion.fast,
    reverseDuration: ArMotion.base,
  );

  late final Animation<double> _scale = Tween<double>(
    begin: 1,
    end: widget.scale,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

  bool get _enabled => widget.onTap != null || widget.onLongPress != null;

  void _setPressed(bool pressed) {
    if (!_enabled) return;
    if (pressed) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.child;

    if (!_enabled) return child;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      child: ScaleTransition(scale: _scale, child: child),
    );
  }
}

/// Entrata a ondate per un elenco.
///
/// Applica [ArReveal] a ogni elemento con un ritardo crescente. Il ritardo si
/// calcola dal modo della griglia e non dall'indice assoluto: nell'ultima riga
/// di una griglia gli ultimi elementi arrivano tutti insieme altrimenti, e si
/// vede lo "scalino" che interrompe l'onda.
///
/// Stacka in verticale: dentro un `ListView` o un carosello orizzontale va
/// usato [ArReveal] direttamente, perche' un `Column` dentro una lista
/// orizzontale si comporterebbe come un unico elemento largo.
class ArStaggered extends StatelessWidget {
  const ArStaggered({
    required this.itemCount,
    required this.itemBuilder,
    this.stepMs = 35,
    this.maxDelayMs = 420,
    this.columns = 1,
    super.key,
  });

  final int itemCount;
  final Widget Function(BuildContext, int) itemBuilder;

  /// Ritardo aggiuntivo per ogni elemento successivo.
  final int stepMs;

  /// Tetto del ritardo: oltre, gli ultimi elementi arrivano talmente tardi che
  /// l'utente li crede mancanti.
  final int maxDelayMs;

  /// Numero di colonne, per spezzare l'onda riga per riga.
  final int columns;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < itemCount; i++)
          () {
            final withinRow = columns > 1 ? i % columns : i;
            final rowStart = columns > 1 ? (i ~/ columns) * columns : 0;
            final delay = ((rowStart + withinRow) * stepMs).clamp(0, maxDelayMs);

            return ArReveal(
              key: ValueKey(i),
              delayMs: delay,
              child: itemBuilder(context, i),
            );
          }(),
      ],
    );
  }
}

/// Contatore che sale fino al valore finale.
///
/// Usato sui numeri in evidenza (voti, membri, posizione). Un numero che
/// appare gia' a posto e' un dato; un numero che arriva contando e' un
/// risultato, e l'occhio ci resta sopra un secondo in piu'. Il conteggio non
/// parte se il valore iniziale e' gia' vicino: per 3 da 0 l'effetto durerebbe
/// piu' del messaggio che il numero doveva comunicare.
class ArCountUp extends StatelessWidget {
  const ArCountUp({
    required this.value,
    required this.builder,
    this.duration = const Duration(milliseconds: 900),
    this.decimals = 0,
    super.key,
  });

  final double value;
  final Widget Function(BuildContext, double) builder;
  final Duration duration;
  final int decimals;

  @override
  Widget build(BuildContext context) {
    // Sotto 1% di variazione il conteggio non si vede ma fa comunque perdere
    // tempo: in quel caso si mostra il valore finale e basta.
    if (value.abs() < 1) {
      return builder(context, value);
    }

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, animated, _) => builder(context, animated),
    );
  }
}

/// Bottone che ha il gradiente del brand.
///
/// Il gradiente pieno e' riservato all'azione principale della pagina: se lo
/// usassero tutti i pulsanti, l'occhio non saprebbe piu' quale premere e la
/// pagina sembrerebbe tutta importante, quindi niente.
///
/// Il gradiente scorre appena alla pressione per dare un segnale tattile anche
/// su un bottone che non si muove nel layout.
class ArGradientButton extends StatelessWidget {
  const ArGradientButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final button = DecoratedBox(
      decoration: BoxDecoration(
        gradient: enabled ? ArColors.brand : null,
        color: enabled ? null : Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(ArRadii.control),
        boxShadow: enabled
            ? ArShadows.glow(ArColors.primary, strength: 0.34)
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 19, color: Colors.white),
              const SizedBox(width: ArSpace.sm),
            ],
            Text(
              label,
              style: const TextStyle(
                fontFamily: AppTheme.bodyFont,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                fontVariations: [FontVariation('wght', 700)],
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );

    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: ArPressable(
        onTap: onPressed,
        child: button,
      ),
    );
  }
}
