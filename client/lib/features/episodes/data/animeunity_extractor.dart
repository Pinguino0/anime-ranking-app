import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/episode.dart';

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
/// Tutto con `dart:io`, senza pacchetti HTTP aggiuntivi: i cookie di sessione si
/// leggono e si rimandano a mano, che e' l'unica cosa che un client HTTP
/// generico non fa da solo.
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

  /// Il client che risolve gli indirizzi via DNS-over-HTTPS.
  ///
  /// Viene costruito solo se serve, cioe' quando un'estrazione normale
  /// fallisce: sulla maggioranza delle reti non tocca mai la rete.
  static HttpClient? _bypassHttpClient;

  /// Il client usato per parlare con i resolver DoH. Non ha nessun
  /// `connectionFactory`, perche' altrimenti si risolverebbe ricorsivamente.
  static final HttpClient _dohHttp = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8);

  /// Gli IP risolti via DoH, per host. Una risoluzione per host per processo.
  static final Map<String, List<String>> _dohCache = {};

  /// Indirizzi Cloudflare noti che servono il sito. Si tentano per ultimi,
  /// quando il DoH non risponde: sono gli stessi a cui puntano i domini
  /// alternativi (`.to`, `.it`), che sono lo stesso operatore.
  static const List<String> _cloudflareFallbacks = [
    '188.114.96.7',
    '188.114.97.7',
    '104.21.83.16',
    '172.67.166.248',
  ];

  static _Session? _session;
  static DateTime? _sessionExpiresAt;

  @override
  Future<ResolvedSource> extract({
    required String sourceId,
    required String canonicalUrl,
    required int episodeNumber,
    String? quality,
    String? providerSlug,
  }) async {
    try {
      return await _extract(
        client: _http,
        sourceId: sourceId,
        canonicalUrl: canonicalUrl,
        episodeNumber: episodeNumber,
        quality: quality,
        providerSlug: providerSlug,
      );
    } on ClientExtractionFailure catch (failure) {
      // Un tentativo andato male puo' lasciare in cache una sessione che il
      // server ha ormai cominciato a rifiutare (Cloudflare, token scaduto). La
      // si butta, cosi' il prossimo tentativo — il player ne fa qualche giro,
      // vedi `_EpisodePlayerState.resolutionTries` — ne compra una nuova invece
      // di ripetere lo stesso errore. Su un errore non ritentabile non si tocca
      // nulla: la sessione non c'entra con un episodio inesistente.
      if (!failure.isRetryable) rethrow;

      _session = null;
      _sessionExpiresAt = null;

      // Secondo giro con il client "anti-blocco". Alcune reti — tipicamente i
      // dati mobili italiani — intercettano il DNS della fonte e rispondono con
      // una pagina di blocco: la connessione fallisce subito e il player mostra
      // "le fonti non si risolvono", anche se dal Wi-Fi lo stesso episodio
      // parte. Qui si risolve l'indirizzo con DNS-over-HTTPS (che il gestore
      // non vede) e ci si collega direttamente, tenendo l'SNI giusto perche' il
      // certificato resti valido. Se anche cosi' non passa, si rilancia
      // l'errore originale: il player passa alla fonte successiva come prima.
      try {
        return await _extract(
          client: _bypassHttp,
          sourceId: sourceId,
          canonicalUrl: canonicalUrl,
          episodeNumber: episodeNumber,
          quality: quality,
          providerSlug: providerSlug,
        );
      } on ClientExtractionFailure {
        _session = null;
        _sessionExpiresAt = null;
      }
      rethrow;
    }
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

    final session = await _getSession(_http);
    final uri = Uri.parse('$_base/info_api/$animeId/1').replace(
      queryParameters: {'start_range': '1', 'end_range': '1'},
    );

    final info = await _apiJson(_http, uri, _apiHeaders(session));
    final raw = info['episodes_count'];
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  Future<ResolvedSource> _extract({
    required HttpClient client,
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

    final session = await _getSession(client);

    final infoUri = Uri.parse('$_base/info_api/$animeId/$episodeNumber').replace(
      queryParameters: {
        'start_range': '$episodeNumber',
        'end_range': '$episodeNumber',
      },
    );

    final info = await _apiJson(client, infoUri, _apiHeaders(session));
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
      client,
      'GET',
      Uri.parse('$_base/embed-url/$episodeId'),
      headers: {
        ..._apiHeaders(session),
        'accept': 'text/plain',
        'referer': animePage,
      },
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
      client,
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
        await _pickRendition(client, playlistUrl, wanted);

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

  Future<_Session> _getSession(HttpClient client) async {
    final cached = _session;
    final expiresAt = _sessionExpiresAt;
    if (cached != null && expiresAt != null && DateTime.now().isBefore(expiresAt)) {
      return cached;
    }

    final response = await _send(
      client,
      'GET',
      Uri.parse('$_base/'),
      headers: {'user-agent': _userAgent, 'accept': 'text/html'},
    );
    if (response.status != 200) {
      throw ClientExtractionFailure(
          'AnimeUnity ha risposto HTTP ${response.status}.');
    }

    final cookies = response.setCookies
        .map((c) => c.split(';').first.trim())
        .where((c) => c.isNotEmpty)
        .toList();
    final cookie = cookies.join('; ');

    String? token;
    for (final raw in response.setCookies) {
      final match = RegExp('XSRF-TOKEN=([^;]+)').firstMatch(raw);
      if (match != null) {
        token = Uri.decodeComponent(match.group(1)!);
        break;
      }
    }

    if (token == null || token.isEmpty) {
      throw const ClientExtractionFailure(
          'AnimeUnity non ha rilasciato il token CSRF.');
    }

    _session = _Session(cookie, token);
    _sessionExpiresAt = DateTime.now().add(_sessionTtl);
    return _session!;
  }

  Map<String, String> _apiHeaders(_Session session) => {
        'user-agent': _userAgent,
        'accept': 'application/json',
        'x-requested-with': 'XMLHttpRequest',
        'x-xsrf-token': session.token,
        if (session.cookie.isNotEmpty) 'cookie': session.cookie,
      };

  Future<Map<String, dynamic>> _apiJson(
    HttpClient client,
    Uri uri,
    Map<String, String> headers, {
    bool retried = false,
  }) async {
    final response = await _send(client, 'GET', uri, headers: headers);

    // 419: la sessione non vale piu'. Se ne compra una nuova e si rifa' la
    // richiesta una volta sola — insistere all'infinito su una sessione che il
    // server continua a rifiutare nasconderebbe un problema vero.
    if (response.status == 419 && !retried) {
      _session = null;
      _sessionExpiresAt = null;
      final fresh = await _getSession(client);
      return _apiJson(client, uri, _apiHeaders(fresh), retried: true);
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

  Future<_HttpResult> _send(
    HttpClient client,
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    try {
      final request = await client.openUrl(method, uri);
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(const Duration(seconds: 20));
      final body = await response.transform(utf8.decoder).join();

      final setCookies = <String>[];
      response.headers.forEach((name, values) {
        if (name.toLowerCase() == 'set-cookie') setCookies.addAll(values);
      });

      return _HttpResult(response.statusCode, body, setCookies);
    } on TimeoutException {
      throw const ClientExtractionFailure('AnimeUnity non risponde. Riprova.');
    } on HandshakeException {
      // Tipico di una rete che intercetta la fonte: la connessione arriva a un
      // server che non ha il certificato giusto. Ritentabile, perche' il giro
      // con il DNS-over-HTTPS puo' aggirarla.
      throw const ClientExtractionFailure(
          'Connessione sicura ad AnimeUnity non riuscita. Riprova.');
    } on SocketException {
      throw const ClientExtractionFailure(
          'Connessione ad AnimeUnity non riuscita. Controlla la rete.');
    }
  }

  // -------------------------------------------------------------------------
  // Aggiramento dei blocchi di rete
  // -------------------------------------------------------------------------

  static HttpClient get _bypassHttp =>
      _bypassHttpClient ??= _buildBypassClient();

  /// Il client che scavalca i blocchi DNS/IP del gestore.
  ///
  /// Differenza dall'`HttpClient` normale: prima di ogni connessione risolve
  /// l'host con DNS-over-HTTPS e si collega all'indirizzo vero, poi fa
  /// l'handshake TLS indicando il nome giusto. Un gestore che risponde alle
  /// richieste DNS con una pagina di blocco viene cosi' scavalcato: la
  /// connessione non passa piu' dal suo resolver.
  static HttpClient _buildBypassClient() {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 15);

    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final host = uri.host;
      final port = uri.port;
      final isAnimeUnity = host.contains('animeunity');

      final resolved = await _dohLookup(host);

      // Ordine dei tentativi: gli indirizzi veri appena risolti; se il DoH non
      // ha risposto, il nome (il DNS di sistema, come sempre); per il sito, in
      // ultima istanza, indirizzi Cloudflare noti. Cloudflare serve lo stesso
      // sito da qualunque suo IP, basta l'SNI giusto nel handshake.
      final targets = <Object>[
        if (resolved.isNotEmpty) ...resolved,
        if (resolved.isEmpty) host,
        if (isAnimeUnity) ..._cloudflareFallbacks,
      ];

      Object? lastError;
      for (final target in targets) {
        try {
          final task = await Socket.startConnect(target, port);
          if (uri.scheme != 'https') return task;

          final raw = await task.socket;
          // `host` (non l'IP) e' l'SNI: il certificato resta valido e il
          // server sa quale sito si sta chiedendo.
          final secure = await SecureSocket.secure(raw, host: host);
          return ConnectionTask.fromSocket(
            Future<SecureSocket>.value(secure),
            task.cancel,
          );
        } catch (error) {
          lastError = error;
        }
      }
      throw lastError ??
          const SocketException('Nessun indirizzo raggiungibile.');
    };

    return client;
  }

  /// Gli indirizzi IPv4 di [host], chiesti a un resolver DNS-over-HTTPS.
  ///
  /// Si usano indirizzi letterali (`1.1.1.1`, `8.8.8.8`) e non i nomi dei
  /// resolver: se il gestore intercetta il DNS, anche il nome del resolver
  /// verrebbe falsato, mentre il suo indirizzo no. Il risultato resta in cache
  /// per il processo: un host si risolve una volta sola.
  static Future<List<String>> _dohLookup(String host) async {
    final cached = _dohCache[host];
    if (cached != null) return cached;

    const endpoints = ['https://1.1.1.1/dns-query', 'https://8.8.8.8/resolve'];
    for (final endpoint in endpoints) {
      try {
        final uri = Uri.parse(endpoint)
            .replace(queryParameters: {'name': host, 'type': 'A'});
        final request = await _dohHttp.getUrl(uri);
        request.headers.set('accept', 'application/dns-json');
        final response =
            await request.close().timeout(const Duration(seconds: 5));
        final body = await response.transform(utf8.decoder).join();
        final decoded = jsonDecode(body);
        final answers = decoded is Map ? decoded['Answer'] : null;
        if (answers is! List) continue;

        final addresses = <String>[];
        for (final answer in answers) {
          if (answer is Map && answer['type'] == 1 && answer['data'] is String) {
            addresses.add(answer['data'] as String);
          }
        }
        if (addresses.isNotEmpty) {
          _dohCache[host] = addresses;
          return addresses;
        }
      } catch (_) {
        // Resolver irraggiungibile o risposta illeggibile: si prova il
        // successivo, e se nessuno risponde si torna alla risoluzione normale.
      }
    }
    return const [];
  }

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
    HttpClient client,
    String playlistUrl,
    String quality,
  ) async {
    final response = await _send(
      client,
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

class _HttpResult {
  const _HttpResult(this.status, this.body, this.setCookies);

  final int status;
  final String body;
  final List<String> setCookies;
}