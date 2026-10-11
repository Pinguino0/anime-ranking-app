/// Un rilascio pubblicato dell'app.
///
/// L'unico dato che decide qualcosa e' [versionCode]: tutto il resto serve a
/// mostrarlo all'utente o a far scaricare il file giusto.
class AppRelease {
  const AppRelease({
    required this.versionCode,
    required this.versionName,
    required this.apkUrl,
    this.sha256,
    this.sizeBytes,
    this.notes = '',
  });

  /// Numero con cui Android distingue le build: intero, e confrontabile.
  ///
  /// Il confronto e' questo e non [versionName] perche' "1.0.10" come testo
  /// viene prima di "1.0.9", quindi un confronto lessicale propose
  /// l'aggiornamento al contrario e l'app non si aggiornerebbe mai. Il
  /// version_code e' gia' il numero che Android usa per capire quale APK e'
  /// piu' recente, quindi non si inventa niente.
  final int versionCode;

  /// Etichetta mostrata all'utente ("1.0.2"). Non partecieta a nessun confronto.
  final String versionName;

  /// Dove si scarica l'APK.
  final String apkUrl;

  /// Hash SHA-256 in esadecimale dell'APK, se il rilascio lo dichiara.
  ///
  /// Facoltativo perche' una versione si puo' pubblicare senza averlo
  /// calcolato, ma quando c'e' il file scaricato viene verificato prima
  /// dell'installazione: un download troncato non viene mai installato.
  final String? sha256;

  final int? sizeBytes;

  /// Note del rilascio, mostrate nella schermata di aggiornamento.
  final String notes;

  /// true se questo rilascio e' piu' recente della versione installata.
  bool isNewerThan(int installedVersionCode) =>
      versionCode > installedVersionCode;

  /// Legge una riga di `public.app_releases`.
  ///
  /// Restituisce `null` invece di lanciare quando la riga e' incompleta: una
  /// riga rotta in tabella non deve impedire all'app di partire, deve solo far
  /// saltare quel controllo. Il rischio di accettare una riga senza
  /// `version_code` o senza `apk_url` e' pero' reale, quindi quei due campi
  /// sono trattati come obbligatori e tutto il resto no.
  static AppRelease? parse(Map<String, dynamic> row) {
    final code = _asInt(row['version_code']);
    final name = _asString(row['version_name']);
    final url = _asString(row['apk_url']);
    if (code == null || code <= 0 || name == null || name.isEmpty) return null;
    if (url == null || url.isEmpty) return null;

    return AppRelease(
      versionCode: code,
      versionName: name,
      apkUrl: url,
      sha256: _asString(row['sha256']),
      sizeBytes: _asInt(row['size_bytes']),
      notes: _asString(row['notes']) ?? '',
    );
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static String? _asString(Object? value) {
    final s = value?.toString();
    return (s == null || s.isEmpty) ? null : s;
  }
}