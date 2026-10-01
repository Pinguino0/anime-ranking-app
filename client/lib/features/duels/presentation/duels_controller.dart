import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/app_retry.dart';
import '../data/duels_repository.dart';
import '../domain/duels.dart';

final duelsRepositoryProvider = Provider<DuelsRepository>((ref) {
  throw StateError('duelsRepositoryProvider non e stato inizializzato.');
});

/// Coppia attualmente proposta all utente.
///
/// Nullable perche' `next_duel_pair` puo' non restituire righe: un gruppo con
/// un solo anime votato non ha niente da mettere in gara, e la schermata deve
/// poterlo dire senza trattarlo come errore.
class DuelPairController extends AsyncNotifier<DuelPair?> {
  DuelPairController(this.groupId);

  final String groupId;

  @override
  Future<DuelPair?> build() =>
      ref.watch(duelsRepositoryProvider).nextPair(groupId);

  /// Rilettura dopo una scelta.
  ///
  /// Invalidare da se stessi provider invece di scrivere lo stato a mano:
  /// quando l utente torna sul tab del duello e' la stessa istanza che rifa la
  /// richiesta, quindi non serve tenere due copie della coppia corrente.
  Future<void> next() async {
    ref.invalidateSelf();
    await future;
  }
}

final duelPairProvider =
    AsyncNotifierProvider.family<DuelPairController, DuelPair?, String>(
  DuelPairController.new,
  retry: appRetry,
);

/// Classifica Elo del gruppo.
///
/// Provider separato dalla coppia: sono richieste diverse e falliscono per
/// motivi diversi, quindi un errore nella classifica non deve far sparire il
/// duello che l utente sta giocando.
class DuelStandingsController extends AsyncNotifier<List<DuelStanding>> {
  DuelStandingsController(this.groupId);

  final String groupId;

  @override
  Future<List<DuelStanding>> build() =>
      ref.watch(duelsRepositoryProvider).standings(groupId);

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

final duelStandingsProvider =
    AsyncNotifierProvider.family<DuelStandingsController, List<DuelStanding>, String>(
  DuelStandingsController.new,
  retry: appRetry,
);

/// Scelta del contendente preferito.
///
/// Un controller solo per la scrittura, con stato di caricamento: senza, due
/// tocchi ravvicinati registrerebbero due duelli. `duels` e' append-only e non
/// ha nessun vincolo di unicita', quindi il doppio inserimento passerebbe e il
/// secondo duello falserebbe gli Elo. Per questo lo stato serve a disabilitare
/// le due carte finche' la richiesta non e' tornata.
class DuelActionController extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  bool get isSaving => state.isLoading;

  Future<void> play({
    required String groupId,
    required DuelPair pair,
    required String selectedAnimeId,
  }) async {
    state = const AsyncLoading();
    try {
      await ref
          .read(duelsRepositoryProvider)
          .play(groupId, pair, selectedAnimeId);
      state = const AsyncData(null);
    } catch (error, stack) {
      // Come per il voto in classifica: lo stato registra l'errore e
      // l'eccezione viene rilanciata, altrimenti la schermata mostrerebbe la
      // scelta come confermata anche se il backend l'avesse rifiutata.
      state = AsyncError(error, stack);
      rethrow;
    }

    // Solo gli Elo cambiano. La coppia resta quella appena giocata: cambiarla
    // subito nasconderebbe all'utente il risultato della scelta appena fatta,
    // quindi si ricarica solo quando lo chiede con "Prossima coppia".
    ref.invalidate(duelStandingsProvider(groupId));
  }
}

final duelActionProvider =
    AsyncNotifierProvider<DuelActionController, void>(
  DuelActionController.new,
  retry: appRetry,
);
