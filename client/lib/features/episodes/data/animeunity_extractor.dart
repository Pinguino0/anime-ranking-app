import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../core/env/app_config.dart';
import '../domain/episode.dart';
import 'chromium_http.dart';
import 'doh_bypass.dart';

/// Una risoluzione lato client non riuscita.
///
/// Esiste separata da [SourceResolutionFailure] perche' quel tipo vive nel
/// repository, e il repository importa questo file: usarlo qui creerebbe un
/// import circolare. Il repository la traduce in una `SourceResolutionFailure`
/// poco dopo, quindi all'utente arriva comunque un messaggio dicibile.
class ClientExtractionFailure implements Exception {
  const ClientExtractionFailure(this.message, {this.isRetryable = true});

  final String message;
  final bool isRetryable;

  @override
  String toString() => message;
}

/// Chi sa trasformare un indirizzo canonico in un URL riproducibile.
///
/// E' un'interfaccia e non una funzione perche' il repository la riceve in
/// ingresso: i test possono iniettare un finto senza toccare la rete.
abstract interface class ClientSourceExtractor {
  Future<ResolvedSource> extract({
    required String sourceId,
    required String canonicalUrl,
    required int episodeNumber,
    String? quality,
    String? providerSlug,
  });
}

/// Chi sa dire quanti episodi ha un'opera, adesso, secondo il provider.
///
/// Tenuta separata da [ClientSourceExtractor] perche' sono due domande diverse:
/// "quanti episodi ci sono" si fa aprendo la scheda, "dammi il video" si fa
/// premendo play. Un finto nei test puo' rispondere a una e non all'altra.
abstract interface class ClientEpisodeCounts {
  /// Il totale di episodi secondo il provider, `null` se non lo dice.
  Future<int?> fetchEpisodeCount(String canonicalUrl);
}

/// Estrae un episodio di AnimeUnity direttamente dal telefono.
///
/// AnimeUnity sta dietro Cloudflare e risponde 403 a un indirizzo di datacenter:
/// la Edge Function, che gira su un server, non puo' risolverla. Il telefono ha
/// lo stesso IP residenziale dell'utente, quindi per Cloudflare e' un utente
/// normale, e l'estrazione funziona.
///
/// La sequenza e' quella di un'app Laravel:
///
///   1. `GET /` per i cookie di sessione e il token `XSRF-TOKEN`;
///   2. `GET /info_api/{animeId}/{episodio}` con il token per l'id dell'episodio;
///   3. `GET /embed-url/{id}` per l'indirizzo del player (vixcloud);
///   4. `GET <player>` e lettura di `window.masterPlaylist`;
///   5. `GET <playlist>` per scegliere la rendition richiesta.
///
/// Le richieste possono viaggiare su piu' strade, provate in ordine: il motore
/// di rete di Chromium, `dart:io`, `dart:io` con la risoluzione via
/// DNS-over-HTTPS, il Worker. La prima serve sulle reti mobili che filtrano il
/// nome del sito, le ultime coprono i casi di DNS falsato e di indirizzo
/// bloccato. Sulla rete di casa il primo tentativo che riesce e' `dart:io`, e
/// tutto il resto non viene nemmeno toccato.
class AnimeUnityExtractor implements ClientSourceExtractor, ClientEpisodeCounts {
  AnimeUnityExtractor();

  static const String _base = 'https://www.animeunity.so';

  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// Per quanto vale una sessione. AnimeUnity la lascia vivere dieci minuti, ma
  /// ricomprare i cookie a ogni episodio e' una richiesta in piu' per niente:
  /// tre ore coprono una sessione di visione e la sessione viene comunque
  /// rifiutata con un 419 e rifatta prima se scade.
  static const Duration _sessionTtl = Duration(hours: 3);

  static final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  /// Il trasporto diretto: `dart:io`, senza sorprese.
  static final _Transport _io = _IoTransport(() => _http);

