import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/app_retry.dart';
import '../data/tournaments_repository.dart';
import '../domain/tournaments.dart';

final tournamentsRepositoryProvider = Provider<TournamentsRepository>((ref) {
  throw StateError('tournamentsRepositoryProvider non e stato inizializzato.');
});

/// Tornei di un gruppo.
class TournamentsController extends AsyncNotifier<List<Tournament>> {
  TournamentsController(this.groupId);

  final String groupId;

  @override
  Future<List<Tournament>> build() =>
      ref.watch(tournamentsRepositoryProvider).list(groupId);

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

final tournamentsProvider =
    AsyncNotifierProvider.family<TournamentsController, List<Tournament>, String>(
  TournamentsController.new,
  retry: appRetry,
);

/// Tabellone di un torneo.
///
/// L'id arriva dal costruttore e non da `arg`: in Riverpod 3 e' l'unico posto
/// dove resta disponibile anche dentro [refresh].
class TournamentBracketController extends AsyncNotifier<TournamentBracket> {
  TournamentBracketController(this.tournamentId);

  final String tournamentId;

  @override
  Future<TournamentBracket> build() =>
      ref.watch(tournamentsRepositoryProvider).bracket(tournamentId);

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

final tournamentBracketProvider =
    AsyncNotifierProvider.family<TournamentBracketController, TournamentBracket, String>(
  TournamentBracketController.new,
  retry: appRetry,
);

/// Voti degli scontri, indicizzati per scontro.
///
/// Provider separato dal tabellone: i conteggi servono anche quando il bracket
/// non cambia, cioe' dopo ogni voto che non chiude la partita.
class TournamentVotesController extends AsyncNotifier<MatchTallies> {
  TournamentVotesController(this.tournamentId);

  final String tournamentId;

  @override
  Future<MatchTallies> build() async {
    final repo = ref.watch(tournamentsRepositoryProvider);
    // Il tabellone serve a sapere quali scontri esistono: senza di questo non si
    // sa a quali id chiedere i voti.
    final bracket = await ref.watch(tournamentBracketProvider(tournamentId).future);
    final matches = bracket.rounds.expand((round) => round.matches).toList();

    return tallyMatches(
      matches: matches,
      votes: await repo.votes(matches.map((m) => m.id).toList()),
      currentUserId: repo.currentUserId,
    );
  }

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

final tournamentVotesProvider =
    AsyncNotifierProvider.family<TournamentVotesController, MatchTallies, String>(
  TournamentVotesController.new,
  retry: appRetry,
);

/// Classifica del torneo.
class TournamentStandingsController
    extends AsyncNotifier<List<TournamentStanding>> {
  TournamentStandingsController(this.tournamentId);

  final String tournamentId;

  @override
  Future<List<TournamentStanding>> build() =>
      ref.watch(tournamentsRepositoryProvider).standings(tournamentId);

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

final tournamentStandingsProvider = AsyncNotifierProvider.family<
    TournamentStandingsController, List<TournamentStanding>, String>(
  TournamentStandingsController.new,
  retry: appRetry,
);

/// Creazione, voto ed eliminazione.
///
/// Un controller solo per le scritture, con stato di caricamento: senza, due
/// tocchi ravvicinati su uno scontro partirebbero due richieste. `cast_tournament_vote`
/// fa `on conflict do update`, quindi il voto non verrebbe duplicato, ma il
/// secondo richiamo rivaluterebbe il bracket mentre la schermata mostra ancora
/// il primo risultato.
class TournamentActionController extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  bool get isSaving => state.isLoading;

  /// Crea un torneo e restituisce quello creato, per aprirne subito il
  /// tabellone senza passare dalla lista.
  Future<Tournament> create({
    required String groupId,
    required String name,
    required List<String> animeIds,
  }) async {
    state = const AsyncLoading();
    try {
      final tournament = await ref
          .read(tournamentsRepositoryProvider)
          .create(groupId: groupId, name: name, animeIds: animeIds);
      state = const AsyncData(null);
      // La lista del gruppo cambia: senza questo il nuovo torneo non comparirebbe
      // fino al prossimo ricaricamento manuale.
      ref.invalidate(tournamentsProvider(groupId));
      return tournament;
    } catch (error, stack) {
      state = AsyncError(error, stack);
      rethrow;
    }
  }

  /// Vota uno scontro e restituisce true se il voto lo ha chiuso.
  ///
  /// Il valore serve alla schermata: quando e' true il backend ha risolto la
  /// partita e il vincente e' salito al turno dopo, quindi vale la pena dire
  /// all'utente che lo scontro si e' chiuso invece di lasciargli il dubbio.
  Future<bool> vote({
    required String tournamentId,
    required String matchId,
    required String animeId,
  }) async {
    state = const AsyncLoading();
    bool closed;

    try {
      closed = await ref
          .read(tournamentsRepositoryProvider)
          .vote(matchId: matchId, animeId: animeId);
      state = const AsyncData(null);
    } catch (error, stack) {
      state = AsyncError(error, stack);
      rethrow;
    }

    // Dopo il voto cambiano i conteggi e, se lo scontro e' chiuso, anche il
    // tabellone. La classifica si rillega solo in quel caso: rileggerla a ogni
    // voto sarebbe una richiesta sprecata, dato che resta identica finche' il
    // torneo non finisce.
    ref.invalidate(tournamentVotesProvider(tournamentId));
    ref.invalidate(tournamentBracketProvider(tournamentId));
    if (closed) {
      ref.invalidate(tournamentStandingsProvider(tournamentId));
    }

    return closed;
  }

  /// Elimina un torneo. Rilegge anche la lista, da cui il `groupId` serve.
  Future<void> delete({required String groupId, required String tournamentId}) async {
    state = const AsyncLoading();
    try {
      await ref.read(tournamentsRepositoryProvider).delete(tournamentId);
      state = const AsyncData(null);
      ref.invalidate(tournamentsProvider(groupId));
    } catch (error, stack) {
      state = AsyncError(error, stack);
      rethrow;
    }
  }
}

final tournamentActionProvider =
    AsyncNotifierProvider<TournamentActionController, void>(
  TournamentActionController.new,
  retry: appRetry,
);