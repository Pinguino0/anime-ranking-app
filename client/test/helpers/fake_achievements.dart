import 'package:animerank/features/achievements/data/achievements_repository.dart';
import 'package:animerank/features/achievements/domain/achievement.dart';

/// Repository finto per i test degli obiettivi.
///
/// Il controller e la schermata non devono passare da Supabase: qui si decide
/// direttamente cosa torna, cosi' si verifica il comportamento dell'interfaccia
/// (sbloccati, bloccati, vuoto, errore) senza un database.
class FakeAchievementsRepository implements AchievementsRepository {
  FakeAchievementsRepository({List<Achievement>? achievements})
      : achievements = achievements ?? defaultAchievements();

  List<Achievement> achievements;

  AchievementsFailure? loadFailure;
  int loadCalls = 0;

  @override
  Future<List<Achievement>> loadMine() async {
    loadCalls++;
    final failure = loadFailure;
    if (failure != null) throw failure;
    return achievements;
  }
}

/// Obiettivo di comodo per i test.
Achievement buildAchievement({
  String id = 'a1',
  String code = 'first_vote',
  String name = 'Primo voto',
  String description = 'Hai votato il tuo primo anime.',
  String icon = '⭐',
  String requirement = 'Vota 1 anime',
  bool hidden = false,
  DateTime? unlockedAt,
}) =>
    Achievement(
      id: id,
      code: code,
      name: name,
      description: description,
      icon: icon,
      requirement: requirement,
      hidden: hidden,
      unlockedAt: unlockedAt,
    );

/// Un catalogo minimo: un obiettivo sbloccato e uno ancora bloccato.
List<Achievement> defaultAchievements() => [
      buildAchievement(
        id: 'a1',
        name: 'Primo voto',
        unlockedAt: DateTime(2026, 2, 1),
      ),
      buildAchievement(
        id: 'a2',
        code: 'ten_votes',
        name: 'Dieci voti',
        requirement: 'Vota 10 anime',
      ),
    ];