  /// Il trasporto che passa dal motore di rete di Chromium (Cronet).
  static _Transport? _chromiumTransport;

  /// `null` quando la piattaforma non ha Cronet (tutto tranne Android) o quando
  /// il motore si e' rifiutato di partire: in quel caso restano `dart:io`, il
  /// DNS-over-HTTPS e il Worker.
  static _Transport? get _chromium {
    if (!ChromiumHttp.supported || ChromiumHttp.unavailable) return null;
    return _chromiumTransport ??= const _ChromiumTransport();
  }

  /// Il client che risolve gli indirizzi via DNS-over-HTTPS.
  ///
  /// Viene costruito solo se serve, cioe' quando un'estrazione normale
  /// fallisce: sulla maggioranza delle reti non tocca mai la rete.
  static HttpClient? _bypassHttpClient;

  /// Indirizzi Cloudflare noti che servono il sito. Si tentano per ultimi,
  /// quando il DoH non risponde: sono gli stessi a cui puntano i domini
  /// alternativi (`.to`, `.it`), che sono lo stesso operatore.
  static const List<String> _cloudflareFallbacks = [
    '188.114.96.7',
    '188.114.97.7',
    '104.21.83.16',
    '172.67.166.248',
  ];

  /// Le sessioni comprate, una per trasporto.
  ///
  /// Tenute separate perche' il token CSRF e' legato ai cookie di *quella*
  /// sessione: mescolarli (cookie di un trasporto e token di un altro) farebbe
  /// rispondere 419. Il Worker ha la sua, il motore di Chromium la sua.
  static final Map<String, _Session> _sessions = {};
  static final Map<String, DateTime> _sessionExpiry = {};

  /// La chiave della sessione di un tentativo.
  ///
  /// Il Worker non e' un trasporto a se': e' `dart:io` che passa da un altro
  /// indirizzo, quindi la sua sessione va tenuta a parte.
  static String _sessionKey(_Transport transport, Uri? relay) =>
      relay != null ? 'relay' : transport.sessionKey;

  static void _forgetSession(_Transport transport, Uri? relay) {
    final key = _sessionKey(transport, relay);
    _sessions.remove(key);
    _sessionExpiry.remove(key);
  }

  /// Il Worker configurato in fase di build, se c'e'.
  static Uri? get _relay {
    final raw = AppConfig.animeUnityRelay.trim();
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    return uri;
  }


  @override
  Future<ResolvedSource> extract({
    required String sourceId,
    required String canonicalUrl,
    required int episodeNumber,
    String? quality,
    String? providerSlug,
  }) async {
    // Quattro trasporti, dal piu' affidabile al piu' di riserva:
    //   1. il motore di rete di Chromium, quando c'e' (Android): e' lo stesso
    //      stack del browser e l'unico che supera un filtro che legge il nome
    //      del sito nell'handshake TLS;
    //   2. rete diretta con `dart:io`, che sulle reti normali va benissimo ed e'
    //      il piu' economico;
    //   3. rete diretta con DNS-over-HTTPS e indirizzo vero, IPv6 per primo
    //      (aggira il DNS falsato, non un filtro TLS);
    //   4. Worker Cloudflare (aggira un blocco di indirizzo). Si tenta solo se
    //      configurato in fase di build.
    // Un fallimento "non ritentabile" (episodio inesistente, indirizzo non
    // riconosciuto) ferma subito: cambiare strada non lo risolverebbe.
    final chromium = _chromium;
    final attempts = <({_Transport transport, Uri? relay})>[
      if (chromium != null) (transport: chromium, relay: null),
      (transport: _io, relay: null),
      (transport: _bypass, relay: null),
      if (_relay != null) (transport: _io, relay: _relay),
    ];

    ClientExtractionFailure? failure;
    for (final attempt in attempts) {
      try {
        return await _extract(
          transport: attempt.transport,
          relay: attempt.relay,
          sourceId: sourceId,
          canonicalUrl: canonicalUrl,
          episodeNumber: episodeNumber,
          quality: quality,
          providerSlug: providerSlug,
        );
      } on ClientExtractionFailure catch (e) {
        failure = e;

        // La sessione di quel trasporto puo' essere ormai rifiutata: si butta,
        // cosi' il tentativo successivo (o quello dopo, dal player) ne compra
        // una nuova invece di ripetere lo stesso errore. Su un errore non
        // ritentabile ci si ferma: la sessione non c'entra con un episodio
        // inesistente.
        _forgetSession(attempt.transport, attempt.relay);
        if (!e.isRetryable) rethrow;
      } catch (_) {
        // Un errore che non e' un [ClientExtractionFailure] (bug di un
        // trasporto, eccezione di piattaforma inattesa) non deve fermare il
        // giro: e' proprio quando la rete blocca la fonte che capita l'imprevisto,
        // e il trasporto successivo puo' comunque farcela. Si registra e si
        // continua invece di far fallire tutto al primo tentativo.
        failure = const ClientExtractionFailure(
            'Connessione ad AnimeUnity non riuscita. Riprova.');
        _forgetSession(attempt.transport, attempt.relay);
      }
    }

    throw failure ??
        const ClientExtractionFailure('AnimeUnity non raggiungibile.');
  }

