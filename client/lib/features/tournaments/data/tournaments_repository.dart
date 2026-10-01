import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/tournaments.dart';

/// Colonne dei tornei.
///
/// `creator:created_by` e `champion:champion_anime_id` sono join con altre
/// tabelle: l'alias segue il nome della colonna della chiave esterna, quindi
/// rinominare la colonna romperebbe la query senza errori di compilazione.
const String _tournamentSelect = 'id, group_id, name, status, created_by, bracket_size, '
    'champion_anime_id, created_at, completed_at, '
    'creator:created_by ( username ), '
    'champion:champion_anime_id ( id, title, image_url )';

/// Colonne degli scontri, con i due contendenti uniti.
///
/// Il vincitore non si unisce: e' sempre uno dei due contendenti, quindi
/// arriva gia' come id e i dati li si sono gia' letti.
const String _matchSelect = 'id, tournament_id, round_number, match_number, '
    'anime_a_id, anime_b_id, winner_anime_id, status, next_slot, finished_at, '
    'anime_a:anime_a_id ( id, title, image_url ), '
    'anime_b:anime_b_id ( id, title, image_url )';

/// Operazioni sui tornei.
///
/// Quasi tutto passa da RPC: `tournaments` e `tournament_matches` non hanno
/// nessuna policy di scrittura, quindi non esiste un percorso PostgREST per
/// creare un bracket o votare. Solo le letture sono query dirette.
abstract interface class TournamentsRepository {
  /// Tornei di un gruppo, dal piu' recente.
  Future<List<Tournament>> list(String groupId);

  /// Tabellone completo: torneo e partite di tutti i turni.
  Future<TournamentBracket> bracket(String tournamentId);

  /// Voti raccolti sugli scontri indicati.
  Future<List<TournamentVote>> votes(List<String> matchIds);

  /// Classifica del torneo da `tournament_standings`.
  Future<List<TournamentStanding>> standings(String tournamentId);

  /// Crea il torneo e genera il bracket.
  Future<Tournament> create({
    required String groupId,
    required String name,
    required List<String> animeIds,
  });

  /// Vota uno scontro.
  ///
  /// true se il voto ha chiuso lo scontro: quando tutti i membri hanno votato,
  /// la RPC risolve la partita e la fa avanzare, quindi il tabellone va
  /// riletto.
  Future<bool> vote({required String matchId, required String animeId});

  /// Elimina un torneo (solo admin).
  Future<void> delete(String tournamentId);

  /// Id dell'utente collegato.
  ///
  /// Serve a distinguere il proprio voto dagli altri: la RLS permette ai membri
  /// del gruppo di leggere tutti i voti, quindi il client non puo' dedurre dal
  /// solo elenco chi e' lui.
  String get currentUserId;
}

