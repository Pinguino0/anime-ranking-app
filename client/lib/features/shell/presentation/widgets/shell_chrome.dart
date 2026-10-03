import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/ui/transitions.dart';

/// Una voce di navigazione.
///
/// Icona doppia perche' una voce selezionata che cambia simbolo si legge come
/// "ora sei da un'altra parte", mentre una che resta identica sembra un
/// semaforo che non si accende.
class ArDestination {
  const ArDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Il nome dell'app.
///
/// "Anime" in grigio e "Rank" col gradiente del brand: il nome dice due cose
/// diverse e anche il colore le distingue. Il gradiente da solo non basterebbe
/// perche' su fondo scuro il viola del tema e' gia' il colore del testo
/// selezionato, quindi la parola chiara regge il contrasto e il gradiente la
/// rifinisce invece di sostituirla.
class BrandMark extends StatelessWidget {
  const BrandMark({this.size = 21, super.key});

  final double size;

  @override
  Widget build(BuildContext context) {
    // La parola "Anime" e' lunga e va ridotta perche' il segno sta anche in
    // testa alla barra laterale, che non e' larga come un'intestazione.
    final style = TextStyle(
      fontFamily: AppTheme.displayFont,
      fontSize: size,
      // Il font e' variabile: senza `fontVariations` il peso qui non cambierebbe
      // e la parola sembrerebbe scritta col corpo del testo.
      fontVariations: const [FontVariation('wght', 800)],
      letterSpacing: -0.5,
      height: 1.1,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Anime', style: style.copyWith(color: ArColors.textHigh)),
        ShaderMask(
          // Il gradiente viene applicato a un riquadro largo quanto la sola
          // parola "Rank": se prendesse tutta la riga, il viola arriverebbe
          // anche sull'iniziale di "Anime" e l'effetto si perde.
          shaderCallback: (bounds) => ArColors.brand.createShader(bounds),
          child: Text(
            'Rank',
            // Il colore e' bianco solo perche' il gradiente lo sostituisce:
            // il testo al di sotto e' quello che si vede se il gradiente
            // fallisce.
            style: style.copyWith(color: Colors.white),
          ),
        ),
      ],
    );
  }
}

/// Barra di navigazione in basso.
///
/// Al posto della `NavigationBar` di Material perche' quella mette un cerchio
/// piatto dietro l'icona selezionata: su fondo scuro un alone cosi' tenue non
/// dice "sei qui", dice "e' successo qualcosa qui vicino". Qui la pastiglia ha
/// il gradiente del brand, che e' lo stesso accento dei pulsanti e delle
/// medaglie, e si assesta invece di comparire.
class ArBottomBar extends StatelessWidget {
  const ArBottomBar({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelect,
    super.key,
  });

  final List<ArDestination> destinations;

  /// Voce attiva.
  ///
  /// Va tenuta dentro [destinations]: la barra disegna la pastiglia su questa
  /// posizione e un indice fuori elenco porterebbe a un accesso che non esiste,
  /// quindi chi la costruisce e' responsabile di passare un indice valido.
  final int selectedIndex;

  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      // Bordo in alto e non ombra: sopra il contenuto scuro un'ombra non si
      // vede, e il bordo e' l'unico modo di dire che qui comincia un piano
      // diverso dal resto dello schermo.
      decoration: const BoxDecoration(
        color: ArColors.containerLow,
        border: Border(top: BorderSide(color: ArColors.borderSoft)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              for (var i = 0; i < destinations.length; i++)
                Expanded(
                  child: _BarItem(
                    destination: destinations[i],
                    selected: i == selectedIndex,
                    onTap: () => onSelect(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Una voce della barra di basso.
class _BarItem extends StatelessWidget {
  const _BarItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final ArDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = destination.label;

    return ArPressable(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedContainer(
            duration: ArMotion.base,
            curve: ArMotion.enter,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              gradient: selected ? ArColors.brand : null,
              borderRadius: BorderRadius.circular(ArRadii.chip),
              // L'alone segue la pastiglia e sparisce con lei: senza, la voce
              // non selezionata avrebbe un alone che non spiega nulla.
              boxShadow: selected
                  ? ArShadows.glow(ArColors.primary, strength: 0.28)
                  : null,
            ),
            child: Icon(
              selected ? destination.selectedIcon : destination.icon,
              size: 21,
              color: selected ? Colors.white : ArColors.textMid,
            ),
          ),
          const SizedBox(height: ArSpace.xxs),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: AppTheme.displayFont,
              fontSize: 10.5,
              color: selected ? ArColors.textHigh : ArColors.textLow,
              fontVariations: [
                FontVariation('wght', selected ? 700 : 500),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Barra laterale da desktop.
///
/// Non un `NavigationRail` per la stessa ragione della barra in basso, e per
/// una seconda: il `NavigationRail` etichetta ogni voce nello spazio della
/// striscia e su una finestra stretta le parole si accavallano. Qui la voce e'
/// una riga intera, quindi l'etichetta ha spazio per restare leggibile anche
/// con nomi lunghi come "Watchlist".
class ArNavRail extends StatelessWidget {
  const ArNavRail({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelect,
    this.width = 236,
    super.key,
  });

  final List<ArDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final double width;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: ArColors.container,
        border: Border(right: BorderSide(color: ArColors.borderSoft)),
      ),
      child: SizedBox(
        width: width,
        child: SafeArea(
          right: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(ArSpace.lg, ArSpace.lg, ArSpace.md, ArSpace.lg),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: BrandMark(),
                ),
              ),
              // La lista scorre invece di essere centrata: su una finestra
              // bassa sette voci piu' il segno non ci starebbero, e una barra
              // laterale che taglia le voci nasconderebbe proprio la sezione
              // aperta.
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: ArSpace.sm),
                  itemCount: destinations.length,
                  itemBuilder: (context, i) => _RailItem(
                    destination: destinations[i],
                    selected: i == selectedIndex,
                    onTap: () => onSelect(i),
                  ),
                ),
              ),
              const SizedBox(height: ArSpace.lg),
            ],
          ),
        ),
      ),
    );
  }
}

/// Una voce della barra laterale.
class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final ArDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ArPressable(
      onTap: onTap,
      scale: 0.98,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Container(
          height: 46,
          padding: const EdgeInsets.only(left: ArSpace.sm, right: ArSpace.sm),
          decoration: BoxDecoration(
            color: selected
                ? ArColors.primary.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(ArRadii.control),
          ),
          child: Row(
            children: [
              // Filetto a sinistra che segna la voce attiva. Ha sempre la stessa
              // larghezza, anche quando non e' mostrato: se comparisse insieme
              // al fondo, tutte le icone si sposterebbero di tre pixel nel
              // momento del tocco e la barra sembrerebbe spostarsi.
              AnimatedContainer(
                duration: ArMotion.base,
                curve: ArMotion.enter,
                width: 3,
                height: 22,
                decoration: BoxDecoration(
                  color: selected ? ArColors.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: ArSpace.sm),
              Icon(
                selected ? destination.selectedIcon : destination.icon,
                size: 21,
                color: selected ? ArColors.primary : ArColors.textMid,
              ),
              const SizedBox(width: ArSpace.sm),
              Expanded(
                child: Text(
                  destination.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AppTheme.displayFont,
                    fontSize: 14,
                    color: selected ? ArColors.textHigh : ArColors.textMid,
                    fontVariations: [
                      FontVariation('wght', selected ? 700 : 500),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}