  /// Quanti episodi ha AnimeUnity adesso.
  ///
  /// Una GET sola su `/info_api/{animeId}/1`: il totale viaggia con la prima
  /// puntata, quindi non serve scaricare l'elenco intero. Riusa la stessa
  /// sessione (cookie + token CSRF) gia' comprata per l'estrazione.
  ///
  /// Non solleva per un guasto di rete: senza conteggio la lista resta quella
  /// che era, e chi chiama non deve gestire un fallimento che non cambia nulla.
  @override
  Future<int?> fetchEpisodeCount(String canonicalUrl) async {
    final animeId = _parseAnimeId(canonicalUrl);
    if (animeId == null) return null;

    final uri = Uri.parse('$_base/info_api/$animeId/1').replace(
      queryParameters: {'start_range': '1', 'end_range': '1'},
    );

    // Best-effort: si prova il motore di Chromium, poi la rete diretta e, se
    // configurato, il Worker. Un conteggio mancante non cambia cio' che l'utente
    // vede, quindi qui non solleva mai.
    final chromium = _chromium;
    final attempts = <({_Transport transport, Uri? relay})>[
      if (chromium != null) (transport: chromium, relay: null),
      (transport: _io, relay: null),
      if (_relay != null) (transport: _io, relay: _relay),
    ];

    for (final attempt in attempts) {
      try {
        final transport = attempt.transport;
        final session = await _getSession(transport, relay: attempt.relay);
        final info = await _apiJson(
          transport,
          uri,
          _apiHeaders(session, withCookies: !transport.managesCookies),
          relay: attempt.relay,
        );
        final raw = info['episodes_count'];
        if (raw is num) return raw.toInt();
        if (raw is String) return int.tryParse(raw);
        return null;
      } catch (_) {
        // Trasporto non disponibile: si prova il successivo.
        _forgetSession(attempt.transport, attempt.relay);
      }
    }
    return null;
  }

