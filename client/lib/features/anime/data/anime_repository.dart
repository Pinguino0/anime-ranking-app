import 'dart:convert';

// `HttpMethod` arriva da qui: supabase_flutter riesporta il client delle
// Edge Function e i suoi tipi, quindi non serve dipendere da `functions_client`
// direttamente per usare `invoke`.
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/env/app_config.dart';
import '../../../core/error/app_failure.dart';
import '../domain/anime.dart';

/// Operazioni sul catalogo anime.
///
/// Due percorsi distinti, e' importante sapere quale dei due si usa:
///
///  - [searchLocal] e [currentSeason] leggono il catalogo sul server. Sono
///    veloci e funzionano senza rete verso l'esterno. E' la via normale.
///  - [searchRemote] chiama l'Edge Function, che interroga Jikan e scrive in
///    catalogo. Serve quando la ricerca locale non trova niente.
///
/// Il client non interroga mai Jikan direttamente: la quota e' del progetto e
/// un client che chiama a piacere la esaurisce per tutti gli utenti.
abstract interface class AnimeRepository {
  /// Cerca nel catalogo locale.
  ///
  /// [query] vuota con filteri attivi e' lecito: "tutti gli anime del 2024 di
  /// Action" e' una ricerca valida senza testo.
  Future<AnimePage> searchLocal(
    String query, {
    AnimeFilters filters,
    int limit,
    int offset,
  });

  /// Cerca su Jikan passando dall'Edge Function, con scrittura in catalogo.
  ///
  /// Restituisce i risultati anche se la cache non e' scrivibile: e' il
  /// fallback che permette di vedere qualcosa anche quando il database
  /// rifiuta la scrittura.
  Future<AnimePage> searchRemote(
    String query, {
    AnimeFilters filters,
    int limit,
    int page,
  });

  /// Anime della stagione corrente e delle ultime uscite.
  Future<List<AnimeEntry>> currentSeason({int limit, String? genre});

  /// Generi presenti in catalogo, con il rispettivo numero di anime.
  Future<List<AnimeGenre>> genres();

  /// Riepilogo del catalogo per la testata.
  Future<AnimeCatalogStats> stats();

  /// Verifica che l'Edge Function sia raggiungibile.
  ///
  /// Serve a distinguere "funzione non deployata" da "nessun risultato": senza
  /// questa prova, un utente della beta vede una ricerca vuota e non sa se
  /// sta sbagliando la parola o se il backend non esiste.
  Future<AnimeEdgeHealth> checkEdge();
}

/// Stato dell'Edge Function, per messaggi di errore onesti.
enum AnimeEdgeHealth {
  /// La funzione risponde e puo' interrogare Jikan.
  ready,

  /// La funzione non e' stata deployata.
  missing,

  /// Jikan e' momentaneamente sovraccarico (HTTP 429).
  rateLimited,

  /// La funzione c'e' ma fallisce (500, timeout, rete assente).
  failing,
}

/// Una pagina di risultati.
class AnimePage {
  const AnimePage({
    required this.results,
    required this.hasNext,
    this.total,
    this.fromCache = false,
  });

  final List<AnimeEntry> results;

  /// true se esiste una pagina successiva.
  final bool hasNext;

  /// Totale dei risultati, quando il server lo sa.
  ///
  /// `null` quando arriva da Jikan senza conteggio: la UI mostra allora solo
  /// il numero di righe caricate, senza inventare un totale.
  final int? total;

  /// true se la pagina e' arrivata dal catalogo locale senza toccare Jikan.
  ///
  /// Ha un doppio uso: evita di rilanciare la stessa ricerca e permette di
  /// scrivere "gia' in catalogo" senza mentire quando la provenienza non e'
  /// nota.
  final bool fromCache;
}

class SupabaseAnimeRepository implements AnimeRepository {
  SupabaseAnimeRepository(this._client);

  final SupabaseClient _client;

  /// Quanti risultati per pagina.
  ///
  /// 24 e' la scelta che viene dal config: e' anche il limite di Jikan per
  /// richiesta, quindi chiedere di piu' alla Edge Function non porterebbe nulla.
  static const int pageSize = AppConfig.searchPageSize;

