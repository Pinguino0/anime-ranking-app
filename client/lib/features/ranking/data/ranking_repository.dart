import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/ranking.dart';

/// Operazioni di classifica su un gruppo.
abstract interface class RankingRepository {
  /// Classifica principale, gia' pesata e gia' ordinata dal backend.
  ///
  /// Paginated perche' un gruppo con molti membri puo' avere centinaia di
  /// anime votati: portarli tutti in memoria sul telefono costerebbe piu' di
  /// quanto vale, e la classifica si consulta per leggere le prime posizioni.
  Future<List<RankingEntry>> ranking(
    String groupId, {
    int limit,
    int offset,
  });

  /// Una delle classifiche speciali.
  Future<List<SpecialRankingEntry>> special(
    String groupId,
    SpecialRankingKind kind, {
    int limit,
  });

  /// Totali del gruppo: membri, anime votati, media, generi piu' votati.
  Future<GroupStats> stats(String groupId);

  /// Registra il voto dell'utente su un anime.
  ///
  /// Scrive una riga in `ratings`, che la RLS gia' limita all'utente collegato
  /// e ai gruppi di cui e' membro. Non serve una funzione dedicata come per i
  /// gruppi: qui non c'e' un ruolo da controllare, il vincolo e' sulla riga
  /// stessa.
  Future<void> rate(String groupId, String animeId, double score);
}

class SupabaseRankingRepository implements RankingRepository {
  SupabaseRankingRepository(this._client);

  final SupabaseClient _client;

  /// Quante righe chiedere per schermata.
  static const int pageSize = 50;

  String get _uid {
    final id = _client.auth.currentUser?.id;
    if (id == null) {
      throw const RankingFailure('Devi essere collegato.', isRetryable: false);
    }
    return id;
  }

  @override
  Future<List<RankingEntry>> ranking(
    String groupId, {
    int limit = pageSize,
    int offset = 0,
  }) async {
    try {
      final rows = await _client.rpc(
        'group_ranking',
        params: {
          '_group_id': groupId,
          '_limit': limit,
          '_offset': offset,
        },
      );

      return [for (final row in _rows(rows)) RankingEntry.parse(_map(row))];
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (_) {
      throw const RankingFailure('Classifica non disponibile. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<List<SpecialRankingEntry>> special(
    String groupId,
    SpecialRankingKind kind, {
    int limit = 20,
  }) async {
    try {
      final rows = await _client.rpc(
        'special_rankings',
        params: {
          '_group_id': groupId,
          '_kind': kind.wire,
          '_limit': limit,
        },
      );

      return [
        for (final row in _rows(rows))
          SpecialRankingEntry.parse(_map(row), kind: kind),
      ];
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (_) {
      throw const RankingFailure('Classifica non disponibile. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<GroupStats> stats(String groupId) async {
    try {
      final result = await _client.rpc('group_stats', params: {'_group_id': groupId});

      // Il backend avvolve tutto in `from (select 1) where is_group_member(...)`,
      // quindi per un non membro arriva una lista vuota invece di un errore.
      // Dire "non sei membro" e' piu' utile di mostrare una pagina di zeri.
      if (result is List && result.isEmpty) {
        throw const RankingFailure('Non sei membro di questo gruppo.');
      }

      final map = result is List ? result.first : result;
      if (map is! Map) {
        throw const RankingFailure('Statistiche non riconosciute.');
      }

      return GroupStats.parse(Map<String, dynamic>.from(map));
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (e) {
      if (e is RankingFailure) rethrow;
      throw const RankingFailure('Statistiche non disponibili. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<void> rate(String groupId, String animeId, double score) async {
    // Controllo identico al CHECK `ratings_score_valid`: e' una riga di
    // codice, e il backend risponderebbe comunque rifiutando.
    if (!RatingValidators.isValid(score)) {
      throw RankingFailure(RatingValidators.error(score)!);
    }

    try {
      await _client.from('ratings').upsert(
        {
          'group_id': groupId,
          'anime_id': animeId,
          'user_id': _uid,
          'score': score,
        },
        // La tabella ha un unique su (group_id, user_id, anime_id). Senza dire
        // quali colonne lo compongono PostgREST non trova nulla da
        // aggiornare e prova a inserire una seconda riga, che il vincolo
        // rifiuta: e' l'errore che si manifesta come "23505 duplicato" quando
        // in realta' si voleva solo cambiare il voto.
        onConflict: 'group_id,user_id,anime_id',
      );
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (_) {
      throw const RankingFailure('Voto non registrato. Riprova.', isRetryable: true);
    }
  }

  /// Normalizza la risposta di una funzione che "returns table".
  ///
  /// PostgREST restituisce una lista di oggetti, ma il tipo statico e' dinamico
  /// e una versione della libreria puo' consegnare `null` invece di `[]`.
  /// Iterare su un valore che non e' una lista fallirebbe con un errore di tipo
  /// che l'utente leggerebbe come "server assente".
  List<Object?> _rows(Object? raw) => switch (raw) {
        final List<Object?> list => list,
        _ => const [],
      };

  Map<String, dynamic> _map(Object? row) =>
      row is Map ? Map<String, dynamic>.from(row) : const {};

  RankingFailure _translate(PostgrestException e) {
    const passthrough = {
      '22023', // validazione input
      '42501', // permessi
      '28000', // autenticazione
      'P0002', // non trovato
      '23503', // riferimento non valido
      '23505', // duplicato
    };

    if (passthrough.contains(e.code) && e.message.trim().isNotEmpty) {
      return RankingFailure(e.message.trim());
    }

    if (e.code == null && e.message.contains('row-level security')) {
      return const RankingFailure('Permessi insufficienti.');
    }

    return const RankingFailure('Operazione non riuscita. Riprova.', isRetryable: true);
  }
}
