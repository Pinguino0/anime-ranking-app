import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Un [HttpClient] che scavalca i blocchi DNS del gestore.
///
/// Perche' esiste
/// --------------
/// Su alcune reti mobili italiane l'operatore avvelena il DNS: il nome del
/// sito viene risolto verso un server di blocco, che presenta un certificato
/// sbagliato e fa fallire l'handshake TLS. Il browser dell'utente non se ne
/// accorge — usa il DNS-over-HTTPS — mentre l'app usa il DNS di sistema, e
/// per lei il sito "non si apre" anche se su Wi-Fi funziona.
///
/// La difesa e' la stessa del browser: prima di ogni connessione l'host si
/// risolve con DNS-over-HTTPS (a indirizzi letterali, cosi' non si puo'
/// falsificare il resolver), ci si collega all'indirizzo vero e si fa
/// l'handshake indicando il nome giusto. La richiesta parte dall'IP
/// dell'utente, che Cloudflare non banna: e' la strada che funziona davvero,
/// a differenza di un relay su datacenter (respinto con 403).
///
/// Un solo [build] va usato per tutte le richieste dello stesso servizio: la
/// risoluzione resta in cache per processo, quindi un host si risolve una
/// volta sola anche se le pagine da aprire sono dieci.
class DohBypassHttpClient {
  DohBypassHttpClient._();

  /// Il client per le query DoH. Non ha `connectionFactory`, perche'
  /// altrimenti si risolverebbe ricorsivamente.
  static final HttpClient _dohHttp = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8);

  /// Gli IP risolti via DoH, per host. Una risoluzione per host per processo.
  static final Map<String, List<String>> _cache = {};

  /// Costruisce un client che risolve gli host via DoH.
  ///
  /// [fallbackIps] fornisce, per un host, indirizzi noti da tentare per ultimi
  /// quando il DoH non risponde. Serve ai siti serviti da Cloudflare, che
  /// risponde dallo stesso indirizzo a qualunque nome (basta l'SNI giusto):
  /// se anche il resolver DoH fosse irraggiungibile, la connessione puo'
  /// comunque partire.
  static HttpClient build({
    List<String> Function(String host)? fallbackIps,
  }) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 15);

    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final host = uri.host;
      final port = uri.port;
      final resolved = await _lookup(host);

      // Ordine dei tentativi: gli indirizzi veri appena risolti, IPv6 prima
      // (che e' la strada che preferisce anche un browser); se il DoH non ha
      // risposto, il nome (il DNS di sistema, come sempre); per ultimi gli
      // eventuali indirizzi noti.
      final targets = <Object>[
        if (resolved.isNotEmpty) ...resolved,
        if (resolved.isEmpty) host,
        ...?fallbackIps?.call(host),
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

  /// Gli indirizzi IPv6 e IPv4 di [host], chiesti a un resolver DNS-over-HTTPS.
  ///
  /// Si usano indirizzi letterali (`1.1.1.1`, `8.8.8.8`) e non i nomi dei
  /// resolver: se il gestore intercetta il DNS, anche il nome del resolver
  /// verrebbe falsato, mentre il suo indirizzo no.
  ///
  /// Gli indirizzi IPv6 vengono prima: e' la strada che il filtro del gestore
  /// spesso non copre, ed e' quella che preferisce anche il browser.
  static Future<List<String>> _lookup(String host) async {
    final cached = _cache[host];
    if (cached != null) return cached;

    const endpoints = [
      'https://1.1.1.1/dns-query',
      // Secondo resolver Cloudflare: se il gestore blocca il primo indirizzo
      // (ma non il secondo) la risoluzione passa comunque.
      'https://1.0.0.1/dns-query',
      'https://8.8.8.8/resolve',
    ];
    for (final endpoint in endpoints) {
      try {
        final ipv6 = await _query(endpoint, host, 'AAAA');
        final ipv4 = await _query(endpoint, host, 'A');
        final addresses = [...ipv6, ...ipv4];
        if (addresses.isNotEmpty) {
          _cache[host] = addresses;
          return addresses;
        }
      } catch (_) {
        // Resolver irraggiungibile o risposta illeggibile: si prova il
        // successivo, e se nessuno risponde si torna alla risoluzione normale.
      }
    }
    return const [];
  }

  /// Gli indirizzi di [host] per il tipo di record richiesto (1 = A, 28 = AAAA).
  static Future<List<String>> _query(
    String endpoint,
    String host,
    String type,
  ) async {
    final uri = Uri.parse(endpoint).replace(
      queryParameters: {'name': host, 'type': type},
    );
    final request = await _dohHttp.getUrl(uri);
    request.headers.set('accept', 'application/dns-json');
    final response =
        await request.close().timeout(const Duration(seconds: 5));
    final body = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(body);
    final answers = decoded is Map ? decoded['Answer'] : null;
    if (answers is! List) return const [];

    final wantedType = type == 'AAAA' ? 28 : 1;
    final addresses = <String>[];
    for (final answer in answers) {
      if (answer is Map &&
          answer['type'] == wantedType &&
          answer['data'] is String) {
        addresses.add(answer['data'] as String);
      }
    }
    return addresses;
  }
}
