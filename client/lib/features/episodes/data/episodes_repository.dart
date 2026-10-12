import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/env/app_config.dart';
import '../domain/episode.dart';
import 'animeunity_extractor.dart';

/// Una risoluzione richiesta e non riuscita.
///
/// Vale solo per le fonti che hanno un [EpisodeSource.canonicalUrl], e serve a
/// distinguere il caso in cui il player deve passare alla fonte successiva
/// ("questa non si risolve") dal caso in cui deve mostrare un errore ("il
/// servizio non c'e'"). Sono due cose diverse per l'utente: la prima si
/// risolve da sola, la seconda no.
class SourceResolutionFailure implements Exception {
  const SourceResolutionFailure(this.message, {this.isRetryable = true});

  final String message;
  final bool isRetryable;

  @override
  String toString() => message;
}

/// Operazioni su episodi, fonti e progresso di visione.
///
/// Il contratto e' volutamente corto: quattro operazioni, tutte con un nome che
/// dice cosa fanno senza dire come. Il "come" e' tutto dentro
/// [SupabaseEpisodesRepository], perche' e' l'unica parte che parla con il
/// backend.
abstract interface class EpisodesRepository {
  /// Episodi di un anime, con il progresso e il voto del chiamante.
  Future<List<Episode>> forAnime(String animeId);

  /// Fonti attive di un episodio, dalla piu' alta qualita' in giu'.
  Future<List<EpisodeSource>> sources(String episodeId);

  /// Trasforma l'indirizzo canonico di una fonte in un URL riproducibile.
  ///
  /// Va chiamata al momento della riproduzione e non prima: il risultato porta
  /// una scadenza e vale per una richiesta sola, quindi risolvere tutto
  /// all'apertura della schermata farebbe consumare i token dei provider senza
  /// che nessuno li usi. Per le fonti che hanno gia' un indirizzo
  /// riproducibile non serve chiamarla, e quando serve restituisce
  /// [SourceResolutionFailure] invece di un URL inventato.
  Future<ResolvedSource> resolveSource(String sourceId);

  /// Registra il voto su un episodio. `null` lo cancella.
  Future<double?> rate(String episodeId, double? score);

  /// Il provider da cui chiedere gli episodi di un anime.
  ///
  /// `null` quando l'anime non e' agganciato a nessun provider: in quel caso
  /// non c'e' niente da rileggere.
  Future<EpisodeProviderRef?> providerRef(String animeId);

  /// Allinea gli episodi di un anime al provider adesso.
  ///
  /// Restituisce quanti episodi nuovi ha creato (`0` se nessuno). Non e' un
  /// fallimento che il provider non risponda: a chiamarla e' una schermata che
  /// sta gia' mostrando una lista valida, e un errore di rete non cambia quello
  /// che l'utente vede.
  Future<int> syncEpisodes(String animeId);

  /// Salva a che punto si e' arrivati.
  Future<void> saveProgress(
    String episodeId,
    int currentTime, {
    bool? completed,
  });

  /// Secondi gia' guardati. `null` se non c'e' ancora nessuna riga.
  Future<int?> progress(String episodeId);
}

class SupabaseEpisodesRepository implements EpisodesRepository {
  SupabaseEpisodesRepository(
    this._client, {
    ClientSourceExtractor? clientExtractor,
    ClientEpisodeCounts? episodeCounts,
  })  : _clientExtractor = clientExtractor ?? AnimeUnityExtractor(),
        _episodeCounts = episodeCounts ?? AnimeUnityExtractor();

  final SupabaseClient _client;

  /// Chi risolve le fonti che il backend non puo' (AnimeUnity, dietro
  /// Cloudflare). Iniettabile perche' i test non devono toccare la rete.
  final ClientSourceExtractor _clientExtractor;

