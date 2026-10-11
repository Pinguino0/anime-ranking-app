import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_update_controller.dart';
import 'update_dialog.dart';

/// Mette l'app sotto una coperta quando c'e' da aggiornare.
///
/// Va montato dentro `MaterialApp.router(builder: ...)`, e va detto perche'
/// non e' una rotta del router.
///
/// Il `builder` di MaterialApp sta SOPRA il Navigator, non sotto: e' il posto
/// dove si mettono wrapper come un `MediaQuery` o una `Directionality`, e il
/// Navigator e' dentro il `child` che il builder riceve. Quindi da qui
/// `showDialog` non funziona — chiede un Navigator e non lo trova. Provarlo e'
/// stato un modo di perdere un pomeriggio.
///
/// La coperta e' uno `Stack` invece di un dialogo per due motivi che vengono
/// fuori insieme:
///
///   - non dipende dal Navigator, quindi funziona anche qui dentro;
///   - non e' una rotta, quindi non si chiude con il gesture "indietro".
///     Un dialogo aperto con showDialog si chiude indietro, e l'utente
///     resterebbe dentro un'app vecchia con l'avviso sparito.
///
/// Il `ModalBarrier` serve a mangiare i tocchi: senza, l'app si puo' usare
/// dietro all'avviso, che e' il peggio di entrambe le situazioni.
class UpdateGate extends ConsumerWidget {
  const UpdateGate({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appUpdateProvider);

    // Fuori dal percorso bloccante non c'e' niente da fare: si restituisce il
    // figlio com'e'. Avvolgerlo comunque in uno Stack metterebbe uno strato in
    // piu' davanti a ogni schermata dell'app, per tutta la vita dell'app, per
    // non mostrare niente.
    if (!state.isBlocking) return child;

    return Stack(
      children: [
        child,
        const ModalBarrier(
          dismissible: false,
          // Trasparente perche' l'avviso deve mostrare l'app dietro: si vede
          // che cosa si sta aggiornando e il dialogo non sembra un'app
          // separata.
          color: Colors.transparent,
        ),
        // `SafeArea` perche' il dialogo su un telefono con barra di stato
        // ritratta finisce sotto il notch.
        SafeArea(
          child: Center(
            child: UpdateDialog(
              state: state,
              onInstall: ref.read(appUpdateProvider.notifier).install,
            ),
          ),
        ),
      ],
    );
  }
}