import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ota_update/ota_update.dart';

export 'package:ota_update/ota_update.dart' show OtaEvent, OtaStatus;

/// Il download dell'APK dietro un'interfaccia.
///
/// Il controller non sa nulla del plugin: nei test un finto sostituisce il
/// download vero, che senza un dispositivo Android non produce eventi e tenga
/// il test appeso su una stream che non finisce.
abstract interface class ApkDownloader {
  /// Avvia il download. Ad ogni chiamata un download nuovo, mai riusato.
  ApkDownload start(
    String url, {
    String? destinationFilename,
    String? sha256checksum,
  });
}

/// Un download in corso, con gli eventi e la possibilita' di annullarlo.
abstract interface class ApkDownload {
  Stream<OtaEvent> get events;

  Future<void> cancel();
}

/// Download vero, che delega al plugin `ota_update`.
class OtaUpdateDownloader implements ApkDownloader {
  @override
  ApkDownload start(
    String url, {
    String? destinationFilename,
    String? sha256checksum,
  }) {
    // Il plugin tiene in memoria lo stream del download precedente e lo
    // riuserebbe: un'istanza nuova per ogni tentativo evita che un secondo
    // tentativo riceva gli eventi del file gia' scaricato.
    final update = OtaUpdate();
    return _OtaDownload(
      update.execute(
        url,
        destinationFilename: destinationFilename,
        sha256checksum: sha256checksum,
      ),
      update,
    );
  }
}

class _OtaDownload implements ApkDownload {
  _OtaDownload(this._events, this._update);

  final Stream<OtaEvent> _events;
  final OtaUpdate _update;

  @override
  Stream<OtaEvent> get events => _events;

  @override
  Future<void> cancel() async {
    try {
      await _update.cancel();
    } catch (_) {
      // Il plugin puo' essere assente (test) o gia' scollegato: annullare fallisce
      // senza fare danni.
    }
  }
}

final apkDownloaderProvider = Provider<ApkDownloader>((ref) => OtaUpdateDownloader());