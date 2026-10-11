import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/watchlist.dart';

/// Colonne lette da PostgREST.
///
/// `anime:anime_id (...)` e il join con `public.anime`: la sintassi dell alias
/// segue la colonna della chiave esterna, quindi cambiare il nome di
/// `anime_id` romperebbe la query senza errori di compilazione.
const String _select = 'id, group_id, user_id, anime_id, status, current_episode, '
    'is_favorite, message, created_at, updated_at, '
    'anime:anime_id ( id, title, title_it, image_url, episodes, year, genres, status ), '
    'profile:user_id ( username )';

/// Colonne della watchlist personale: identiche a [_select] tranne `group_id`,
/// che su `personal_watchlist` non esiste. Chiedere `group_id` qui farebbe
/// fallire il select con un errore di colonna sconosciuta.
const String _personalSelect = 'id, user_id, anime_id, status, current_episode, '
    'is_favorite, created_at, updated_at, '
    'anime:anime_id ( id, title, title_it, image_url, episodes, year, genres, status )';

/// Operazioni sulla watchlist: personale e di gruppo.
///
/// Non esiste una RPC dedicata (a differenza dei gruppi): qui non c'e un ruolo
/// da controllare, il permesso e sulla riga stessa e la RLS garantisce che si
/// possano toccare solo le proprie voci.
///
/// Due tabelle, un solo vocabolario: `groupId` null significa **watchlist
/// personale** (`personal_watchlist`), un id di gruppo significa la lista
/// condivisa del gruppo (`watchlists`).
abstract interface class WatchlistRepository {
  /// Id dell'utente collegato.
  ///
  /// Esposto perche' la scheda anime deve escludere se stessa dall'elenco dei
  /// destinatari di un consiglio: non ci si consiglia un anime da soli.
  String get currentUserId;

  /// Tutte le voci di un gruppo, con i dati dell anime e di chi le ha messe.
  ///
  /// La lista di gruppo e' "consigliata da tutti": comprende le voci di ogni
  /// membro, non solo le proprie. `WatchlistEntry.userId` dice di chi e' la
  /// voce e `message` l'eventuale consiglio scritto.
  Future<List<WatchlistEntry>> entries(String groupId);

  /// Voci della watchlist personale dell'utente collegato.
  ///
  /// E' la sorgente di "La mia lista": niente gruppi, niente condivisione. La
  /// RLS limita comunque la lettura alle righe proprie.
  Future<List<WatchlistEntry>> personalEntries();

  /// Totali della watchlist di gruppo, per le cifre in cima alla schermata.
  Future<WatchlistTotals> totals(String groupId);

  /// Cambia lo stato di un anime, creandolo se non era in watchlist.
  ///
  /// `groupId == null` scrive nella watchlist personale, altrimenti in quella
  /// del gruppo indicato.
  Future<void> setStatus(String? groupId, String animeId, WatchStatus status);

  /// Cambia il numero di episodi guardati.
  Future<void> setEpisode(String? groupId, String animeId, int episode);

  /// Mette o toglie il contrassegno di preferito.
  Future<void> setFavorite(String? groupId, String animeId, bool isFavorite);

  /// Toglie l anime dalla watchlist.
  Future<void> remove(String? groupId, String animeId);

  /// Consigli di visione registrati nel gruppo, dal piu' recente.
  Future<List<AnimeRecommendation>> recommendations(String groupId);

  /// Registra un consiglio: a tutto il gruppo (`toUserId == null`) o a una
  /// persona sola.
  ///
  /// In entrambi i casi il backend fa entrare l'anime nella watchlist del
  /// gruppo; il consiglio "a persona" genera anche una notifica. Il client non
  /// scrive la watchlist da se': lo fa il trigger, cosi' il comportamento e'
  /// lo stesso anche se il consiglio arriva da un altro client.
  Future<void> recommend({
    required String groupId,
    required String animeId,
    String? toUserId,
    String? message,
  });
}

class SupabaseWatchlistRepository implements WatchlistRepository {
  SupabaseWatchlistRepository(this._client);

  final SupabaseClient _client;

  static const int pageSize = 200;

