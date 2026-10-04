import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

/// Prima lettera di un nome, per il fallback di [ProfileAvatar].
///
/// Sta qui e non dentro ogni schermata perche' la regola e' una sola: con una
/// stringa vuota restituirebbe un carattere vuoto e l'avatar sembrerebbe
/// rotto, quindi si lascia il segnaposto. Ripetere la funzione in tre file
/// avrebbe significato che il giorno in cui la si fosse voluta cambiare, una
/// parte degli avatar sarebbe rimasta con la lettera sbagliata.
String avatarInitial(String label) {
  final trimmed = label.trim();
  return trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();
}

/// Avatar con fallback su iniziale.
///
/// L'immagine viene rimpiazzata dall'iniziale se manca o se non si carica: un
/// riquadro grigio o l'icona di errore di [Image.network] non dicono nulla,
/// mentre l'iniziale identifica comunque la persona.
///
/// L'avatar porta sempre un bordo e un alone colorato. Su un fondo scuro un
/// cerchio pieno senza contorno si perde: il bordo e' quello che gli dà un
/// limite, l'alone quello che lo stacca dal testo che ci sta intorno.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    required this.fallbackText,
    required this.size,
    this.url,
    super.key,
  });

  final String? url;
  final String fallbackText;
  final double size;

  @override
  Widget build(BuildContext context) {
    final avatar = url?.isNotEmpty == true
        ? Image.network(
            url!,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stack) =>
                _Initials(fallbackText: fallbackText, size: size),
          )
        : _Initials(fallbackText: fallbackText, size: size);

    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        // `foreground`: il bordo viene disegnato sopra l'immagine, dentro i
        // limiti del quadrato, cosi' l'avatar misura esattamente [size] e il
        // file non viene spostato dal peso del bordo.
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: ArColors.border,
            width: size >= 64 ? 2 : 1,
          ),
          boxShadow: ArShadows.glow(
            ArColors.primary,
            strength: size >= 64 ? 0.28 : 0.18,
          ),
        ),
        child: ClipOval(child: avatar),
      ),
    );
  }
}

/// Iniziale su superficie del tema.
///
/// Il tema viene riletto dal `context` e non passato dalla classe sopra: la
/// versione precedente si portava dietro il [ThemeData] attraverso ogni
/// costruzione, e ogni chiamata che dimenticava di aggiornarlo mostrava
/// colori di una schermata diversa.
class _Initials extends StatelessWidget {
  const _Initials({required this.fallbackText, required this.size});

  final String fallbackText;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: ArColors.containerHigh,
      child: Center(
        child: Text(
          fallbackText,
          // La dimensione segue il diametro: con uno stile fisso, a 96px
          // l'iniziale restava a 28px e sembrava un timbro minuscolo dentro un
          // disco vuoto invece di un ritratto.
          style: TextStyle(
            fontFamily: AppTheme.displayFont,
            fontSize: size * 0.42,
            fontWeight: FontWeight.w700,
            fontVariations: const [FontVariation('wght', 700)],
            letterSpacing: -1,
            height: 1,
            color: ArColors.textHigh,
          ),
        ),
      ),
    );
  }
}
