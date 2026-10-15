import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../domain/episode.dart';
import 'animeunity_extractor.dart';
import 'chromium_http.dart';
import 'doh_bypass.dart';

/// Chi sa riprodurre un episodio su una fonte di riserva.
///
/// Esiste separata da [ClientSourceExtractor] perche' risponde a una domanda
/// diversa: non "traduci questo indirizzo canonico", ma "questo anime, questo
/// episodio, trovalo altrove". La differenza conta perche' la fonte di riserva
/// non ha un canonico nel catalogo: il suo indirizzo va *scoperto*, e l'unico
/// modo di scoprirlo con certezza e' cercare l'anime e poi verificare di aver
/// preso quello giusto.
abstract interface class BackupSourceExtractor {
  /// Risolve `episodeNumber` dell'anime descritto da [titles] e [anilistId].
  ///
  /// [titles] serve solo a *cercare* i candidati. La scelta finale si fa
  /// confrontando l'id AniList, non il titolo: e' l'unico confronto che non
  /// rischia di riprodurre l'anime sbagliato quando il provider usa titoli
  /// localizzati diversi da quelli del catalogo.
  Future<ResolvedSource> extract({
    required String sourceId,
    required List<String> titles,
    required int episodeNumber,
    String? anilistId,
    int? year,
    String? language,
    String? quality,
  });
}

/// Una risposta HTTP grezza, corpo incluso.
class BackupHttpResponse {
  const BackupHttpResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

/// Chi sa fare una GET e restituire il corpo come testo.
///
/// E' un'interfaccia perche' i test possano fingere le risposte senza toccare
/// la rete: la logica di ricerca e di decodifica si prova con pagine finte,
/// che e' l'unico modo di provarla senza dipendere da un sito esterno.
abstract interface class BackupHttpClient {
  Future<BackupHttpResponse> get(String url, {Map<String, String>? headers});
}

/// Il client che passa dal motore di rete di Chromium (Cronet).
///
/// E' lo stesso stack del browser: sulle reti mobili che filtrano il nome del
/// sito nell'handshake TLS e' l'unico che passa.
class ChromiumBackupHttpClient implements BackupHttpClient {
  const ChromiumBackupHttpClient();

  @override
  Future<BackupHttpResponse> get(String url, {Map<String, String>? headers}) async {
    final response = await ChromiumHttp.send(
      'GET',
      Uri.parse(url),
      {
        'Accept-Language': 'it-IT,it;q=0.9,en;q=0.8',
        ...?headers,
      },
    );
    return BackupHttpResponse(response.statusCode, response.body);
  }
}

/// Prova il motore di Chromium e, se non c'e' o non riesce, la rete diretta.
class ChromiumThenIoBackupHttpClient implements BackupHttpClient {
  ChromiumThenIoBackupHttpClient(this._io);

  final BackupHttpClient _io;

  @override
  Future<BackupHttpResponse> get(String url, {Map<String, String>? headers}) async {
    if (ChromiumHttp.supported && !ChromiumHttp.unavailable) {
      try {
        return await const ChromiumBackupHttpClient().get(url, headers: headers);
      } catch (_) {
        // Il motore non e' disponibile o non ha raggiunto il sito: si ripiega
        // sulla rete diretta, che sulle reti normali va benissimo.
      }
    }
    return _io.get(url, headers: headers);
  }
}

/// L'implementazione vera, con `dart:io` e senza pacchetti HTTP aggiuntivi.
class IoBackupHttpClient implements BackupHttpClient {
  IoBackupHttpClient();

  /// Il client con il bypass DoH.
  ///
  /// Serve anche qui, non solo per AnimeUnity: sulla rete mobile di alcuni
  /// gestori il DNS di sistema e' avvelenato, e senza la risoluzione DoH il
  /// sito di riserva non si apre nemmeno (fallisce l'handshake TLS verso il
  /// server di blocco). Il browser non ha il problema perche' usa il DoH.
  static final HttpClient _client = DohBypassHttpClient.build(
    fallbackIps: (host) => host.contains('animesaturn')
        ? AnimeSaturnExtractor.cloudflareFallbacks
        : const [],
  );

  @override
  Future<BackupHttpResponse> get(String url, {Map<String, String>? headers}) async {
    final request = await _client.getUrl(Uri.parse(url));
    request.followRedirects = true;
    request.headers.set(HttpHeaders.userAgentHeader, AnimeSaturnExtractor.userAgent);
    request.headers.set(
      HttpHeaders.acceptLanguageHeader,
      'it-IT,it;q=0.9,en;q=0.8',
    );
    headers?.forEach((key, value) => request.headers.set(key, value));

    final response = await request.close().timeout(const Duration(seconds: 20));
    final body = await response.transform(utf8.decoder).join();
    return BackupHttpResponse(response.statusCode, body);
  }
}

/// Un candidato trovato dalla ricerca di AnimeSaturn.
class SaturnCandidate {
  SaturnCandidate({required this.path, required this.title, this.year});