  Future<ResolvedSource> _extract({
    required _Transport transport,
    Uri? relay,
    required String sourceId,
    required String canonicalUrl,
    required int episodeNumber,
    String? quality,
    String? providerSlug,
  }) async {
    final animeId = _parseAnimeId(canonicalUrl);
    if (animeId == null) {
      throw ClientExtractionFailure(
        'Indirizzo AnimeUnity non riconosciuto.',
        isRetryable: false,
      );
    }
    if (episodeNumber < 1) {
      throw const ClientExtractionFailure(
          'Numero episodio mancante per questa fonte.');
    }

    final wanted = _requestedQuality(quality);

    final session = await _getSession(transport, relay: relay);

    final infoUri = Uri.parse('$_base/info_api/$animeId/$episodeNumber').replace(
      queryParameters: {
        'start_range': '$episodeNumber',
        'end_range': '$episodeNumber',
      },
    );

    final info = await _apiJson(
      transport,
      infoUri,
      _apiHeaders(session, withCookies: !transport.managesCookies),
      relay: relay,
    );
    final episodes = info['episodes'];
    final list = episodes is List ? episodes : const [];

    Map<String, dynamic>? chosen;
    for (final entry in list) {
      if (entry is Map &&
          '${entry['number']}' == '$episodeNumber' &&
          entry['id'] != null) {
        chosen = Map<String, dynamic>.from(entry);
        break;
      }
    }
    chosen ??= list.isNotEmpty && list.first is Map
        ? Map<String, dynamic>.from(list.first as Map)
        : null;

    if (chosen == null || chosen['id'] == null) {
      throw ClientExtractionFailure(
        'Episodio $episodeNumber non disponibile su AnimeUnity.',
        isRetryable: false,
      );
    }

    final episodeId = '${chosen['id']}';
    final animePage = '$_base/anime/$episodeId-x';

    final embedResponse = await _send(
      transport,
      'GET',
      Uri.parse('$_base/embed-url/$episodeId'),
      headers: {
        ..._apiHeaders(session, withCookies: !transport.managesCookies),
        'accept': 'text/plain',
        'referer': animePage,
      },
      relay: relay,
    );
    if (embedResponse.status != 200) {
      throw ClientExtractionFailure(
          'AnimeUnity ha risposto HTTP ${embedResponse.status}.');
    }

    final embedUrl = embedResponse.body.trim();
    if (!embedUrl.startsWith('https://')) {
      throw const ClientExtractionFailure(
          'Il player AnimeUnity non ha restituito un indirizzo.');
    }

    final page = await _send(
      transport,
      'GET',
      Uri.parse(embedUrl),
      headers: {
        'user-agent': _userAgent,
        'accept': 'text/html',
        'referer': '$_base/',
      },
    );
    if (page.status != 200) {
      throw ClientExtractionFailure(
          'Il player AnimeUnity ha risposto HTTP ${page.status}.');
    }

    final config = _parseMasterPlaylist(page.body);
    final playlistUrl = _buildPlaylistUrl(config);
    final (hlsUrl, expiresAt) =
        await _pickRendition(transport, playlistUrl, wanted);

    return ResolvedSource(
      sourceId: sourceId,
      resolvedUrl: hlsUrl,
      headers: const {
        'Referer': 'https://vixcloud.co/',
        'Origin': 'https://vixcloud.co',
      },
      sourceType: EpisodeSourceType.hls,
      canonicalUrl: canonicalUrl,
      providerSlug: providerSlug,
      expiresAt: expiresAt,
    );
  }

  // -------------------------------------------------------------------------
  // Sessione e chiamate
  // -------------------------------------------------------------------------