  /// Chi sa dire quanti episodi ha AnimeUnity adesso.
  ///
  /// Stessa macchina dell'estrazione ma con un'interfaccia a parte: la
  /// sincronizzazione e' iniettata a parte nei test, dove la si vuole
  /// controllare senza dover fingere anche una risoluzione video.
  final ClientEpisodeCounts _episodeCounts;

  /// Id dell'utente collegato.
  ///
  /// Il fallback e' una failure, non un `null` silenzioso: senza `user_id` una
  /// scrittura del progresso fallirebbe comunque piu' a valle, e fallire qui
  /// dice subito "devi essere collegato" invece di lasciare l'utente a guardare
  /// un player che non salva.
  String get _uid {
    final id = _client.auth.currentUser?.id;
    if (id == null) {
      throw const EpisodesFailure(
        'Devi essere collegato per guardare gli episodi.',
        isRetryable: false,
      );
    }
    return id;
  }

  @override
  Future<List<Episode>> forAnime(String animeId) async {
    try {
      final rows = await _client.rpc(
        'episodes_for_anime',
        params: {'_anime_id': animeId},
      );
      return [
        for (final row in _rows(rows))
          Episode.parse(_map(row)),
      ]..sort((a, b) => a.number.compareTo(b.number));
    } on PostgrestException catch (e) {
      throw _translate(e);
    } on EpisodesFailure {
      rethrow;
    } catch (_) {
      throw const EpisodesFailure(
        'Episodi non raggiungibili. Riprova.',
        isRetryable: true,
      );
    }
  }

  @override
  Future<List<EpisodeSource>> sources(String episodeId) async {
    try {
      final rows = await _client.rpc(
        'episode_sources_list',
        params: {'_episode_id': episodeId},
      );

      return [for (final row in _rows(rows)) EpisodeSource.parse(_map(row))];
    } on PostgrestException catch (e) {
      throw _translate(e);
    } on EpisodesFailure {
      rethrow;
    } catch (_) {
      throw const EpisodesFailure(
        'Fonti di visione non disponibili. Riprova.',
        isRetryable: true,
      );
    }
  }

  @override
  Future<ResolvedSource> resolveSource(String sourceId) async {
    // Il client manda solo l'id. L'indirizzo canonico e' riletto dal backend,
    // perche' se arrivasse da qui la funzione sarebbe un proxy aperto per
    // qualunque URL e non un resolver di fonti del catalogo: chi chiama
    // potrebbe scegliere *quale* fonte risolvere, non *cosa* risolvere.
    try {
      final response = await _client.functions.invoke(
        AppConfig.sourceResolverFunction,
        // `client_extract` dice alla funzione che questa versione dell'app sa
        // risolvere da sola le fonti che il datacenter non puo' (AnimeUnity).
        // Le versioni vecchie non lo mandano e ricevono la risposta di sempre:
        // e' l'unico modo per cambiare forma a una risposta senza rompere chi
        // non e' ancora aggiornato.
        body: {'source_id': sourceId, 'client_extract': true},
      );

      final data = response.data;
      if (data is! Map) {
        throw const SourceResolutionFailure(
          'Il resolver ha risposto in modo inatteso.',
        );
      }

      final row = Map<String, dynamic>.from(response.data as Map);

      // Il backend non puo' risolvere questa fonte (sta dietro Cloudflare) e ha
      // rimandato indietro l'indirizzo canonico perche' la risolva l'app, che
      // ha l'IP residenziale dell'utente. Non e' un errore: e' la risposta
      // giusta per queste fonti.
      if (row['resolution'] == 'client') {
        return await _extractOnDevice(sourceId, row);
      }

      final resolved = ResolvedSource.parse(row);

      if (resolved.resolvedUrl.isEmpty) {
        // Una risposta 200 senza URL non e' un successo: e' un resolver che ha
        // accettato la richiesta e non ha fatto niente. Dare inoltre al player un
        // URL vuoto produrrebbe un errore di rete che parla di DNS, e la causa
        // vera e' qui.
        throw const SourceResolutionFailure('Il resolver non ha restituito un link.');
      }

      return resolved;
    } on SourceResolutionFailure {
      rethrow;
    } on FunctionException catch (e) {
      throw _translateResolution(e);
    } catch (_) {
      throw const SourceResolutionFailure(
        'Risoluzione non riuscita. Riprova.',
      );
    }
  }

