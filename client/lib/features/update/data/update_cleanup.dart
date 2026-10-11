import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Nome della cartella dove `ota_update` salva gli APK scaricati.
///
/// Non e' configurabile: il plugin la ricava lui stesso dallo storage interno
/// dell'app (`files/ota_update`, cioe' `getApplicationSupportDirectory()` piu'
/// questo nome). Se un giorno il plugin cambiasse cartella, questa costante
/// andrebbe aggiornata insieme a lui.
const String otaUpdateFolderName = 'ota_update';

/// Cancella gli APK di aggiornamento rimasti sul telefono.
///
/// Ogni aggiornamento scarica un APK da decine di MB in `files/ota_update` e lo
/// passa all'installatore, ma nessuno lo cancella dopo: il file resta li' anche
/// dopo l'aggiornamento, perche' Android sostituisce la app ma tiene i suoi
/// dati. Dopo qualche versione sono centinaia di MB occupati per niente.
///
/// Si chiama all'avvio: in quel momento non c'e' nessun download in corso (parte
/// solo quando l'utente preme Aggiorna) e ogni file presente e' un residuo che
/// ha gia' fatto il suo lavoro. Non lancia mai: se il disco o il permesso non
/// collaborano l'app deve partire lo stesso.
///
/// [directory] esiste solo per i test: in produzione si usa la cartella vera
/// dell'app. Restituisce quanti file ha cancellato, cosi' un test lo puo'
/// verificare senza guardare il filesystem.
Future<int> deleteLeftoverUpdateApks({Directory? directory}) async {
  try {
    final dir = directory ?? await _defaultDirectory();
    if (!await dir.exists()) return 0;

    var count = 0;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      // Solo gli APK: nella stessa cartella il plugin non mette altro, ma un
      // file di altro tipo (un log, un residuo di un'altra versione del plugin)
      // non va cancellato alla cieca.
      if (!entity.path.toLowerCase().endsWith('.apk')) continue;
      try {
        await entity.delete();
        count++;
      } catch (_) {
        // File ancora in uso dall'installatore: si riprovera' al prossimo avvio.
      }
    }
    return count;
  } catch (_) {
    return 0;
  }
}

/// La cartella degli APK nel percorso dell'app.
Future<Directory> _defaultDirectory() async {
  final base = await getApplicationSupportDirectory();
  return Directory('${base.path}${Platform.pathSeparator}$otaUpdateFolderName');
}

/// true se e' ora di rifare la pulizia.
///
/// Estratta da sola perche' e' l'unica parte con una decisione dentro: il resto
/// e' filesystem. Con [lastCleanup] a `null` e' la prima volta, e si pulisce
/// subito; altrimenti si aspetta che sia passato [interval].
bool isCleanupDue({
  required DateTime now,
  DateTime? lastCleanup,
  Duration interval = const Duration(days: 7),
}) {
  if (lastCleanup == null) return true;
  return now.difference(lastCleanup) >= interval;
}