  @override
  Future<AnimePage> searchLocal(
    String query, {
    AnimeFilters filters = AnimeFilters.none,
    int limit = pageSize,
    int offset = 0,
  }) async {
    try {
      final rows = await _client.rpc(
        'anime_search',
        params: {
          '_query': query.trim().isEmpty ? null : query.trim(),
          ..._filterParams(filters),
          // Nessuna ordinazione per rilevanza quando il client non cerca un
          // testo: la RPC gia' lo fa al suo interno e inviare un ordinamento
          // diverso mostrerebbe risultati in un ordine che nessuno ha chiesto.
          '_sort': 'relevance',
          '_limit': limit,
          '_offset': offset,
        },
      );

      final entries = [
        for (final row in _rows(rows)) AnimeEntry.parse(_map(row)),
      ];

      return AnimePage(
        results: entries,
        // La RPC non restituisce il totale per ogni pagina, quindi il segnale di
        // fine e' una pagina piu' corta del richiesto: e' il modo piu' onesto
        // perche' non richiede una seconda query a ogni scroll.
        hasNext: entries.length == limit,
        fromCache: true,
      );
    } on PostgrestException catch (e) {
      throw _translate(e);
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw const AnimeFailure(
        'Catalogo non raggiungibile. Riprova.',
        isRetryable: true,
      );
    }
  }

  @override
  Future<AnimePage> searchRemote(
    String query, {
    AnimeFilters filters = AnimeFilters.none,
    int limit = pageSize,
    int page = 1,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      throw const AnimeFailure('Scrivi qualcosa da cercare.');
    }

    // I filtri non viaggiano: Jikan accetta solo i suoi (`sfw`, `by_popularity`)
    // e non conosce "voto almeno 7". Tradurre "minScore" in qualcosa che Jikan
    // capirebbe richiederebbe di scaricare tutti i risultati e filtrarli qui,
    // che e' il contrario di risparmiare banda. Percio' i filtri restano
    // al client e vengono riapplicati sulla pagina ricevuta.
    //
    // E' una scelta con un limite dichiarato: filtrando solo la pagina
    // ricevuta, i risultati mostrati possono essere meno del previsto. La UI
    // lo dice con "filtri applicati ai risultati caricati".
    final queryParams = <String, String>{
      'q': trimmed,
      'limit': '$limit',
      'page': '$page',
    };
    if (filters.mediaType != null) {
      final flag = switch (filters.mediaType!) {
        AnimeMediaType.tv => 'tv',
        AnimeMediaType.movie => 'movie',
        AnimeMediaType.ova => 'ova',
        AnimeMediaType.special => 'special',
        // ONA e Music non sono fra i filtri di Jikan: non si invia nulla e il
        // filtro resta da applicare lato client.
        AnimeMediaType.ona || AnimeMediaType.music => null,
      };
      if (flag != null) queryParams['filter'] = flag;
    }

    try {
      final response = await _client.functions.invoke(
        AppConfig.jikanFunction,
        method: HttpMethod.get,
        // `route` e' un parametro, non un path: il gateway Supabase chiama
        // sempre la radice della funzione, quindi un `/search` nel path non
        // arriverebbe mai alla funzione.
        queryParameters: {...queryParams, 'route': '/search'},
      );

      final decoded = _decodeBody(response.data);
      if (decoded == null) {
        throw const AnimeFailure('Risposta vuota dal server anime.');
      }
      if (decoded is! Map) {
        throw const AnimeFailure('Risposta non riconosciuta dal server anime.');
      }
      final body = Map<String, dynamic>.from(decoded);

      // La funzione puo' rispondere 200 con un corpo che contiene `error`: e'
      // il modo che ha per segnalare un fallimento di Jikan senza cambiare il
      // codice HTTP. Va controllato prima di leggere `results`, altrimenti il
      // crash sarebbe su una lista inesistente.
      final error = body['error'];
      if (error is String && error.isNotEmpty) {
        throw AnimeFailure(_edgeMessage(body));
      }

      final rawResults = body['results'];
      final entries = rawResults is List
          ? [
              for (final row in rawResults)
                if (row is Map)
                  AnimeEntry.parse(Map<String, dynamic>.from(row)),
            ]
          : <AnimeEntry>[];

      // Filtri che Jikan non conosce, applicati alla pagina ricevuta.
      final filtered = _applyLocalFilters(entries, filters);

      final pagination = body['pagination'];
      final hasNext = pagination is Map && pagination['has_next'] == true;
      final total = pagination is Map && pagination['total'] is num
          ? (pagination['total'] as num).toInt()
          : null;

      return AnimePage(
        results: filtered,
        hasNext: hasNext,
        total: total,
        fromCache: body['source'] == 'cache',
      );
    } on AppFailure {
      rethrow;
    } on FunctionException catch (e) {
      // `FunctionsFetchException` arriva con status 0: la richiesta non e'
      // nemmeno uscita dal dispositivo, quindi il rimprovero va all'app e non
      // al server. Gli altri hanno uno status vero e vanno tradotti.
      throw AnimeFailure(
        _edgeMessageFromInvoke(e),
        isRetryable: e.status == 0 || e.status >= 500,
      );
    } catch (_) {
      throw const AnimeFailure(
        'Server anime non raggiungibile. Riprova.',
        isRetryable: true,
      );
    }
  }

