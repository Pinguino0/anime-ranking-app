import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../../features/update/data/update_cleanup.dart';

/// Butta via quello che l'app tiene su disco e puo' riscaricare.
///
/// L'app occupa principalmente due cose che non sono dati dell'utente:
///
///  - le locandine e i banner delle schede, scaricati da `cached_network_image`
///    e messi in una cache su disco senza un tetto visibile all'utente. E' la
///    voce grossa: ogni copertina e' centinaia di kilobyte e la home ne tocca
///    decine. Cancellarla costa una riscarica al prossimo avvio, niente di piu'.
///  - gli APK degli aggiornamenti passati, che `ota_update` lascia in
///    `files/ota_update` dopo averli installati (vedi [deleteLeftoverUpdateApks]).
///
/// NON tocca la sessione, le preferenze, la coda di sincronizzazione ne' il
/// punto di visione: quelli sono dati, non cache, e cancellarli farebbe
/// rientrare dall'account o perdere dove si era rimasti.
///
/// Non solleva: se una delle due parti non si puo' cancellare (una cache in uso,
/// un file bloccato) l'azione resta un'utile pulizia parziale invece di un
/// errore da mostrare.
Future<void> clearAppCaches() async {
  try {
    await DefaultCacheManager().emptyCache();
  } catch (_) {
    // Una cache aperta da un'immagine in caricamento non si cancella adesso: si
    // cancella al prossimo giro. Non e' un errore da mostrare all'utente.
  }

  await deleteLeftoverUpdateApks();
}