  Future<_Session> _getSession(_Transport transport, {Uri? relay}) async {
    final key = _sessionKey(transport, relay);
    final cached = _sessions[key];
    final expiresAt = _sessionExpiry[key];
    if (cached != null && expiresAt != null && DateTime.now().isBefore(expiresAt)) {
      return cached;
    }

    final response = await _send(
      transport,
      'GET',
      Uri.parse('$_base/'),
      headers: {'user-agent': _userAgent, 'accept': 'text/html'},
      relay: relay,
    );
    if (response.status != 200) {
      throw ClientExtractionFailure(
          'AnimeUnity ha risposto HTTP ${response.status}.');
    }

    final token = _xsrfToken(response.setCookies);

    // Il motore di Chromium tiene i cookie da solo (li rimanda lui, come farebbe
    // una finestra di navigazione) e le richieste di lettura non hanno bisogno
    // del token CSRF: se manca si prosegue lo stesso, invece di fermare
    // un'estrazione che il server sta gia' servendo.
    if (transport.managesCookies) {
      final session = _Session('', token ?? '');
      _sessions[key] = session;
      _sessionExpiry[key] = DateTime.now().add(_sessionTtl);
      return session;
    }

    if (token == null || token.isEmpty) {
      throw const ClientExtractionFailure(
          'AnimeUnity non ha rilasciato il token CSRF.');
    }

    final cookies = response.setCookies
        .map((c) => c.split(';').first.trim())
        .where((c) => c.isNotEmpty)
        .toList();

    final session = _Session(cookies.join('; '), token);
    _sessions[key] = session;
    _sessionExpiry[key] = DateTime.now().add(_sessionTtl);
    return session;
  }

  /// Il valore del cookie `XSRF-TOKEN`, se le risposte ne portano uno.
  ///
  /// I cookie possono arrivare tutti su una riga sola (il motore di Chromium li
  /// unisce): cercare per nome trova il token in entrambe le forme.
  static String? _xsrfToken(List<String> setCookies) {
    for (final raw in setCookies) {
      final match = RegExp('XSRF-TOKEN=([^;,]+)').firstMatch(raw);
      if (match != null) return Uri.decodeComponent(match.group(1)!);
    }
    return null;
  }

  Map<String, String> _apiHeaders(_Session session, {bool withCookies = true}) =>
      {
        'user-agent': _userAgent,
        'accept': 'application/json',
        'x-requested-with': 'XMLHttpRequest',
        if (session.token.isNotEmpty) 'x-xsrf-token': session.token,
        if (withCookies && session.cookie.isNotEmpty) 'cookie': session.cookie,
      };

