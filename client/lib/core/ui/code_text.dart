import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Codice di gruppo o di invito.
///
/// Va letto ad alta voce, digitato a mano o incollato in una chat: e' il dato
/// che l'utente trasmette a qualcun altro, quindi deve restare leggibile
/// anche con una foto sfocata dello schermo.
///
/// Due scelte lo rendono tale. Il font e' il display del tema e non il
/// monospaziato di sistema, che su Android e' un file diverso da quello su iOS e
/// su Windows: lo stesso codice avrebbe forme diverse a seconda del
/// telefono. E la spaziatura fra i caratteri e' ampia, cosi' una sequenza lunga
/// si separa a occhio anche quando i caratteri si toccano.
class ArCodeText extends StatelessWidget {
  const ArCodeText(this.code, {this.large = false, super.key});

  final String code;

  /// Versione grande, per il codice del gruppo.
  ///
  /// Quella degli inviti singoli e' piu' piccola perche' nella stessa schermata
  /// i due codici compaiono insieme: della stessa dimensione sembrerebbero
  /// due dati di peso uguale, mentre uno e' l'accesso permanente del gruppo e
  /// l'altro un accesso singolo che scade.
  final bool large;

  /// Spaziatura fra i caratteri.
  ///
  /// Piu' di quella dei titoli, che e' negativa perche' i titoli devono
  /// stare compatti: qui il criterio e' l'opposto, e un codice stretto si
  /// legge male a colpo d'occhio.
  static const double tracking = 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = large
        ? theme.textTheme.headlineSmall
        : theme.textTheme.titleSmall;

    return Text(
      code,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: base?.copyWith(
        fontFamily: AppTheme.displayFont,
        fontVariations: const [FontVariation('wght', 700)],
        letterSpacing: tracking,
      ),
    );
  }
}