  /// Il path dell'anime, es. `/anime/overgeared-zzb4X`.
  final String path;
  final String title;
  final int? year;

  /// true se la pagina e' la versione doppiata in italiano.
  bool get isItalian =>
      title.toUpperCase().contains('(ITA)') ||
      path.toLowerCase().contains('-ita');

  bool checked = false;
}

/// Risolve un episodio su AnimeSaturn, senza agganciare la fonte per titolo.
///
/// Perche' AnimeSaturn
/// -------------------
/// Alcuni operatori mobili (WindTre) bloccano AnimeUnity, che e' il provider
/// del 99,9% del catalogo, ma non AnimeSaturn. Senza un secondo provider,
/// l'utente con dati mobili vede "non si riesce a guardare" e su Wi-Fi funziona:
/// un guasto che sembra dell'app ma e' della rete. AnimeSaturn e' la rete di
/// riserva.
///
/// Perche' l'id AniList e non il titolo
/// ------------------------------------
/// AnimeSaturn pubblica i titoli in italiano ("L'attacco dei Giganti"), mentre
/// il catalogo tiene i romaji ("Shingeki no Kyojin"): confrontare le stringhe
/// fallirebbe o, peggio, aggancerebbe l'anime sbagliato. Ogni pagina di
/// AnimeSaturn linka AniList, e l'id AniList e' esattamente `anime.external_id`
/// del catalogo, quindi il confronto e' esatto. Il titolo serve solo a
/// *trovare* i candidati, non a sceglierli.
///
/// La sequenza
/// -----------
///   1. `GET /api/search?q=<titolo>` per ogni titolo, finche' non si trova la
///      pagina il cui link AniList coincide con `anilistId`;
///   2. `GET /anime/<slug>/ep-<n>`: la pagina di visione porta un JSON
///      (`watchPage({...})`) col player;
///   3. `GET https://play.saturncdn.net/embed/<id>/playlist?...`: restituisce
///      `{d, p}`;
///   4. `d` e' l'URL del video in base64, offuscato con XOR e chiave il token:
///      si decodifica e si ha il link riproducibile.
class AnimeSaturnExtractor implements BackupSourceExtractor {
  AnimeSaturnExtractor({BackupHttpClient? http})
      : _http = http ?? ChromiumThenIoBackupHttpClient(IoBackupHttpClient());

  final BackupHttpClient _http;

  /// I domini ufficiali, in ordine di preferenza. AnimeSaturn cambia dominio
  /// quando il principale viene oscurato: provarli tutti e' l'unico modo perche'
  /// la riserva resti viva senza aggiornare l'app a ogni cambio.
  static const List<String> bases = [
    'https://www.animesaturn.cx',
    'https://www.animesaturn.net',
    'https://www.animesaturn.cc',
    'https://www.animesaturn.com',
  ];

  /// Il CDN che ospita il player e la playlist.
  static const String playBase = 'https://play.saturncdn.net';

  /// Indirizzi Cloudflare noti che servono il sito, da tentare quando nemmeno
  /// il DoH risponde. Cloudflare risponde dallo stesso indirizzo a qualunque
  /// nome, basta l'SNI giusto nell'handshake.
  static const List<String> cloudflareFallbacks = [
    '188.114.96.7',
    '188.114.97.7',
  ];

  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// Quanti titoli provare in ricerca prima di arrendersi.
  static const int maxSearchQueries = 6;

  /// Quante pagine candidata aprire al massimo per verificare l'id AniList.
  static const int maxPageChecks = 12;

  /// Quanto deve somigliare un titolo quando *non* c'e' un id AniList con cui
  /// verificare. Sotto questa soglia non si scegle: meglio non riprodurre che
  /// riprodurre l'anime sbagliato.
  static const double strictTitleThreshold = 0.9;