  Future<Map<String, dynamic>> _apiJson(
    _Transport transport,
    Uri uri,
    Map<String, String> headers, {
    bool retried = false,
    Uri? relay,
  }) async {
    final response =
        await _send(transport, 'GET', uri, headers: headers, relay: relay);

    // 419: la sessione non vale piu'. Se ne compra una nuova e si rifa' la
    // richiesta una volta sola — insistere all'infinito su una sessione che il
    // server continua a rifiutare nasconderebbe un problema vero.
    if (response.status == 419 && !retried) {
      _forgetSession(transport, relay);
      final fresh = await _getSession(transport, relay: relay);
      return _apiJson(transport, uri,
          _apiHeaders(fresh, withCookies: !transport.managesCookies),
          retried: true, relay: relay);
    }

    if (response.status != 200) {
      throw ClientExtractionFailure(
          'AnimeUnity ha risposto HTTP ${response.status}.');
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on FormatException {
      // sotto
    }
    throw const ClientExtractionFailure(
        'AnimeUnity ha risposto con dati non leggibili.');
  }

  /// L'indirizzo del Worker per una richiesta ad AnimeUnity.
  ///
  /// Il Worker espone `?u=<indirizzo completo>`: la query del bersaglio viaggia
  /// dentro `u`, quindi l'URL finale resta valido anche quando l'originale ne
  /// aveva una (es. `info_api/...?start_range=1`).
  static Uri _withRelay(Uri relay, Uri target) => relay.replace(
        queryParameters: {
          ...relay.queryParameters,
          'u': target.toString(),
        },
      );

  Future<_HttpResult> _send(
    _Transport transport,
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Uri? relay,
  }) async {
    // Solo le richieste ad AnimeUnity passano dal Worker: il player (vixcloud,
    // vix-content) non e' bloccato e va lasciato sulla rete diretta, che e'
    // piu' veloce.
    final viaRelay = relay != null && uri.host.contains('animeunity');
    final target = viaRelay ? _withRelay(relay, uri) : uri;

    try {
      final result = await transport.send(method, target, headers);

      // Dietro il Worker i `Set-Cookie` non possono viaggiare come header
      // normali (il browser/app li leggerebbe di un altro dominio): il Worker li
      // rimette nel header `x-set-cookie` come lista JSON.
      if (viaRelay) {
        final rawCookies = result.headers['x-set-cookie'];
        if (rawCookies != null && rawCookies.isNotEmpty) {
          try {
            final decoded = jsonDecode(rawCookies);
            if (decoded is List) {
              for (final entry in decoded) {
                if (entry is String) result.setCookies.add(entry);
              }
            }
          } on FormatException {
            // Header illeggibile: senza cookie si compra una sessione nuova al
            // giro dopo, quindi non vale far fallire questa richiesta.
          }
        }
      }

      return result;
    } on TimeoutException {
      throw const ClientExtractionFailure('AnimeUnity non risponde. Riprova.');
    } on HandshakeException {
      // Tipico di una rete che intercetta la fonte: la connessione arriva a un
      // server che non ha il certificato giusto. Ritentabile, perche' il motore
      // di Chromium — o il DNS-over-HTTPS, o il Worker — puo' aggirarla.
      throw const ClientExtractionFailure(
          'Connessione sicura ad AnimeUnity non riuscita. Riprova.');
    } on SocketException {
      throw const ClientExtractionFailure(
          'Connessione ad AnimeUnity non riuscita. Controlla la rete.');
    } on IOException {
      // `HttpException`, `TlsException` e le altre varianti di `IOException`
      // arrivano quando una rete che blocca la fonte chiude la connessione a
      // meta'. Senza questo ramo l'eccezione grezza sfuggirebbe al giro dei
      // trasporti, che quindi non proverebbe mai il motore di Chromium ne' il
      // Worker: ed e' il caso che conta sui dati mobili.
      throw const ClientExtractionFailure(
          'Connessione ad AnimeUnity non riuscita. Controlla la rete.');
    } catch (_) {
      // Rete o risposta fuori standard. Comunque ritentabile: un altro
      // trasporto puo' riuscire.
      throw const ClientExtractionFailure(
          'Connessione ad AnimeUnity non riuscita. Riprova.');
    }
  }

  // -------------------------------------------------------------------------
  // Aggiramento dei blocchi di rete
  // -------------------------------------------------------------------------

  /// Il client che scavalca i blocchi DNS/IP del gestore.
  ///
  /// La logica vive in [DohBypassHttpClient], condivisa con la fonte di
  /// riserva. Qui si aggiungono solo gli indirizzi Cloudflare noti di
  /// AnimeUnity, da tentare quando nemmeno il DoH risponde.
  static HttpClient get _bypassHttp => _bypassHttpClient ??=
      DohBypassHttpClient.build(
        fallbackIps: (host) =>
            host.contains('animeunity') ? _cloudflareFallbacks : const [],
      );

  /// Lo stesso trasporto, con la risoluzione dei nomi fatta via DoH.
  static final _Transport _bypass = _IoTransport(() => _bypassHttp);

  // -------------------------------------------------------------------------
  // Parsing
  // -------------------------------------------------------------------------

