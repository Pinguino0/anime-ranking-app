import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Permesso speciale di Android per installare APK da fuori.
///
/// Da Android 8 (O) in poi l'app che vuole lanciare l'installatore deve avere
/// il toggle "Consenti installazione di app sconosciute" acceso per conto suo:
/// chi ha installato l'APK dal browser ha dato il consenso al browser, non
/// all'app. Senza quel consenso Android ignora il lancio dell'installatore in
/// silenzio, e l'app resta a dire "si sta installando" per sempre.
abstract interface class InstallPermission {
  /// true se questa app puo' gia' aprire l'installatore.
  Future<bool> canInstallFromSource();

  /// Apre la pagina di sistema dove l'utente abilita il consenso.
  Future<void> openFromSettings();
}

/// Implementazione per Android.
///
/// Su qualunque altra piattaforma non c'e' nulla da concedere: i due metodi
/// rispondono come se il consenso ci fosse gia', cosi' il flusso di
/// aggiornamento non cambia per desktop o web.
class MethodChannelInstallPermission implements InstallPermission {
  static const MethodChannel _channel =
      MethodChannel('com.animerank.animerank/ota');

  @override
  Future<bool> canInstallFromSource() async {
    try {
      final value = await _channel.invokeMethod<bool>('canRequestPackageInstalls');
      return value ?? true;
    } on MissingPluginException {
      return true;
    } catch (_) {
      return true;
    }
  }

  @override
  Future<void> openFromSettings() async {
    try {
      await _channel.invokeMethod('openInstallSourcesSettings');
    } on MissingPluginException {
      // Niente impostazioni su desktop: non serve nulla.
    } catch (_) {
      // Aprire le impostazioni e' un gesto di comodo: se fallisce non e' un
      // errore che va mostrato, quello vero arriva al momento dell'installazione.
    }
  }
}

/// Provider di default: va sovrascritto in `main.dart` come gli altri, e i
/// test lo sostituiscono con un finto per non dipendere dalla piattaforma.
final installPermissionProvider = Provider<InstallPermission>((ref) {
  throw UnimplementedError(
    'installPermissionProvider va sovrascritto in main.dart: la versione '
    'installata dello 0.1.3 non ha il collegamento al permesso di installazione.',
  );
});