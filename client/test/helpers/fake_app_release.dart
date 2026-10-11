import 'package:animerank/features/update/data/app_release_repository.dart';
import 'package:animerank/features/update/domain/app_release.dart';

/// Repository finto dei rilasci.
///
/// Tiene in memoria il rilascio da restituire e conta le chiamate, come gli
/// altri finti del progetto: verificare che il controllo parta una volta sola
/// e non a ogni ricostruzione e' parte del contratto, non un dettaglio.
class FakeAppReleaseRepository implements AppReleaseRepository {
  FakeAppReleaseRepository({this.release, this.failWith});

  /// Cosa risponde `latest()`. `null` e' "non e' stato pubblicato niente",
  /// che e' una risposta valida e non un errore.
  final AppRelease? release;

  /// Se valorizzato, `latest()` fallisce con questa failure.
  final AppReleaseFailure? failWith;

  int calls = 0;

  @override
  Future<AppRelease?> latest() async {
    calls++;
    if (failWith != null) throw failWith!;
    return release;
  }
}

/// Rilascio finto, con valori che non cambiano tra un test e l'altro.
AppRelease releaseFixture({
  int versionCode = 2,
  String versionName = '1.0.1',
  String apkUrl = 'https://esempio.invalid/animerank.apk',
  String? sha256,
  String notes = '',
}) {
  return AppRelease(
    versionCode: versionCode,
    versionName: versionName,
    apkUrl: apkUrl,
    sha256: sha256,
    notes: notes,
  );
}