import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/episode.dart';

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

  /// Registra il voto su un episodio. `null` lo cancella.
  Future<double?> rate(String episodeId, double? score);

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
  SupabaseEpisodesRepository(this._client);

  final SupabaseClient _client;

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

  List<Object?> _rows(Object? raw) => switch (raw) {
        final List<Object?> list => list,
        _ => const [],
      };

  Map<String, dynamic> _map(Object? row) =>
      row is Map ? Map<String, dynamic>.from(row) : const <String, dynamic>{};

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
}