import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/watchlist.dart';

/// Colonne lette da PostgREST.
///
/// `anime:anime_id (...)` e il join con `public.anime`: la sintassi dell alias
/// segue la colonna della chiave esterna, quindi cambiare il nome di
/// `anime_id` romperebbe la query senza errori di compilazione.
const String _select = 'id, group_id, user_id, anime_id, status, current_episode, '
    'is_favorite, created_at, updated_at, '
    'anime:anime_id ( id, title, image_url, episodes, year, genres, status )';

/// Operazioni sulla watchlist personale dentro un gruppo.
///
/// Non esiste una RPC dedicata (a differenza dei gruppi): qui non c'e un ruolo
/// da controllare, il permesso e sulla riga stessa e la RLS garantisce che si
/// possano toccare solo le proprie voci.
abstract interface class WatchlistRepository {
  /// Voci dell utente collegato in un gruppo, con i dati dell anime uniti.
  Future<List<WatchlistEntry>> entries(String groupId);

  /// Totali della watchlist, per le cifre in cima alla schermata.
  Future<WatchlistTotals> totals(String groupId);

  /// Cambia lo stato di un anime, creandolo se non era in watchlist.
  Future<void> setStatus(String groupId, String animeId, WatchStatus status);

  /// Cambia il numero di episodi guardati.
  Future<void> setEpisode(String groupId, String animeId, int episode);

  /// Mette o toglie il contrassegno di preferito.
  Future<void> setFavorite(String groupId, String animeId, bool isFavorite);

  /// Toglie l anime dalla watchlist.
  Future<void> remove(String groupId, String animeId);
}

class SupabaseWatchlistRepository implements WatchlistRepository {
  SupabaseWatchlistRepository(this._client);

  final SupabaseClient _client;

  static const int pageSize = 200;

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
      final rows = await _client
          .from('watchlists')
          .select(_select)
          .eq('group_id', groupId)
          .eq('user_id', _uid)
          .order('updated_at', ascending: false)
          .limit(pageSize);

      return [for (final row in _rows(rows)) WatchlistEntry.parse(_map(row))];
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (e) {
      if (e is WatchlistFailure) rethrow;
      throw const WatchlistFailure('Watchlist non disponibile. Riprova.', isRetryable: true);
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
  Future<void> setStatus(String groupId, String animeId, WatchStatus status) =>
      _write(groupId, animeId, {'status': status.wire}, 'Stato non aggiornato. Riprova.');

  @override
  Future<void> setEpisode(String groupId, String animeId, int episode) {
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
  Future<void> setFavorite(String groupId, String animeId, bool isFavorite) => _write(
        groupId,
        animeId,
        {'is_favorite': isFavorite},
        'Preferito non aggiornato. Riprova.',
      );

  @override
  Future<void> remove(String groupId, String animeId) async {
    try {
      await _client
          .from('watchlists')
          .delete()
          .eq('group_id', groupId)
          .eq('user_id', _uid)
          .eq('anime_id', animeId);
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (_) {
      throw const WatchlistFailure('Rimozione non riuscita. Riprova.', isRetryable: true);
    }
  }

  /// Modifica una voce, creandola se non esiste ancora.
  ///
  /// Prima prova un `update` e solo se non tocca nessuna riga fa un `insert`.
  /// Un `upsert` diretto sarebbe piu' breve ma azzererebbe `current_episode` e
  /// `is_favorite` della riga che sta sostituendo: cambiare stato dopo aver
  /// segnato 20 episodi non deve costare quei 20 episodi.
  Future<void> _write(
    String groupId,
    String animeId,
    Map<String, Object?> patch,
    String failureMessage,
  ) async {
    try {
      final updated = await _client
          .from('watchlists')
          .update(patch)
          .eq('group_id', groupId)
          .eq('user_id', _uid)
          .eq('anime_id', animeId)
          .select('id');

      if (_rows(updated).isNotEmpty) return;

      await _client.from('watchlists').insert({
        'group_id': groupId,
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