  @override
  Future<ResolvedSource> extract({
    required String sourceId,
    required List<String> titles,
    required int episodeNumber,
    String? anilistId,
    int? year,
    String? language,
    String? quality,
  }) async {
    final queries = candidateQueries(titles);
    if (queries.isEmpty) {
      throw const ClientExtractionFailure(
        'Manca il titolo per cercare la fonte di riserva.',
      );
    }
    if (episodeNumber < 1) {
      throw const ClientExtractionFailure(
        'Manca il numero episodio per la fonte di riserva.',
      );
    }

    Object? lastError;
    for (final base in bases) {
      try {
        final path = await _findAnimePath(
          base: base,
          queries: queries,
          anilistId: anilistId,
          language: language,
          year: year,
        );
        if (path == null) continue;

        return await _resolveEpisode(
          base: base,
          path: path,
          episodeNumber: episodeNumber,
          sourceId: sourceId,
        );
      } catch (error) {
        // Un mirror irraggiungibile o senza questo anime non ferma niente: si
        // prova il successivo, e solo se cadono tutti si riporta l'ultimo
        // motivo, che e' quello che l'utente vedra'.
        lastError = error;
      }
    }

    if (lastError is ClientExtractionFailure) throw lastError;
    throw const ClientExtractionFailure(
      'Fonte di riserva non disponibile. Riprova.',
    );
  }

  /// I titoli da provare in ricerca: ripuliti, senza duplicati, e senza quelli
  /// che sono solo caratteri non latini, che la ricerca di AnimeSaturn non sa
  /// usare.
  static List<String> candidateQueries(List<String> titles) {
    final seen = <String>{};
    final out = <String>[];
    for (final raw in titles) {
      final title = raw.trim();
      if (title.isEmpty) continue;
      final key = title.toLowerCase();
      if (!seen.add(key)) continue;
      out.add(title);
      if (out.length >= maxSearchQueries) break;
    }
    return out;
  }

  /// Cerca l'anime e restituisce il path della pagina il cui id AniList e'
  /// [anilistId]. `null` se non c'e' nessuna corrispondenza esatta.
  ///
  /// La ricerca e' intervallata alla verifica: appena la ricerca ha prodotto
  /// qualche candidato, si controllano, e ci si ferma al primo id giusto. Cosi'
  /// nel caso normale (l'anime e' tra i primi risultati del primo titolo) si
  /// fanno due richieste invece di sei.
  Future<String?> _findAnimePath({
    required String base,
    required List<String> queries,
    required String? anilistId,
    required String? language,
    required int? year,
  }) async {
    final wantItalian = (language ?? '').toLowerCase().contains('ita');
    final candidates = <SaturnCandidate>[];
    final seenPaths = <String>{};
    var checks = 0;

    for (final query in queries) {
      final found = await _search(base, query);
      for (final candidate in found) {
        if (seenPaths.add(candidate.path)) candidates.add(candidate);
      }

      if (anilistId == null) continue;

      candidates.sort(
        (a, b) => _compare(a, b, wantItalian: wantItalian, year: year, queries: queries),
      );

      for (final candidate in candidates) {
        if (candidate.checked) continue;
        if (checks >= maxPageChecks) break;
        candidate.checked = true;
        checks++;
        final page = await _getText('$base${candidate.path}');
        if (anilistIdOf(page) == anilistId) return candidate.path;
      }

      if (checks >= maxPageChecks) break;
    }

    // Nessun id AniList con cui verificare: si accetta solo un titolo quasi
    // identico e della stessa lingua. Meglio non riprodurre nulla che
    // riprodurre un altro anime.
    if (anilistId == null && candidates.isNotEmpty) {
      candidates.sort(
        (a, b) => _compare(a, b, wantItalian: wantItalian, year: year, queries: queries),
      );
      final best = candidates.first;
      final score = _bestScore(best, queries);
      if (score >= strictTitleThreshold && best.isItalian == wantItalian) {
        return best.path;
      }
    }

    return null;
  }

  static int _compare(
    SaturnCandidate a,
    SaturnCandidate b, {
    required bool wantItalian,
    required int? year,
    required List<String> queries,
  }) {
    final la = a.isItalian == wantItalian ? 1 : 0;
    final lb = b.isItalian == wantItalian ? 1 : 0;
    if (la != lb) return lb - la;

    if (year != null) {
      final ya = a.year == year ? 1 : 0;
      final yb = b.year == year ? 1 : 0;
      if (ya != yb) return yb - ya;
    }

    return _bestScore(b, queries).compareTo(_bestScore(a, queries));
  }