  /// Risolve sul telefono una fonte che il backend ha dichiarato non risolvibile.
  ///
  /// La risposta del backend porta solo l'indirizzo canonico e i metadati: il
  /// link effimero lo produce questa estrazione, sul dispositivo, dove Cloudflare
  /// vede l'IP dell'utente invece di quello di un datacenter.
  Future<ResolvedSource> _extractOnDevice(
    String sourceId,
    Map<String, dynamic> row,
  ) async {
    final canonicalUrl = _value(row['canonical_url']);
    if (canonicalUrl == null) {
      throw const SourceResolutionFailure(
          'La fonte non ha un indirizzo da risolvere.');
    }

    final rawEpisode = row['episode_number'];
    final episodeNumber = rawEpisode is int
        ? rawEpisode
        : rawEpisode is num
            ? rawEpisode.toInt()
            : int.tryParse('$rawEpisode');

    if (episodeNumber == null || episodeNumber < 1) {
      throw const SourceResolutionFailure(
          'Numero episodio mancante per questa fonte.');
    }

    final quality = _value(row['quality']);
    final provider = row['provider'];
    final providerSlug = provider is Map ? _value(provider['slug']) : null;

    try {
      return await _clientExtractor.extract(
        sourceId: sourceId,
        canonicalUrl: canonicalUrl,
        episodeNumber: episodeNumber,
        quality: quality,
        providerSlug: providerSlug,
      );
    } on ClientExtractionFailure catch (e) {
      throw SourceResolutionFailure(e.message, isRetryable: e.isRetryable);
    }
  }

  @override
  Future<double?> rate(String episodeId, double? score) async {
    try {
      // La validazione e' dentro la RPC: il client controlla comunque il
      // valore, ma e' il database a dire no, perche' e' l'unico posto dove il
      // passo 0.5 e' garantito per chiunque — compresa una richiesta fatta a
      // mano dal pannello di rete.
      final result = await _client.rpc(
        'episode_rate',
        params: {'_episode_id': episodeId, '_score': score},
      );

      if (result is num) return result.toDouble();
      return null;
    } on PostgrestException catch (e) {
      throw _translate(e);
    } on EpisodesFailure {
      rethrow;
    } catch (_) {
      throw const EpisodesFailure(
        'Voto non registrato. Riprova.',
        isRetryable: true,
      );
    }
  }

  @override
  Future<void> saveProgress(
    String episodeId,
    int currentTime, {
    bool? completed,
  }) async {
    try {
      final row = <String, Object?>{
        'user_id': _uid,
        'episode_id': episodeId,
        // La colonna si chiama `current_seconds` e non `current_time`: quest'ultimo e'
        // una funzione built-in di Postgres, quindi come colonna andrebbe tra
        // apici e ogni client dovrebbe scrivere `select("current_time")`.
        'current_seconds': currentTime,
      };
      // `completed` si scrive solo quando e' noto. Omittinglo del tutto
      // durante i salvataggi periodici evita di scrivere `false` sopra un
      // `true` gia' registrato: l'episodio finito si finisce una volta sola.
      if (completed != null) row['completed'] = completed;

      // La tabella ha `unique (user_id, episode_id)`: senza `onConflict`
      // l'upsert inserirebbe una seconda riga a ogni salvataggio e ogni dieci
      // secondi l'utente si troverebbe decine di copie dello stesso progresso.
      await _client
          .from('watch_progress')
          .upsert(row, onConflict: 'user_id,episode_id');
    } on PostgrestException catch (e) {
      throw _translate(e);
    } on EpisodesFailure {
      rethrow;
    } catch (_) {
      throw const EpisodesFailure(
        'Progresso non salvato.',
        isRetryable: true,
      );
    }
  }