  @override
  Future<List<AnimeEntry>> currentSeason({
    int limit = pageSize,
    String? genre,
  }) async {
    try {
      final rows = await _client.rpc(
        'anime_current_season',
        params: {
          '_limit': limit,
          '_offset': 0,
          if (genre != null && genre.isNotEmpty) '_genre': genre,
        },
      );

      return [for (final row in _rows(rows)) AnimeEntry.parse(_map(row))];
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (_) {
      throw const AnimeFailure(
        'Novita\' non raggiungibili. Riprova.',
        isRetryable: true,
      );
    }
  }

  @override
  Future<List<AnimeGenre>> genres() async {
    try {
      final rows = await _client.rpc('anime_genres');

      return [for (final row in _rows(rows)) AnimeGenre.parse(_map(row))];
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (_) {
      throw const AnimeFailure(
        'Generi non disponibili. Riprova.',
        isRetryable: true,
      );
    }
  }

  @override
  Future<AnimeCatalogStats> stats() async {
    try {
      final rows = await _client.rpc('anime_catalog_stats');
      final first = _rows(rows).firstOrNull;

      if (first == null) {
        // La funzione restituisce sempre una riga; se non c'e', il catalogo e'
        // illeggibile e dire "vuoto" sarebbe raccontare il falso come una notizia.
        throw const AnimeFailure('Statistiche non riconosciute.');
      }

      return AnimeCatalogStats.parse(_map(first));
    } on PostgrestException catch (e) {
      throw _translate(e);
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw const AnimeFailure(
        'Statistiche non disponibili. Riprova.',
        isRetryable: true,
      );
    }
  }

  @override
  Future<AnimeEdgeHealth> checkEdge() async {
    try {
      // `/health` e non `/search`: la rotta di ricerca risponderebbe "400
      // ricerca vuota" anche con la funzione perfettamente viva, e il controllo
      // direbbe "non raggiungibile" per unanime che funziona.
      final response = await _client.functions.invoke(
        AppConfig.jikanFunction,
        method: HttpMethod.get,
        queryParameters: const {'route': '/health'},
      );

      if (_decodeBody(response.data) is Map) {
        return AnimeEdgeHealth.ready;
      }
      return AnimeEdgeHealth.failing;
    } on FunctionException catch (e) {
      final status = e.status;
      if (status == 429) return AnimeEdgeHealth.rateLimited;
      // 404 e' il caso della funzione non deployata: e' l'unico status che
      // distingue "non esiste" da "esiste e fallisce", e la differenza per
      // l'utente e' enorme.
      if (status == 404) return AnimeEdgeHealth.missing;
      return AnimeEdgeHealth.failing;
    } catch (_) {
      return AnimeEdgeHealth.failing;
    }
  }

  /// Traduce i filtri nel formato atteso da `anime_search`.
  ///
  /// I parametri `null` non vengono inviati: la RPC li tratta come "non
  /// filtrare", e ometterli mantiene la query leggibile nei log del server.
  Map<String, dynamic> _filterParams(AnimeFilters filters) => {
    if (filters.genres.isNotEmpty) '_genres': filters.genres,
    if (filters.mediaType != null) '_media_type': filters.mediaType!.wire,
    if (filters.season != null) '_season': filters.season!.wire,
    if (filters.status != null) '_status': filters.status!.wire,
    if (filters.yearFrom != null) '_year_from': filters.yearFrom,
    if (filters.yearTo != null) '_year_to': filters.yearTo,
    if (filters.minScore != null) '_min_score': filters.minScore,
    if (filters.minEpisodes != null) '_min_episodes': filters.minEpisodes,
    if (filters.maxEpisodes != null) '_max_episodes': filters.maxEpisodes,
  };

  /// Applica sul lato client i filtri che Jikan non conosce.
  ///
  /// Vale solo per la pagina appena ricevuta, non per il catalogo intero: e'
  /// un limite dichiarato del percorso remoto, non un bug.
  List<AnimeEntry> _applyLocalFilters(
    List<AnimeEntry> entries,
    AnimeFilters filters,
  ) {
    if (filters.isEmpty) return entries;

    return entries.where((entry) {
      // Generi: AND. Se l'opera non ha il campo generi non puo' soddisfare un
      // filtro che lo richiede.
      for (final genre in filters.genres) {
        if (!entry.genres.contains(genre)) return false;
      }

      if (filters.mediaType != null && entry.mediaType != filters.mediaType) {
        return false;
      }
      if (filters.season != null && entry.season != filters.season) {
        return false;
      }
      if (filters.status != null && entry.status != filters.status) {
        return false;
      }
      if (filters.yearFrom != null &&
          (entry.year == null || entry.year! < filters.yearFrom!)) {
        return false;
      }
      if (filters.yearTo != null &&
          (entry.year == null || entry.year! > filters.yearTo!)) {
        return false;
      }
      if (filters.minScore != null &&
          (entry.score == null || entry.score! < filters.minScore!)) {
        return false;
      }
      if (filters.minEpisodes != null &&
          (entry.episodes == null || entry.episodes! < filters.minEpisodes!)) {
        return false;
      }
      if (filters.maxEpisodes != null &&
          (entry.episodes == null || entry.episodes! > filters.maxEpisodes!)) {
        return false;
      }

      return true;
    }).toList();
  }

  /// Messaggio d'errore estraibile dal corpo JSON della Edge Function.
  String _edgeMessage(Map<String, dynamic> body) {
    final message = body['error'];
    if (message is String && message.trim().isNotEmpty) {
      return message.trim();
    }
    return 'Server anime: errore sconosciuto.';
  }

  /// Messaggio per un'eccezione di invocazione.
  ///
  /// functions_client mette il corpo della risposta in `details`: se la funzione
  /// ha risposto `Content-Type: application/json` arriva gia' decodificato,
  /// altrimenti e' testo grezzo. Dentro c'e' il JSON dell'errore della
  /// funzione, con un messaggio molto piu' utile di "errore 500".
  String _edgeMessageFromInvoke(FunctionException e) {
    final details = e.details;
    final decoded = _decodeBody(details);
    if (decoded is Map) {
      final message = decoded['error'];
      if (message is String && message.trim().isNotEmpty) return message.trim();
    }
    if (details is String &&
        details.isNotEmpty &&
        !details.startsWith('{') &&
        details.length < 200) {
      return details.trim();
    }

    return switch (e.status) {
      0 => 'Connessione assente. Verifica la rete e riprova.',
      404 => 'Il server anime non e\' ancora stato attivato.',
      401 || 403 => 'Sessione non valida. Rientra nell app.',
      429 => 'Troppe ricerche in poco tempo. Aspetta un momento.',
      >= 500 => 'Server anime non raggiungibile. Riprova.',
      _ => 'Server anime: errore ${e.status}.',
    };
  }

  /// Porta il corpo della risposta a una forma decodificabile.
  ///
  /// `Content-Type: application/json` arriva gia' come `Map`, quindi chiamare
  /// `jsonDecode` su quello lancerebbe; `text/plain` invece e' una stringa da
  /// decodificare. Qualsiasi altro tipo non e' una risposta che sappiamo
  /// leggere e vale `null`.
  Object? _decodeBody(Object? body) {
    if (body == null) return null;
    if (body is String) {
      if (body.trim().isEmpty) return null;
      try {
        return jsonDecode(body);
      } catch (_) {
        return null;
      }
    }
    return body;
  }

  /// Normalizza la risposta di una funzione "returns table".
  ///
  /// Copiato dal pattern gia' usato dagli altri repository: PostgREST puo'
  /// consegnare `null` invece di una lista vuota, e iterare su `null` darebbe
  /// un errore che l'utente leggerebbe come "server assente".
  List<Object?> _rows(Object? raw) => switch (raw) {
    final List<Object?> list => list,
    _ => const [],
  };

  Map<String, dynamic> _map(Object? row) =>
      row is Map ? Map<String, dynamic>.from(row) : const <String, dynamic>{};

  AnimeFailure _translate(PostgrestException e) {
    const passthrough = {
      '22023', // validazione input
      '42501', // permessi
      '28000', // autenticazione
      'P0002', // parametro mancante
      '23503', // riferimento non valido
    };

    if (passthrough.contains(e.code) && e.message.trim().isNotEmpty) {
      return AnimeFailure(e.message.trim());
    }

    if (e.code == null && e.message.contains('row-level security')) {
      return const AnimeFailure(
        'Catalogo non leggibile: permessi insufficienti.',
      );
    }

    // La funzione non esiste ancora: il caso normale se la migration 019 non
    // e' stata applicata. Vale la pena distinguerlo dal generico "riprova",
    // altrimenti l'utente riprova per sempre un errore che non passa da solo.
    if (e.code == '42883' ||
        e.message.contains('function') &&
            e.message.contains('does not exist')) {
      return const AnimeFailure(
        'Catalogo non ancora attivo. Applica la migration 019.',
      );
    }

    return const AnimeFailure(
      'Operazione non riuscita. Riprova.',
      isRetryable: true,
    );
  }
}

/// Errore sulle operazioni del catalogo anime.
class AnimeFailure extends AppFailure {
  const AnimeFailure(super.message, {super.isRetryable});
}
