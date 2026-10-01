import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/duels.dart';

/// Operazioni sui duelli dentro un gruppo.
///
/// Non esiste una RPC che registri un duello: l inserimento e' una riga diretta
/// in `public.duels`, mentre il backend si occupa solo di scegliere la coppia e
/// di ricalcolare gli Elo. Quindi qui convivono una lettura via RPC e una
/// scrittura via PostgREST.
abstract interface class DuelsRepository {
  /// Prossima coppia proposta, oppure null se il gruppo non ne ha.
  ///
  /// `next_duel_pair` esclude gia' le coppie giocate da questo utente, quindi
  /// restituire la stessa coppia non dovrebbe accadere; il controllo resta
  /// perche' la tabella e' scrivibile in modo diretto e nulla impedisce a due
  /// richieste simultanee di ottenerla insieme.
  Future<DuelPair?> nextPair(String groupId);

  /// Classifica Elo del gruppo, gia' ordinata dal backend.
  Future<List<DuelStanding>> standings(String groupId);

  /// Registra la scelta di un anime fra i due proposti.
  Future<void> play(String groupId, DuelPair pair, String selectedAnimeId);
}

class SupabaseDuelsRepository implements DuelsRepository {
  SupabaseDuelsRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<DuelPair?> nextPair(String groupId) async {
    try {
      final rows = _rows(await _client.rpc(
        'next_duel_pair',
        params: {'_group_id': groupId},
      ));

      if (rows.isEmpty) return null;
      return DuelPair.parse(_map(rows.first));
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (e) {
      if (e is DuelsFailure) rethrow;
      throw const DuelsFailure('Coppia non disponibile. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<List<DuelStanding>> standings(String groupId) async {
    try {
      final rows = _rows(await _client.rpc(
        'duel_elo',
        params: {'_group_id': groupId},
      ));

      // `duel_elo` non distingue "gruppo senza duelli" da "chiamata non
      // riuscita": tornerebbe una lista vuota in entrambi i casi. Il vuoto
      // viene pero' trattato come elenco da mostrare vuoto, e la schermata
      // distingue i due casi dal fatto che la coppia non esiste.
      return [
        for (var i = 0; i < rows.length; i++)
          DuelStanding.parse(_map(rows[i]), position: i + 1),
      ];
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (e) {
      if (e is DuelsFailure) rethrow;
      throw const DuelsFailure('Classifica Elo non disponibile. Riprova.', isRetryable: true);
    }
  }

  @override
  Future<void> play(String groupId, DuelPair pair, String selectedAnimeId) async {
    // Gli stessi controlli del CHECK del database, eseguiti prima della
    // richiesta: `duels_distinct_animes` e `duels_selected_in_pair` farebbero
    // fallire l'inserimento, e un errore tecnico per una scelta impossibile da
    // fare a mano e' solo rumore.
    final error = pair.validate(selectedAnimeId);
    if (error != null) throw error;

    try {
      await _client.from('duels').insert({
        'group_id': groupId,
        // Non viene dalla richiesta ma dall'utente collegato: `duels_user_id`
        // e la RLS controllano che una riga non possa essere attribuita ad
        // altri. Lasciarlo al client significherebbe poter votare per conto
        // altrui ogni volta che la regola cambiasse.
        'user_id': _uid,
        'anime_a_id': pair.animeAId,
        'anime_b_id': pair.animeBId,
        'selected_anime_id': selectedAnimeId,
      });

      // Nessun id restituito e nessun errore se la riga c'e' gia': `duels` non ha
      // vincoli di unicita' sulle coppie (l'esclusione per utente la fa
      // `next_duel_pair` filtrando), quindi l'inserimento va dato per riuscito.
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (_) {
      throw const DuelsFailure('Duello non registrato. Riprova.', isRetryable: true);
    }
  }

  String get _uid {
    final id = _client.auth.currentUser?.id;
    if (id == null) {
      throw const DuelsFailure('Devi essere collegato.', isRetryable: false);
    }
    return id;
  }

  List<Object?> _rows(Object? raw) => switch (raw) {
        final List<Object?> list => list,
        _ => const [],
      };

  Map<String, dynamic> _map(Object? row) =>
      row is Map ? Map<String, dynamic>.from(row) : const {};

  DuelsFailure _translate(PostgrestException e) {
    const passthrough = {
      '42501', // permessi: anche l'eccezione di next_duel_pair
      '28000', // autenticazione
      '23503', // riferimento non valido
      '23514', // check: coppia con due anime uguali o scelta fuori coppia
      'P0002', // non trovato
    };

    if (passthrough.contains(e.code) && e.message.trim().isNotEmpty) {
      return DuelsFailure(e.message.trim());
    }

    if (e.code == null && e.message.contains('row-level security')) {
      return const DuelsFailure('Permessi insufficienti.');
    }

    return const DuelsFailure('Operazione non riuscita. Riprova.', isRetryable: true);
  }
}