  /// Interroga `/api/search` e restituisce i candidati.
  Future<List<SaturnCandidate>> _search(String base, String query) async {
    final url =
        '$base/api/search?q=${Uri.encodeQueryComponent(query)}';
    final response = await _http.get(
      url,
      headers: const {
        'Accept': 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
      },
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ClientExtractionFailure(
        'La ricerca della fonte di riserva ha risposto HTTP ${response.statusCode}.',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      return const [];
    }
    if (decoded is! Map) return const [];

    final results = decoded['results'];
    if (results is! List) return const [];

    final out = <SaturnCandidate>[];
    for (final entry in results) {
      if (entry is! Map) continue;
      final path = entry['url'];
      if (path is! String || path.trim().isEmpty) continue;
      out.add(
        SaturnCandidate(
          path: path.trim(),
          title: entry['title'] is String ? entry['title'] as String : '',
          year: int.tryParse('${entry['year']}'),
        ),
      );
    }
    return out;
  }

  /// Apre la pagina di visione e produce il link riproducibile.
  Future<ResolvedSource> _resolveEpisode({
    required String base,
    required String path,
    required int episodeNumber,
    required String sourceId,
  }) async {
    final pageUrl = '$base$path/ep-$episodeNumber';
    final page = await _getText(pageUrl);

    final rawJson = watchPageJson(page);
    if (rawJson == null) {
      throw const ClientExtractionFailure(
        'Episodio non trovato sulla fonte di riserva.',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(rawJson);
    } catch (_) {
      throw const ClientExtractionFailure(
        'Il player della fonte di riserva non e\' leggibile.',
      );
    }
    if (decoded is! Map) {
      throw const ClientExtractionFailure(
        'Il player della fonte di riserva non e\' leggibile.',
      );
    }

    final embed = embedUrlOf(decoded);
    if (embed == null) {
      throw const ClientExtractionFailure(
        'Nessun player per questo episodio sulla fonte di riserva.',
      );
    }

    final resolvedUrl = await _resolveEmbed(embed);
    if (resolvedUrl == null) {
      throw const ClientExtractionFailure(
        'Video non disponibile sulla fonte di riserva.',
      );
    }

    return ResolvedSource(
      sourceId: sourceId,
      resolvedUrl: resolvedUrl,
      // Il CDN di AnimeSaturn serve il file senza header particolari: e' stato
      // verificato che l'mp4 si apre senza `Referer`. Una `User-Agent` esplicita
      // resta perche' alcuni CDN la pretendono e non costa niente.
      headers: const {'User-Agent': userAgent},
      sourceType: sourceTypeOf(resolvedUrl),
      canonicalUrl: pageUrl,
      providerSlug: 'animesaturn',
    );
  }

  /// Trasforma l'URL del player (`play.saturncdn.net/embed/...`) nel video
  /// vero, passando per la playlist e decodificandone il contenuto offuscato.
  Future<String?> _resolveEmbed(String embed) async {
    final match =
        RegExp(r'embed/(\d+)\?token=([^&]+)&expires=(\d+)').firstMatch(embed);
    if (match == null) {
      // Non e' un embed di AnimeSaturn: alcuni episodi linkano direttamente il
      // file. Se lo e', si usa cosi' com'e'.
      return looksLikeMedia(embed) ? embed : null;
    }

    final id = match.group(1)!;
    final token = Uri.decodeComponent(match.group(2)!);
    final expires = match.group(3)!;

    final response = await _http.get(
      '$playBase/embed/$id/playlist?token=$token&expires=$expires',
      headers: {'Accept': 'application/json', 'Referer': embed},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) return null;

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;

    final d = decoded['d'];
    if (d is! String || d.isEmpty) return null;

    final url = xorDecodeBase64(d, token);
    if (url.isEmpty || url.startsWith('youtube/')) return null;
    return url;
  }

  Future<String> _getText(String url) async {
    final response = await _http.get(
      url,
      headers: const {'Accept': 'text/html,application/json;q=0.9,*/*;q=0.8'},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ClientExtractionFailure(
        'La fonte di riserva ha risposto HTTP ${response.statusCode}.',
      );
    }
    return response.body;
  }

  /// Dice se un titolo candidato e' plausibile per [queries].
  static double _bestScore(SaturnCandidate candidate, List<String> queries) {
    var best = 0.0;
    // La versione doppiata si chiama "Overgeared (ITA)": il marcatore non fa
    // parte del titolo e non deve abbassare la somiglianza.
    final candidateTitle = slugifyTitle(
      candidate.title.replaceAll(RegExp(r'\(\s*ita\s*\)', caseSensitive: false), ''),
    );
    for (final query in queries) {
      final score = dice(slugifyTitle(query), candidateTitle);
      if (score > best) best = score;
    }
    return best;
  }

  /// L'id AniList della pagina di un anime, letto dal link che AnimeSaturn
  /// pubblica verso AniList. `null` se la pagina non lo porta.
  static String? anilistIdOf(String page) {
    final match = RegExp(r'anilist\.co/anime/(\d+)').firstMatch(page);
    return match?.group(1);
  }

  /// L'URL del player dentro il JSON `watchPage({...})`.
  ///
  /// Si preferisce `initialVideoUrl` (il player predefinito) e si ripiega sul
  /// primo server, perche' alcune pagine hanno `initialVideoUrl` vuoto ma la
  /// lista dei server piena.
  static String? embedUrlOf(Map<dynamic, dynamic> data) {
    final initial = data['initialVideoUrl'];
    if (initial is String && initial.trim().isNotEmpty) return initial.trim();

    final servers = data['servers'];
    if (servers is List) {
      for (final server in servers) {
        if (server is Map) {
          final link = server['link'];
          if (link is String && link.trim().isNotEmpty) return link.trim();
        }
      }
    }
    return null;
  }

  /// Estrae il JSON di `watchPage({...})` da una pagina di visione.
  ///
  /// Il JSON sta dentro un attributo `x-data="watchPage({...})"`, quindi le
  /// virgolette sono entita' HTML (`&quot;`) e le graffe sono annidate. Si
  /// ripristinano prima le entita' — cosi' le virgolette tornano vere e si
  /// possono riconoscere le graffe che stanno *dentro* una stringa — poi si
  /// contano le graffe fino a quella che chiude l'oggetto. `null` se la pagina
  /// non ha il player.
  static String? watchPageJson(String html) {
    final decoded = decodeHtmlEntities(html);
    final marker = decoded.indexOf('watchPage(');
    if (marker < 0) return null;

    final start = decoded.indexOf('{', marker);
    if (start < 0) return null;

    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < decoded.length; i++) {
      final char = decoded[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (char == r'\') {
          escaped = true;
        } else if (char == '"') {
          inString = false;
        }
        continue;
      }
      if (char == '"') {
        inString = true;
      } else if (char == '{') {
        depth++;
      } else if (char == '}') {
        depth--;
        if (depth == 0) {
          return decoded.substring(start, i + 1);
        }
      }
    }
    return null;
  }

  /// Ripristina le entita' HTML che compaiono dentro un attributo.
  ///
  /// `&amp;` per ultimo: se fosse per primo, un `&amp;quot;` letterale
  /// diventerebbe `&quot;` e verrebbe decodificato una seconda volta.
  static String decodeHtmlEntities(String value) => value
      .replaceAll('&quot;', '"')
      .replaceAll('&#34;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');

  /// Decodifica il campo `d` della playlist: base64 di un URL offuscato con
  /// XOR, con chiave il token dell'embed.
  static String xorDecodeBase64(String data, String key) {
    if (key.isEmpty) return '';

    var normalized = data.replaceAll('-', '+').replaceAll('_', '/');
    final remainder = normalized.length % 4;
    if (remainder != 0) normalized = normalized.padRight(normalized.length + (4 - remainder), '=');

    final Uint8List bytes;
    try {
      bytes = base64Decode(normalized);
    } catch (_) {
      return '';
    }

    final keyBytes = utf8.encode(key);
    final out = Uint8List(bytes.length);
    for (var i = 0; i < bytes.length; i++) {
      out[i] = bytes[i] ^ keyBytes[i % keyBytes.length];
    }
    return utf8.decode(out, allowMalformed: true);
  }

  /// Il formato vero del link, che puo' non coincidere con quello dichiarato.
  static EpisodeSourceType sourceTypeOf(String url) =>
      url.contains('.m3u8') ? EpisodeSourceType.hls : EpisodeSourceType.mp4;

  static bool looksLikeMedia(String url) =>
      url.contains('.mp4') || url.contains('.m3u8');

  /// Riduce un titolo a parole minuscole separate da spazi, per confrontarlo.
  static String slugifyTitle(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();

  /// Somiglianza fra due titoli come sovrapposizione di parole (dado di Sørensen).
  ///
  /// E' lo stesso criterio del resolver lato server: due titoli con le stesse
  /// parole valgono 1, due senza parole in comune valgono 0.
  static double dice(String a, String b) {
    final ta = a.split(' ').where((w) => w.isNotEmpty).toList();
    final tb = b.split(' ').where((w) => w.isNotEmpty).toList();
    if (ta.isEmpty || tb.isEmpty) return 0;

    final setB = tb.toSet();
    var intersection = 0;
    for (final word in ta) {
      if (setB.contains(word)) intersection++;
    }
    return (2 * intersection) / (ta.length + tb.length);
  }
}
