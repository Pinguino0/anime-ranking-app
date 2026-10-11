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
class AnimeUnityExtractor implements ClientSourceExtractor {
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

    final session = await _getSession();

    final infoUri = Uri.parse('$_base/info_api/$animeId/$episodeNumber').replace(
      queryParameters: {
        'start_range': '$episodeNumber',
        'end_range': '$episodeNumber',
      },
    );

    final info = await _apiJson(infoUri, _apiHeaders(session));
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
    final (hlsUrl, expiresAt) = await _pickRendition(playlistUrl, wanted);

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

  Future<_Session> _getSession() async {
    final cached = _session;
    final expiresAt = _sessionExpiresAt;
    if (cached != null && expiresAt != null && DateTime.now().isBefore(expiresAt)) {
      return cached;
    }

    final response = await _send(
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
    Uri uri,
    Map<String, String> headers, {
    bool retried = false,
  }) async {
    final response = await _send('GET', uri, headers: headers);

    // 419: la sessione non vale piu'. Se ne compra una nuova e si rifa' la
    // richiesta una volta sola — insistere all'infinito su una sessione che il
    // server continua a rifiutare nasconderebbe un problema vero.
    if (response.status == 419 && !retried) {
      _session = null;
      _sessionExpiresAt = null;
      final fresh = await _getSession();
      return _apiJson(uri, _apiHeaders(fresh), retried: true);
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
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    try {
      final request = await _http.openUrl(method, uri);
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
    } on SocketException {
      throw const ClientExtractionFailure(
          'Connessione ad AnimeUnity non riuscita. Controlla la rete.');
    }
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
    String playlistUrl,
    String quality,
  ) async {
    final response = await _send(
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