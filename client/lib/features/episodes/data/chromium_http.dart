import 'dart:io';

import 'package:cronet_http/cronet_http.dart';
import 'package:http/http.dart' as http;

/// Una risposta ottenuta dal motore di rete di Chromium.
class ChromiumResponse {
  const ChromiumResponse(this.statusCode, this.body, this.setCookie);

  final int statusCode;
  final String body;

  /// Il valore dell'header `set-cookie`. Quando i cookie sono piu' d'uno il
  /// motore li mette in una riga sola, separati da virgola: per leggerne i
  /// singoli valori basta cercarli per nome.
  final String? setCookie;
}

/// Il motore di rete di Chromium (Cronet) usato come trasporto HTTP.
///
/// Perche' non basta `dart:io`
/// ---------------------------
/// Su alcune reti mobili italiane un filtro legge il nome del sito scritto in
/// chiaro nell'handshake TLS e, se lo riconosce, risponde al posto suo con una
/// pagina di blocco. Da li' `dart:io` non passa in nessun modo: a essere letto
/// e' il nome, non l'indirizzo, quindi cambiare DNS o IP non serve.
///
/// Un browser invece passa, e non per magia: Chromium non offre quel nome su
/// una connessione osservabile, perche' parla HTTP/3 (QUIC). Cronet e' quello
/// stesso motore dentro l'app, quindi si comporta come una finestra di
/// navigazione: stessa risoluzione dei nomi, stesso trasporto, stessa gestione
/// dei cookie.
class ChromiumHttp {
  ChromiumHttp._();

  /// L'agente utente del motore: quello di un browser desktop, perche' i due
  /// provider stanno dietro Cloudflare e si aspettano un browser.
  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// Gli host che il filtro intercetta quando parlano TLS su TCP.
  ///
  /// Servono a una cosa sola: senza dirglielo, Cronet non sa che il sito offre
  /// HTTP/3 e prova prima TCP, finendo dritto nel filtro. Con il suggerimento
  /// va subito su QUIC.
  static const List<(String, int, int)> _quicHosts = [
    ('www.animeunity.so', 443, 443),
    ('animeunity.so', 443, 443),
    ('www.animesaturn.cx', 443, 443),
    ('animesaturn.cx', 443, 443),
    ('www.animesaturn.net', 443, 443),
    ('animesaturn.net', 443, 443),
    ('www.animesaturn.cc', 443, 443),
    ('www.animesaturn.com', 443, 443),
  ];

  static http.Client? _client;
  static bool _unavailable = false;

  /// Se la piattaforma ha un motore di Chromium utilizzabile.
  ///
  /// Cronet esiste solo su Android: altrove le fonti si risolvono con
  /// `dart:io`, che sulle reti normali va benissimo.
  static bool get supported => Platform.isAndroid;

  /// Se il motore si e' gia' rifiutato di partire.
  ///
  /// Una volta fallita la costruzione non ha senso ritentarla a ogni richiesta:
  /// si resta su `dart:io` per tutta la vita del processo.
  static bool get unavailable => _unavailable;

  /// Il motore condiviso, costruito alla prima richiesta.
  ///
  /// `null` quando non c'e' (piattaforma senza Cronet, o costruzione fallita).
  static http.Client? get client {
    if (_unavailable || !supported) return null;

    final existing = _client;
    if (existing != null) return existing;

    try {
      final engine = CronetEngine.build(
        cacheMode: CacheMode.memory,
        // La cache in memoria vuole comunque una dimensione: un megabyte copre
        // le poche pagine di questa estrazione.
        cacheMaxSize: 1024 * 1024,
        userAgent: userAgent,
        enableBrotli: true,
        enableQuic: true,
        useBuiltInDnsResolver: true,
        quicHints: _quicHosts,
      );
      return _client = CronetClient.fromCronetEngine(engine, closeEngine: true);
    } catch (_) {
      _unavailable = true;
      return null;
    }
  }

  /// Fa una richiesta e restituisce il corpo come testo.
  ///
  /// Solleva se il motore non c'e': chi chiama ha altri trasporti da provare e
  /// deve poter passare al successivo.
  static Future<ChromiumResponse> send(
    String method,
    Uri uri,
    Map<String, String> headers,
  ) async {
    final httpClient = client;
    if (httpClient == null) {
      throw const SocketException('Motore di Chromium non disponibile.');
    }

    final request = http.Request(method, uri);
    headers.forEach((key, value) {
      // L'agente utente lo mette il motore: ripeterlo qui lo duplicherebbe.
      if (key.toLowerCase() == 'user-agent') return;
      request.headers[key] = value;
    });

    final response = await httpClient
        .send(request)
        .timeout(const Duration(seconds: 20));
    final body = await response.stream.bytesToString();

    return ChromiumResponse(
      response.statusCode,
      body,
      response.headers['set-cookie'],
    );
  }
}
