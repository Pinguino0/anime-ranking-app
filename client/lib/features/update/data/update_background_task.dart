import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'update_cleanup.dart';

/// Il nome del task e il nome univoco con cui WorkManager lo ricorda.
///
/// Stanno qui e non dentro una funzione perche' il task in background li
/// riceve come stringhe: se i due lati non usassero lo stesso valore la pulizia
/// non partirebbe mai e nessuno se ne accorgerebbe.
///
/// I nomi sono quelli di quando il task serviva anche a controllare le nuove
/// versioni: cambiarli lascerebbe in giro la vecchia schedulazione periodica,
/// che continuerebbe a girare a vuoto.
const String updateCheckTaskName = 'app_update_check';
const String updateCheckUniqueName = 'com.animerank.update_check';

/// Chiave in SharedPreferences con l'ultima pulizia degli APK (epoch in ms).
///
/// Il task in background gira ogni poche ore, ma gli APK vanno buttati una
/// volta a settimana: senza questo segno il tempo la pulizia partirebbe a ogni
/// risveglio, cioe' molte piu' volte del necessario.
const String _lastCleanupKey = 'update_last_cleanup_ms';

/// Ogni quanto si buttano gli APK lasciati dagli aggiornamenti.
const Duration _cleanupInterval = Duration(days: 7);

/// Ogni quanto il sistema puo' risvegliare la pulizia.
///
/// Android garantisce come minimo 15 minuti e puo' rimandare per risparmio
/// energetico: non e' un orologio, e' un "prima o poi". Sei ore bastano perche'
/// un APK lasciato da un aggiornamento sparisca nello stesso giorno senza
/// consumare batteria per una pulizia che quasi sempre non trova niente.
const Duration _checkInterval = Duration(hours: 6);

/// Programma la pulizia periodica degli APK lasciati dagli aggiornamenti.
///
/// L'avviso "c'e' da aggiornare" adesso lo manda il server con una notifica
/// push (trigger su `app_releases` in `20261011201000_app_update_push.sql`), che
/// arriva anche ad app chiusa. Qui resta solo la manutenzione: gli APK
/// scaricati e non piu' usati occupano decine di MB, e senza questa pulizia
/// restano sul telefono per sempre.
///
/// Non lancia mai: la pulizia e' di servizio, e se WorkManager non e'
/// disponibile l'app deve partire lo stesso.
Future<void> bootstrapUpdateMaintenance() async {
  // `kIsWeb` va controllato per primo: sul browser `Platform` non esiste e
  // leggerlo solleverebbe un'eccezione prima ancora di arrivare al confronto.
  if (kIsWeb || !Platform.isAndroid) {
    // Gli aggiornamenti e gli APK scaricati esistono solo su Android: su iOS li
    // consegna TestFlight/App Store, e sul web non ce ne sono affatto, quindi
    // non c'e' niente da programmare e non e' un errore.
    return;
  }

  try {
    await Workmanager().initialize(updateCheckCallbackDispatcher);
    await Workmanager().registerPeriodicTask(
      updateCheckUniqueName,
      updateCheckTaskName,
      frequency: _checkInterval,
      // `update` invece di `keep`: se il task cambia, WorkManager rinfresca la
      // registrazione senza azzerare il timer gia' in corso.
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  } catch (_) {
    // Nessuna pulizia in background: gli APK restano finche' non si apre
    // l'app. Non e' un motivo per non partire.
  }
}

/// Entry point del task in background.
///
/// Deve essere una funzione top-level con `@pragma('vm:entry-point')`:
/// WorkManager la invoca in un isolate nuovo, e senza quell'annotazione il
/// compilatore la eliminerebbe dalla build di release perche' nessuno la
/// "chiama" dal codice.
@pragma('vm:entry-point')
void updateCheckCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task != updateCheckTaskName) return true;
    try {
      await _maybeCleanupUpdateApks();
    } catch (_) {
      // La pulizia e' di servizio: se fallisce si riprova al prossimo giro.
    }
    return true;
  });
}

/// Butta gli APK degli aggiornamenti passati, ma non piu' di una volta a
/// settimana.
///
/// Gira dentro un risveglio del task in background: non vale la pena svegliare
/// il telefono una seconda volta solo per cancellare due file, e cosi' funziona
/// anche se l'app non viene mai aperta.
Future<void> _maybeCleanupUpdateApks() async {
  final prefs = await SharedPreferences.getInstance();
  final lastMs = prefs.getInt(_lastCleanupKey);
  final now = DateTime.now();
  final last = lastMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(lastMs);

  if (!isCleanupDue(now: now, lastCleanup: last, interval: _cleanupInterval)) {
    return;
  }

  await deleteLeftoverUpdateApks();
  await prefs.setInt(_lastCleanupKey, now.millisecondsSinceEpoch);
}