class SupabaseTournamentsRepository implements TournamentsRepository {
  SupabaseTournamentsRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<Tournament>> list(String groupId) async {
    try {
      final rows = await _client
          .from('tournaments')
          .select(_tournamentSelect)
          .eq('group_id', groupId)
          // Ordinamento del server: sul client i tornei arriverebbero in ordine
          // sparso e la lista cambierebbe posizione fra un render e l'altro.
          .order('created_at', ascending: false)
          .limit(50);

      return [for (final row in _rows(rows)) Tournament.parse(_map(row))];
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (e) {
      if (e is TournamentsFailure) rethrow;
      throw const TournamentsFailure('Tornei non disponibili. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<TournamentBracket> bracket(String tournamentId) async {
    try {
      final tournamentRows = _rows(
        await _client
            .from('tournaments')
            .select(_tournamentSelect)
            .eq('id', tournamentId)
            .limit(1),
      );

      // Zero righe significa id sbagliato o torneo gia' cancellato: nessuna
      // policy consente a un non membro di leggerlo, quindi non arriva un
      // errore ma una lista vuota.
      if (tournamentRows.isEmpty) {
        throw const TournamentsFailure('Torneo non trovato.');
      }

      final tournament = Tournament.parse(_map(tournamentRows.first));

      final matchRows = await _client
          .from('tournament_matches')
          .select(_matchSelect)
          .eq('tournament_id', tournamentId)
          .order('round_number')
          .order('match_number');

      return TournamentBracket.parse(
        tournament: tournament,
        matchRows: [for (final row in _rows(matchRows)) _map(row)],
      );
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (e) {
      if (e is TournamentsFailure) rethrow;
      throw const TournamentsFailure('Tabellone non disponibile. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<List<TournamentVote>> votes(List<String> matchIds) async {
    if (matchIds.isEmpty) return const [];

    try {
      // Un solo `.in` con tutti gli scontri: una richiesta per scontro sul
      // tabellone di 16 partite sarebbe 16 viaggi per la stessa schermata.
      final rows = await _client
          .from('tournament_votes')
          .select('match_id, user_id, anime_id')
          .inFilter('match_id', matchIds);

      return [for (final row in _rows(rows)) TournamentVote.parse(_map(row))];
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (e) {
      if (e is TournamentsFailure) rethrow;
      throw const TournamentsFailure('Voti non disponibili. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<List<TournamentStanding>> standings(String tournamentId) async {
    try {
      final rows = _rows(await _client.rpc(
        'tournament_standings',
        params: {'_tournament_id': tournamentId},
      ));

      return [for (final row in rows) TournamentStanding.parse(_map(row))];
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (e) {
      if (e is TournamentsFailure) rethrow;
      throw const TournamentsFailure('Classifica non disponibile. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<Tournament> create({
    required String groupId,
    required String name,
    required List<String> animeIds,
  }) async {
    final nameError = TournamentValidators.nameError(name);
    if (nameError != null) throw TournamentsFailure(nameError);

    final participantsError = TournamentValidators.participantsError(animeIds);
    if (participantsError != null) throw TournamentsFailure(participantsError);

    try {
      // La RPC restituisce la riga `tournaments` completa, quindi il nuovo
      // torneo si puo' mostrare subito senza rileggerlo.
      final row = await _client.rpc(
        'create_tournament',
        params: {'_group_id': groupId, '_name': name.trim(), '_anime_ids': animeIds},
      );

      final map = _map(row);
      if (map['id'] == null) {
        throw const TournamentsFailure('Torneo non creato.');
      }

      return Tournament.parse(map);
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (e) {
      if (e is TournamentsFailure) rethrow;
      throw const TournamentsFailure('Torneo non creato. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<bool> vote({required String matchId, required String animeId}) async {
    try {
      final result = await _client.rpc(
        'cast_tournament_vote',
        params: {'_match_id': matchId, '_anime_id': animeId},
      );

      // La RPC restituisce true solo se il suo voto ha chiuso lo scontro: un
      // false significa che mancano ancora i voti degli altri membri.
      return result == true;
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (e) {
      if (e is TournamentsFailure) rethrow;
      throw const TournamentsFailure('Voto non registrato. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<void> delete(String tournamentId) async {
    try {
      await _client.rpc('delete_tournament', params: {'_tournament_id': tournamentId});
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (_) {
      throw const TournamentsFailure('Torneo non eliminato. Riprova.', isRetryable: true);
    }
  }

  @override
  String get currentUserId => _client.auth.currentUser?.id ?? '';

  List<Object?> _rows(Object? raw) => switch (raw) {
        final List<Object?> list => list,
        _ => const [],
      };

  Map<String, dynamic> _map(Object? row) =>
      row is Map ? Map<String, dynamic>.from(row) : const {};

  TournamentsFailure _translate(PostgrestException e) {
    const passthrough = {
      '42501', // permessi
      '28000', // autenticazione
      '22023', // parametri non validi: nome troppo lungo, taglia, voto fuori coppia
      'P0002', // non trovato
    };

    if (passthrough.contains(e.code) && e.message.trim().isNotEmpty) {
      return TournamentsFailure(e.message.trim());
    }

    if (e.code == null && e.message.contains('row-level security')) {
      return const TournamentsFailure('Permessi insufficienti.');
    }

    return const TournamentsFailure('Operazione non riuscita. Riprova.', isRetryable: true);
  }
}