  int? _parseAnimeId(String canonicalUrl) {
    final match = RegExp(r'/anime/(\d+)').firstMatch(Uri.parse(canonicalUrl).path);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// `window.masterPlaylist` non e' JSON valido: chiavi non quotate, virgole
  /// finali e apici singoli. Si normalizza e si legge l'oggetto con il
  /// conteggio delle graffe, perche' un taglio ingenuo alla prima `}` si
  /// fermerebbe al primo oggetto annidato.
  Map<String, dynamic> _parseMasterPlaylist(String html) {
    final start = html.indexOf('window.masterPlaylist');
    final open = start < 0 ? -1 : html.indexOf('{', start);
    if (open < 0) {
      throw const ClientExtractionFailure(
          'Il player AnimeUnity non contiene la playlist.');
    }

    var depth = 0;
    var end = -1;
    for (var i = open; i < html.length; i++) {
      final char = html[i];
      if (char == '{') {
        depth++;
      } else if (char == '}') {
        depth--;
        if (depth == 0) {
          end = i + 1;
          break;
        }
      }
    }
    if (end < 0) {
      throw const ClientExtractionFailure(
          'La playlist AnimeUnity non e\' leggibile.');
    }

    final normalized = html
        .substring(open, end)
        .replaceAllMapped(
          RegExp(r'([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:'),
          (m) => '${m.group(1)}"${m.group(2)}":',
        )
        .replaceAll(RegExp(r',\s*}'), '}')
        .replaceAll(RegExp(r',\s*]'), ']')
        .replaceAll("'", '"');

    try {
      final decoded = jsonDecode(normalized);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on FormatException {
      // sotto
    }
    throw const ClientExtractionFailure(
        'La playlist AnimeUnity non e\' leggibile.');
  }

  String _buildPlaylistUrl(Map<String, dynamic> config) {
    final base = config['url'];
    if (base is! String || base.isEmpty) {
      throw const ClientExtractionFailure(
          'La playlist AnimeUnity non ha un indirizzo.');
    }

    final uri = Uri.parse(base);
    final query = Map<String, String>.from(uri.queryParameters);

    final params = config['params'];
    if (params is Map) {
      params.forEach((key, value) {
        if (value != null && value != false && '$value'.isNotEmpty) {
          query['$key'] = '$value';
        }
      });
    }
    query['h'] = '1';

    return uri.replace(queryParameters: query).toString();
  }

  Future<(String, DateTime?)> _pickRendition(
    _Transport transport,
    String playlistUrl,
    String quality,
  ) async {
    final response = await _send(
      transport,
      'GET',
      Uri.parse(playlistUrl),
      headers: {'user-agent': _userAgent, 'referer': '$_base/'},
    );
    if (response.status != 200) {
      throw ClientExtractionFailure(
          'La playlist AnimeUnity ha risposto HTTP ${response.status}.');
    }

    final variants = <_Variant>[];
    _Variant? current;

    for (final line in response.body.split(RegExp(r'\r?\n'))) {
      final inf = RegExp(r'#EXT-X-STREAM-INF:([^\n]*)').firstMatch(line);
      if (inf != null) {
        final bandwidth =
            int.tryParse(RegExp(r'BANDWIDTH=(\d+)').firstMatch(inf.group(1)!)?.group(1) ?? '') ?? 0;
        final height =
            int.tryParse(RegExp(r'RESOLUTION=\d+x(\d+)').firstMatch(inf.group(1)!)?.group(1) ?? '') ?? 0;
        current = _Variant(bandwidth: bandwidth, height: height);
        continue;
      }
      if (current != null && line.startsWith('http')) {
        variants.add(_Variant(
          url: line.trim(),
          bandwidth: current.bandwidth,
          height: current.height,
        ));
        current = null;
      }
    }

    if (variants.isEmpty) {
      throw const ClientExtractionFailure(
          'La playlist AnimeUnity non contiene nessun formato.');
    }

    final wanted = switch (quality) {
      '720p' => 720,
      '480p' => 480,
      '360p' => 360,
      _ => 1080,
    };

    final byHeight = variants
        .where((v) => v.height > 0 && v.height <= wanted)
        .toList()
      ..sort((a, b) => b.height.compareTo(a.height));

    final fallback = [...variants]
      ..sort((a, b) => b.bandwidth.compareTo(a.bandwidth));

    final chosen = byHeight.isNotEmpty
        ? byHeight.first
        : variants.firstWhere(
            (v) => v.height == wanted,
            orElse: () => fallback.first,
          );

    return (chosen.url, _expiryFromPlaylistUrl(playlistUrl));
  }

  /// La scadenza del token vixcloud, se l'indirizzo la porta.
  ///
  /// Il player la usa per capire se un link e' vecchio: senza, un token scaduto
  /// verrebbe aperto lo stesso e il fallimento sembrerebbe un file rotto.
  DateTime? _expiryFromPlaylistUrl(String playlistUrl) {
    final expires = Uri.parse(playlistUrl).queryParameters['expires'];
    final seconds = expires == null ? null : int.tryParse(expires);
    if (seconds == null || seconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  }

  static String _requestedQuality(String? quality) =>
      quality == null || quality.isEmpty ? '1080p' : quality;
}

/// Una rendition della playlist master.
class _Variant {
  const _Variant({this.url = '', required this.bandwidth, required this.height});

  final String url;
  final int bandwidth;
  final int height;
}

class _Session {
  const _Session(this.cookie, this.token);

  final String cookie;
  final String token;
}

/// Chi sa fare una richiesta HTTP per conto dell'estrattore.
///
/// E' un'interfaccia perche' le strade sono piu' d'una — `dart:io`, il motore
/// di rete di Chromium, il Worker — e l'estrazione deve poterle provare senza
/// sapere come sono fatte.
abstract interface class _Transport {
  /// La chiave della sessione: due trasporti diversi non condividono i cookie.
  String get sessionKey;

  /// Se i cookie li tiene il trasporto stesso.
  ///
  /// Il motore di Chromium ha un suo deposito di cookie e li rimanda da solo,
  /// come un browser: un header `cookie` scritto a mano lo sostituirebbe con
  /// una versione parziale.
  bool get managesCookies;

  Future<_HttpResult> send(
    String method,
    Uri uri,
    Map<String, String> headers,
  );
}

/// Il trasporto diretto: `dart:io`.
///
/// Riceve una funzione e non il client gia' fatto: quello con il DNS-over-HTTPS
/// va costruito solo se serve davvero, e questo trasporto viene elencato fra i
/// tentativi a ogni estrazione.
class _IoTransport implements _Transport {
  const _IoTransport(this._provide);

  final HttpClient Function() _provide;

  @override
  String get sessionKey => 'io';

  @override
  bool get managesCookies => false;

  @override
  Future<_HttpResult> send(
    String method,
    Uri uri,
    Map<String, String> headers,
  ) async {
    final request = await _provide().openUrl(method, uri);
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(const Duration(seconds: 20));
    final body = await response.transform(utf8.decoder).join();

    final setCookies = <String>[];
    final all = <String, String>{};
    response.headers.forEach((name, values) {
      final key = name.toLowerCase();
      all[key] = values.join(', ');
      if (key == 'set-cookie') setCookies.addAll(values);
    });

    return _HttpResult(response.statusCode, body, setCookies, all);
  }
}

/// Il trasporto che passa dal motore di rete di Chromium (Cronet).
///
/// E' lo stack del browser dentro l'app: l'unico che supera un filtro che legge
/// il nome del sito nell'handshake TLS.
class _ChromiumTransport implements _Transport {
  const _ChromiumTransport();

  @override
  String get sessionKey => 'chromium';

  @override
  bool get managesCookies => true;

  @override
  Future<_HttpResult> send(
    String method,
    Uri uri,
    Map<String, String> headers,
  ) async {
    final response = await ChromiumHttp.send(method, uri, headers);
    final rawCookie = response.setCookie;
    return _HttpResult(
      response.statusCode,
      response.body,
      [if (rawCookie != null && rawCookie.isNotEmpty) rawCookie],
      {'set-cookie': rawCookie ?? ''},
    );
  }
}

class _HttpResult {
  _HttpResult(this.status, this.body, this.setCookies, this.headers);

  final int status;
  final String body;
  final List<String> setCookies;

  /// Tutti gli header della risposta, con i nomi in minuscolo.
  final Map<String, String> headers;
}