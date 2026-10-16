// ============================================================================
// chromium_http_stub.dart — versione web del trasporto Chromium
// ============================================================================
//
// Questo file esiste solo perche' `dart:io` e `cronet_http` (che usa
// `dart:ffi`) non compilano su web. Il file reale e' `chromium_http.dart`,
// raggiungibile solo da piattaforme con `dart:io`.
//
// Su web il motore di Chromium non esiste comunque: il browser ha gia' il
// proprio stack di rete (HTTP/3 incluso), quindi [ChromiumHttp.supported] e'
// sempre false e nessuno chiama [ChromiumHttp.send].
// ============================================================================

import 'package:http/http.dart' as http;

/// Una risposta ottenuta dal motore di rete di Chromium.
///
/// Identica alla classe nel file reale: i due devono avere la stessa forma
/// perche' il codice che le usa non cambia a seconda della piattaforma.
class ChromiumResponse {
  const ChromiumResponse(this.statusCode, this.body, this.setCookie);

  final int statusCode;
  final String body;
  final String? setCookie;
}

/// Il motore di rete di Chromium (Cronet) — stub per web.
///
/// Su web il browser parla gia' HTTP/3 e non serve un motore separato:
/// [supported] e' sempre false e il codice che chiama questo modulo passa
/// direttamente al trasporto successivo (`dart:io` o `package:http`).
class ChromiumHttp {
  ChromiumHttp._();

  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// Su web non c'e' Cronet: il browser e' gia' il motore.
  static bool get supported => false;

  /// Sempre false: non c'e' nulla da rifiutare.
  static bool get unavailable => false;

  /// Sempre null: nessun client dedicato su web.
  static http.Client? get client => null;

  /// Solleva sempre: nessuno dovrebbe arrivarci con `supported == false`.
  static Future<ChromiumResponse> send(
    String method,
    Uri uri,
    Map<String, String> headers,
  ) async {
    throw UnsupportedError(
      'Il motore di Chromium non esiste su web: usa il trasporto HTTP standard.',
    );
  }
}