  @override
  String get currentUserId => _client.auth.currentUser?.id ?? '';

  String get _uid {
    final id = _client.auth.currentUser?.id;
    if (id == null) {
      throw const WatchlistFailure('Devi essere collegato.', isRetryable: false);
    }
    return id;
  }

  @override
  Future<List<WatchlistEntry>> entries(String groupId) async {
    try {
      // Tutte le voci del gruppo, non solo le proprie: la lista di gruppo e'
      // "consigliata da tutti", quindi il filtro per utente e' volutamente
      // assente. La RLS lascia comunque leggere solo ai membri del gruppo.
      final rows = await _client
          .from('watchlists')
          .select(_select)
          .eq('group_id', groupId)
          .order('updated_at', ascending: false)
          .limit(pageSize);

      return [
        for (final row in _rows(rows))
          WatchlistEntry.parse(_map(row), mineId: _uid),
      ];
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (e) {
      if (e is WatchlistFailure) rethrow;
      throw const WatchlistFailure('Watchlist non disponibile. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<List<WatchlistEntry>> personalEntries() async {
    try {
      // La lista personale non ha gruppo: si legge solo per utente. Senza il
      // filtro la RLS lascerebbe comunque passare solo le righe proprie, ma
      // esplicito l'utente per non dipendere da quello.
      final rows = await _client
          .from('personal_watchlist')
          .select(_personalSelect)
          .eq('user_id', _uid)
          .order('updated_at', ascending: false)
          .limit(pageSize);

      return [
        for (final row in _rows(rows))
          // La lista personale e' per definizione propria: `mineId: _uid`
          // rende `isMine` vero anche se un giorno il filtro sparisse.
          WatchlistEntry.parse(_map(row), mineId: _uid),
      ];
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (e) {
      if (e is WatchlistFailure) rethrow;
      throw const WatchlistFailure('Lista non disponibile. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<WatchlistTotals> totals(String groupId) async {
    try {
      final result = await _client.rpc(
        'personal_stats',
        params: {'_group_id': groupId, '_user_id': _uid},
      );

      // Come per `group_stats`: il backend avvolge la query in un controllo di
      // appartenenza, quindi un non membro riceve una lista vuota e non un
      // errore. Una pagina di zeri sarebbe un'informazione falsa.
      if (result is List && result.isEmpty) {
        throw const WatchlistFailure('Non sei membro di questo gruppo.');
      }

      final map = result is List ? result.first : result;
      if (map is! Map) {
        throw const WatchlistFailure('Statistiche non riconosciute.');
      }

      return WatchlistTotals.parse(Map<String, dynamic>.from(map));
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (e) {
      if (e is WatchlistFailure) rethrow;
      throw const WatchlistFailure('Statistiche non disponibili. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<void> setStatus(String? groupId, String animeId, WatchStatus status) =>
      _write(groupId, animeId, {'status': status.wire}, 'Stato non aggiornato. Riprova.');

  @override
  Future<void> setEpisode(String? groupId, String animeId, int episode) {
    final error = WatchlistValidators.episodeError(episode: episode);
    if (error != null) {
      throw WatchlistFailure(error);
    }

    return _write(
      groupId,
      animeId,
      {'current_episode': episode},
      'Episodi non salvati. Riprova.',
    );
  }

  @override
  Future<void> setFavorite(String? groupId, String animeId, bool isFavorite) => _write(
        groupId,
        animeId,
        {'is_favorite': isFavorite},
        'Preferito non aggiornato. Riprova.',
      );

  @override
  Future<void> remove(String? groupId, String animeId) async {
    try {
      final query = _client
          .from(_tableFor(groupId))
          .delete()
          .eq('user_id', _uid)
          .eq('anime_id', animeId);

      // `personal_watchlist` non ha la colonna `group_id`: filtrarla farebbe
      // fallire la delete con "colonna sconosciuta".
      await (groupId == null ? query : query.eq('group_id', groupId));
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (_) {
      throw const WatchlistFailure('Rimozione non riuscita. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<List<AnimeRecommendation>> recommendations(String groupId) async {
    try {
      final rows = await _client
          .from('anime_recommendations')
          .select(
            'id, group_id, anime_id, from_user_id, to_user_id, message, created_at, '
            'from_profile:from_user_id ( username ), '
            'to_profile:to_user_id ( username )',
          )
          .eq('group_id', groupId)
          .order('created_at', ascending: false)
          .limit(pageSize);

      return [
        for (final row in _rows(rows)) AnimeRecommendation.parse(_map(row)),
      ];
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (e) {
      if (e is WatchlistFailure) rethrow;
      throw const WatchlistFailure('Consigli non disponibili. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<void> recommend({
    required String groupId,
    required String animeId,
    String? toUserId,
    String? message,
  }) async {
    final trimmed = message?.trim();

    try {
      await _client.from('anime_recommendations').insert({
        'group_id': groupId,
        'from_user_id': _uid,
        'anime_id': animeId,
        'to_user_id': toUserId,
        // Un messaggio vuoto e' come non averlo scritto: cosi' il check sul
        // database resta pulito e la notifica non mostra una riga vuota.
        'message': (trimmed == null || trimmed.isEmpty) ? null : trimmed,
      });
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (_) {
      throw const WatchlistFailure('Consiglio non inviato. Riprova.', isRetryable: true);
    }
  }

  /// Tabella su cui scrivere: personale quando non c'e un gruppo.
  String _tableFor(String? groupId) =>
      groupId == null ? 'personal_watchlist' : 'watchlists';  /// Modifica una voce, creandola se non esiste ancora.
  ///
  /// Prima prova un `update` e solo se non tocca nessuna riga fa un `insert`.
  /// Un `upsert` diretto sarebbe piu' breve ma azzererebbe `current_episode` e
  /// `is_favorite` della riga che sta sostituendo: cambiare stato dopo aver
  /// segnato 20 episodi non deve costare quei 20 episodi.
  Future<void> _write(
    String? groupId,
    String animeId,
    Map<String, Object?> patch,
    String failureMessage,
  ) async {
    final table = _tableFor(groupId);

    try {
      var filter = _client
          .from(table)
          .update(patch)
          .eq('user_id', _uid)
          .eq('anime_id', animeId);

      // La watchlist personale non ha il gruppo: il filtro esiste solo quando
      // la riga sta in `watchlists`.
      if (groupId != null) filter = filter.eq('group_id', groupId);

      final updated = await filter.select('id');

      if (_rows(updated).isNotEmpty) return;

      await _client.from(table).insert({
        // `group_id` solo per la watchlist di gruppo: l'elemento null-aware
        // omette la chiave quando e' null.
        'group_id': ?groupId,
        'user_id': _uid,
        'anime_id': animeId,
        // Solo i valori richiesti: gli altri restano ai default della tabella
        // (`planned`, 0 episodi, non preferito).
        ...patch,
      });
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (_) {
      throw WatchlistFailure(failureMessage, isRetryable: true);
    }
  }

  /// Normalizza una risposta PostgREST in lista di righe.
  ///
  /// Il tipo statico e dinamico e una versione della libreria puo' consegnare
  /// `null` invece di `[]`: senza questo, iterare su una lista vuota
  /// fallirebbe con un errore di tipo letto come "server assente".
  List<Object?> _rows(Object? raw) => switch (raw) {
        final List<Object?> list => list,
        _ => const [],
      };

  Map<String, dynamic> _map(Object? row) =>
      row is Map ? Map<String, dynamic>.from(row) : const {};

  WatchlistFailure _translate(PostgrestException e) {
    const passthrough = {
      '22023', // validazione input: episodi oltre il totale
      '42501', // permessi
      '28000', // autenticazione
      'P0002', // non trovato
      '23503', // riferimento non valido
      '23505', // duplicato
    };

    if (passthrough.contains(e.code) && e.message.trim().isNotEmpty) {
      return WatchlistFailure(e.message.trim());
    }

    if (e.code == null && e.message.contains('row-level security')) {
      return const WatchlistFailure('Permessi insufficienti.');
    }

    return const WatchlistFailure('Operazione non riuscita. Riprova.', isRetryable: true);
  }
}