  @override
  Future<int?> progress(String episodeId) async {
    try {
      final rows = await _client
          .from('watch_progress')
          .select('current_seconds')
          .eq('episode_id', episodeId)
          .eq('user_id', _uid)
          .limit(1);

      final first = _rows(rows).firstOrNull;
      if (first == null) return null;

      final value = _map(first)['current_seconds'];
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value);
      return null;
    } on PostgrestException catch (e) {
      throw _translate(e);
    } on EpisodesFailure {
      rethrow;
    } catch (_) {
      throw const EpisodesFailure(
        'Progresso non leggibile. Riprova.',
        isRetryable: true,
      );
    }
  }

  @override
  Future<EpisodeProviderRef?> providerRef(String animeId) async {
    try {
      final rows = await _client.rpc(
        'anime_episode_ref',
        params: {'_anime_id': animeId},
      );

      final first = _rows(rows).firstOrNull;
      if (first == null) return null;

      return EpisodeProviderRef.tryParse(_map(first));
    } on PostgrestException catch (e) {
      throw _translate(e);
    } on EpisodesFailure {
      rethrow;
    } catch (_) {
      throw const EpisodesFailure(
        'Episodi non rileggibili dal provider.',
        isRetryable: true,
      );
    }
  }

  @override
  Future<int> syncEpisodes(String animeId) async {
    // Il conteggio vero lo sa solo il provider: qui si decide *se* chiederlo,
    // non *quanto* vale. Il database rilegge il numero dal client e lo applica
    // entro limiti stretti (vedi 20261012161356_episode_sync.sql).
    final ref = await providerRef(animeId);
    if (ref == null) return 0;

    final count = await _episodeCounts.fetchEpisodeCount(ref.canonicalUrl);
    if (count == null || count <= ref.episodesCount) return 0;

    try {
      final result = await _client.rpc(
        'sync_anime_episodes',
        params: {
          '_anime_id': animeId,
          '_episodes_count': count,
          '_provider_slug': ref.providerSlug,
          '_provider_anime_id': ref.providerAnimeId,
        },
      );

      if (result is num) return result.toInt();
      return 0;
    } on PostgrestException catch (e) {
      throw _translate(e);
    } on EpisodesFailure {
      rethrow;
    } catch (_) {
      throw const EpisodesFailure(
        'Sincronizzazione episodi non riuscita.',
        isRetryable: true,
      );
    }
  }

  List<Object?> _rows(Object? raw) => switch (raw) {
        final List<Object?> list => list,
        _ => const [],
      };

  Map<String, dynamic> _map(Object? row) =>
      row is Map ? Map<String, dynamic>.from(row) : const <String, dynamic>{};

  /// Una stringa non vuota, altrimenti `null`.
  ///
  /// Il corpo della risposta e' JSON non tipato: un campo mancante arriva come
  /// `null` e uno vuoto come `''`, e in entrambi i casi il chiamante vuole
  /// `null` invece di una stringa che poi fallisce piu' avanti.
  String? _value(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Traduce un errore di PostgREST in qualcosa che si puo' mostrare.
  EpisodesFailure _translate(PostgrestException e) {
    const passthrough = {
      '22023', // validazione input: il passo del voto non e' rispettato
      '42501', // permessi
      '28000', // autenticazione
      'P0002', // parametro mancante
      '23503', // riferimento non valido
    };

    if (passthrough.contains(e.code) && e.message.trim().isNotEmpty) {
      return EpisodesFailure(e.message.trim());
    }

    // La RPC non esiste ancora: succede se la migration 027 non e' stata
    // applicata. Vale la pena distinguerlo dal generico "riprova", altrimenti
    // l'utente riprova per sempre un errore che non passa da solo.
    if (e.code == '42883' ||
        e.message.contains('function') && e.message.contains('does not exist')) {
      return const EpisodesFailure(
        'Episodi non ancora attivi. Applica la migration 027.',
      );
    }

    return const EpisodesFailure(
      'Operazione non riuscita. Riprova.',
      isRetryable: true,
    );
  }

  /// Traduce un errore della Edge Function in qualcosa di dicibile.
  ///
  /// La funzione gia' manda messaggi scritti per l'utente, quindi si passa
  /// attraverso quelli invece di rimetterli in "operazione non riuscita":
  /// sostituire "questa fonte non e' attiva" con un generico farebbe sembrare
  /// che il problema sia la rete.
  ///
  /// Il codice di stato serve pero' a una cosa: distinguere il tentativo
  /// ancora sensato dal caso in cui il resolver non esiste proprio. Senza, un
  /// "Questo provider non e' ancora supportato" — che non si risolve riprovando
  /// — diventerebbe indistinguibile da un errore di rete passeggero.
  SourceResolutionFailure _translateResolution(FunctionException e) {
    final status = e.status;
    final serverMessage = _serverMessage(e);

    // Status 0: la richiesta non e' nemmeno arrivata. Il pacchetto solleva
    // `FunctionsFetchException` in questo caso, e non c'e' risposta da
    // interpretare: il messaggio del client HTTP ("Failed host lookup")
    // dice piu' del nulla, ma non e' roba dell'utente.
    if (status == 0) {
      return const SourceResolutionFailure('Risoluzione non riuscita. Riprova.');
    }

    // 401 e 403 non sono ripetibili: il token e' scaduto o non c'e'. Riprovare
    // darebbe lo stesso risultato e l'utente aspetterebbe invano.
    if (status == 401 || status == 403) {
      return const SourceResolutionFailure(
        'Sessione scaduta. Rientra e riprova.',
        isRetryable: false,
      );
    }

    // 404: la fonte non c'e' piu'. Non ripetibile — riprovare non la fa
    // ricomparire.
    if (status == 404) {
      return SourceResolutionFailure(
        serverMessage ?? 'Questa fonte non e\' piu\' disponibile.',
        isRetryable: false,
      );
    }

    // 501: manca l'adapter del provider. Non e' un errore, e' una cosa non
    // finita. Dirlo evita che l'utente provi tre volte una fonte che non puo'
    // funzionare.
    if (status == 501) {
      return SourceResolutionFailure(
        serverMessage ?? 'Questo provider non e\' ancora supportato.',
        isRetryable: false,
      );
    }

    // 400 e 422 sono richieste sbagliate: riformularle non le cambia.
    if (status >= 400 && status < 500) {
      return SourceResolutionFailure(
        serverMessage ?? 'Questa fonte non si puo\' risolvere.',
        isRetryable: false,
      );
    }

    // 5xx: qui il tentativo ha senso, e il fallback automatico verso la
    // fonte successiva e' la risposta giusta invece di mostrare un errore.
    return SourceResolutionFailure(
      serverMessage ?? 'Risoluzione non riuscita. Riprova.',
    );
  }

  /// Il messaggio del server, se c'era, altrimenti `null`.
  ///
  /// Va cercato dentro `details`, non dentro il messaggio dell'eccezione:
  /// quello di `supabase_flutter` descrive lo stato HTTP ("400") e non dice
  /// niente del motivo, mentre il corpo della risposta e' l'unico posto dove la
  /// Edge Function ha scritto cosa e' andato storto.
  String? _serverMessage(FunctionException e) {
    final details = e.details;
    String? text;

    if (details is String) {
      text = details;
    } else if (details is Map) {
      final message = details['error'];
      if (message is String) text = message;
    }

    final trimmed = text?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;

    // Il corpo della risposta e' testo non fidato. Non finisce in un widget
    // come messaggio di errore se c'e' dentro HTML, altrimenti un provider
    // potrebbe far comparire un messaggio che sembra dell'app.
    if (trimmed.contains('<') || trimmed.length > 200) return null;

    return trimmed;
  }
}