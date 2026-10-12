import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/achievement.dart';

/// Lettura degli obiettivi dell'utente collegato.
///
/// Il catalogo e gli sblocchi sono due tabelle distinte: la prima e' pubblica e
/// statica, la seconda ha una riga per utente e per obiettivo sbloccato. La
/// combinazione avviene qui, non nel database, perche' non serve una vista:
/// sono dodici righe, e due letture le tengono separate come sono.
abstract interface class AchievementsRepository {
  /// Il catalogo visibile, con lo stato di sblocco dell'utente collegato.
  ///
  /// Ordine: prima gli sbloccati (il piu' recente in cima), poi i bloccati in
  /// ordine alfabetico. E' una regola del dato e non una scelta di disegno,
  /// quindi sta qui e non nella schermata.
  Future<List<Achievement>> loadMine();
}

/// Implementazione reale su Supabase.
class SupabaseAchievementsRepository implements AchievementsRepository {
  SupabaseAchievementsRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<Achievement>> loadMine() async {
    // La sessione si controlla prima: senza, PostgREST risponde come anonimo e
    // la RLS restituisce liste vuote invece di un errore, quindi l'utente
    // vedrebbe "nessun obiettivo" al posto di "accedi di nuovo".
    if (_client.auth.currentSession == null) {
      throw const AchievementsFailure('Sessione scaduta. Accedi di nuovo.');
    }

    try {
      final catalog = await _client
          .from('achievements')
          .select('id, code, name, description, icon, requirement, hidden');

      // La RLS limita gia' questa tabella alle righe dell'utente: non serve
      // filtrare per id.
      final unlocked = await _client
          .from('user_achievements')
          .select('achievement_id, unlocked_at');

      final unlockedByAchievement = <String, DateTime>{
        for (final row in unlocked)
          '${row['achievement_id']}':
              DateTime.tryParse('${row['unlocked_at']}')?.toLocal() ??
                  DateTime.now(),
      };

      final achievements = catalog
          .map(Achievement.parse)
          .map((achievement) => achievement
              .withUnlock(unlockedByAchievement[achievement.id]))
          .where((achievement) => achievement.isVisible)
          .toList();

      _sort(achievements);
      return achievements;
    } on PostgrestException catch (e) {
      // Permessi e sessione non si risolvono riprovando: ripetere la richiesta
      // produrrebbe sempre lo stesso rifiuto, e l'utente vedrebbe uno spinner
      // invece del motivo.
      if (e.code == '42501') {
        throw const AchievementsFailure('Non hai i permessi per vedere gli obiettivi.');
      }
      if (e.code == '28000') {
        throw const AchievementsFailure('Sessione scaduta. Accedi di nuovo.');
      }
      throw const AchievementsFailure('Obiettivi non disponibili. Riprova.', isRetryable: true);
    } catch (_) {
      throw const AchievementsFailure('Obiettivi non disponibili. Riprova.', isRetryable: true);
    }
  }

  /// Sbloccati prima (piu' recenti in cima), poi i bloccati in ordine di nome.
  void _sort(List<Achievement> achievements) {
    achievements.sort((a, b) {
      if (a.isUnlocked != b.isUnlocked) return a.isUnlocked ? -1 : 1;
      if (a.isUnlocked) {
        return b.unlockedAt!.compareTo(a.unlockedAt!);
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }
}
