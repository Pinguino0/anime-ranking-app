import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/app_retry.dart';
import '../data/achievements_repository.dart';
import '../domain/achievement.dart';

/// Repository degli obiettivi.
final achievementsRepositoryProvider = Provider<AchievementsRepository>((ref) {
  throw StateError('achievementsRepositoryProvider non e stato inizializzato.');
});

/// Obiettivi dell'utente collegato.
///
/// Non c'e' un metodo di modifica: gli sblocchi li decide il database con i
/// suoi trigger, quindi l'app li legge e basta. Da qui l'assenza di un
/// `unlock` che sarebbe una scorciatoia per barare.
class AchievementsController extends AsyncNotifier<List<Achievement>> {
  @override
  Future<List<Achievement>> build() =>
      ref.watch(achievementsRepositoryProvider).loadMine();

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

final achievementsProvider =
    AsyncNotifierProvider<AchievementsController, List<Achievement>>(
  AchievementsController.new,
  retry: appRetry,
);
