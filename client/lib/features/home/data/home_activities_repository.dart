import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/friend_activity.dart';

/// Feed di cosa hanno fatto i membri dei gruppi dell'utente.
///
/// E' l'unica cosa social della home che non esisteva: la tabella `activities`
/// e' gia' popolata dai trigger del database per voto, watchlist, episodi e
/// preferiti, quindi il feed si ricava da dati reali invece di un sistema
/// nuovo. La home lo legge per la sezione "Attivita' degli amici".
abstract interface class HomeActivitiesRepository {
  /// Le ultime attivita' degli altri membri dei gruppi in [groupIds].
  ///
  /// [forUserId] e' l'utente collegato: le sue azioni non gli vengono
  /// rimandate indietro. Vuoto quando l'utente non e' in nessun gruppo.
  Future<List<FriendActivity>> friendActivity({
    required List<String> groupIds,
    required String forUserId,
    int limit = 20,
  });
}

/// Implementazione reale su Supabase.
class SupabaseHomeActivitiesRepository implements HomeActivitiesRepository {
  SupabaseHomeActivitiesRepository(this._client);

  final SupabaseClient _client;

  /// Colonne lette in una sola richiesta.
  ///
  /// I due `embed` risolvono le chiavi esterne di `activities` verso `profiles`
  /// (chi ha fatto l'azione) e verso `anime` (su cosa): farlo in una query sola
  /// evita una lettura per riga, che su venti righe di feed sarebbe il classico
  /// N+1.
  static const String _select =
      'id, type, group_id, user_id, anime_id, metadata, created_at, '
      'profile:user_id ( username, avatar_url ), '
      'anime:anime_id ( id, title, title_it, image_url )';

  @override
  Future<List<FriendActivity>> friendActivity({
    required List<String> groupIds,
    required String forUserId,
    int limit = 20,
  }) async {
    if (groupIds.isEmpty) return const [];

    try {
      final rows = await _client
          .from('activities')
          .select(_select)
          .inFilter('group_id', groupIds)
          .neq('user_id', forUserId)
          .order('created_at', ascending: false)
          .limit(limit);

      // Le attivita' senza anime (ingressi, obiettivi) non hanno un poster da
      // mostrare e `tryParse` le scarta da solo: il filtro e' in Dart perche'
      // `anime_id` nullo e' la stessa cosa di "riga non adatta a questa riga".
      final activities = <FriendActivity>[];
      for (final raw in rows) {
        final parsed = FriendActivity.tryParse(Map<String, dynamic>.from(raw));
        if (parsed != null) activities.add(parsed);
      }
      return activities;
    } on PostgrestException catch (e) {
      throw _translate(e);
    } catch (e) {
      if (e is HomeFailure) rethrow;
      throw const HomeFailure(
        'Attività non disponibili. Riprova.',
        isRetryable: true,
      );
    }
  }

  HomeFailure _translate(PostgrestException e) {
    if (e.code == '42501' && e.message.trim().isNotEmpty) {
      return HomeFailure(e.message.trim());
    }
    if (e.code == null && e.message.contains('row-level security')) {
      return const HomeFailure('Permessi insufficienti.');
    }
    return const HomeFailure(
      'Attività non disponibili. Riprova.',
      isRetryable: true,
    );
  }
}
