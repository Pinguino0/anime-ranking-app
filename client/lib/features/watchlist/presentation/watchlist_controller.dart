import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/app_retry.dart';
import '../data/watchlist_repository.dart';
import '../domain/watchlist.dart';

final watchlistRepositoryProvider = Provider<WatchlistRepository>((ref) {
  throw StateError('watchlistRepositoryProvider non e stato inizializzato.');
});

/// Watchlist dell utente collegato in un gruppo.
///
/// L'id del gruppo arriva dal costruttore, non da un campo `arg`: in Riverpod 3
/// la factory di una family passa l argomento al costruttore del notifier, ed e
/// l unico posto dove resta disponibile anche dentro [refresh].
class WatchlistController extends AsyncNotifier<List<WatchlistEntry>> {
  WatchlistController(this.groupId);

  final String groupId;

  @override
  Future<List<WatchlistEntry>> build() =>
      ref.watch(watchlistRepositoryProvider).entries(groupId);

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

final watchlistProvider =
    AsyncNotifierProvider.family<WatchlistController, List<WatchlistEntry>, String>(
  WatchlistController.new,
  retry: appRetry,
);

/// Totali della watchlist, dalla stessa sorgente delle righe.
///
/// Provider separato e non un getter: le cifre arrivano da `personal_stats`,
/// cioe una richiesta diversa, e miscelarle alle righe farebbe fallire tutto
/// insieme quando una delle due non risponde.
class WatchlistTotalsController extends AsyncNotifier<WatchlistTotals> {
  WatchlistTotalsController(this.groupId);

  final String groupId;

  @override
  Future<WatchlistTotals> build() =>
      ref.watch(watchlistRepositoryProvider).totals(groupId);

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

final watchlistTotalsProvider =
    AsyncNotifierProvider.family<WatchlistTotalsController, WatchlistTotals, String>(
  WatchlistTotalsController.new,
  retry: appRetry,
);

/// Statistiche personali complessive, per il profilo.
///
/// Non e' una family — non dipende da un gruppo — e non e' un notifier perche'
/// il profilo la sola legge: un [FutureProvider] basta e non aggiunge stato.
/// Vive qui perche' parla la stessa lingua di [WatchlistTotals] e attinge alle
/// stesse tabelle.
final personalOverviewProvider = FutureProvider<WatchlistTotals>(
  (ref) => ref.watch(watchlistRepositoryProvider).overview(),
  retry: appRetry,
);

/// Consigli di visione registrati nel gruppo.
///
/// Provider a parte dalla watchlist: i consigli sono un fatto distinto dalle
/// righe (dicono chi ha consigliato cosa a chi) e una richiesta separata rende
/// la schermata di gruppo utilizzabile anche se i consigli non rispondono.
class GroupRecommendationsController extends AsyncNotifier<List<AnimeRecommendation>> {
  GroupRecommendationsController(this.groupId);

  final String groupId;

  @override
  Future<List<AnimeRecommendation>> build() =>
      ref.watch(watchlistRepositoryProvider).recommendations(groupId);

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

final groupRecommendationsProvider = AsyncNotifierProvider.family<
    GroupRecommendationsController, List<AnimeRecommendation>, String>(
  GroupRecommendationsController.new,
  retry: appRetry,
);

/// La watchlist personale dell'utente.
///
/// Non e' una family: la lista personale non dipende da un gruppo e non ha
/// nulla a che vedere con le liste condivise. I totali non hanno un provider
/// dedicato perche' si ricavano dalle stesse righe (conteggi e somma degli
/// episodi): una seconda richiesta per numeri che sono gia' qui sarebbe
/// un'altra cosa da far combaciare.
class MyListController extends AsyncNotifier<List<WatchlistEntry>> {
  @override
  Future<List<WatchlistEntry>> build() =>
      ref.watch(watchlistRepositoryProvider).personalEntries();

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

final myListProvider =
    AsyncNotifierProvider<MyListController, List<WatchlistEntry>>(
  MyListController.new,
  retry: appRetry,
);

/// Modifiche alla watchlist.
///
/// Un controller solo per le scritture, con stato di caricamento: le voci
/// si modificano da quattro punti diversi (stato, episodi, preferito,
/// rimozione) e ognuno deve poter dire "sto salvando" senza toccare la lista
/// gia' caricata, che altrimenti lampeggerebbe a ogni tocco.
class WatchlistActionController extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  /// true se una modifica e in corso.
  ///
  /// Serve a disabilitare i controlli della riga: due salvataggi in volo sulla
  /// stessa voce possono tornare nell ordine sbagliato e lasciare a schermo un
  /// valore che non e' quello salvato.
  bool get isSaving => state.isLoading;

  /// Registra un consiglio di visione nel gruppo.
  ///
  /// Non passa da [_run] perche' oltre a righe e totali va invalidata anche la
  /// lista dei consigli: saltarla lascerebbe a schermo il consiglio appena
  /// inviato solo dopo un refresh manuale.
  Future<void> recommend({
    required String groupId,
    required String animeId,
    String? toUserId,
    String? message,
  }) async {
    state = const AsyncLoading();

    try {
      await ref.read(watchlistRepositoryProvider).recommend(
            groupId: groupId,
            animeId: animeId,
            toUserId: toUserId,
            message: message,
          );
      state = const AsyncData(null);
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      rethrow;
    }

    ref.invalidate(watchlistProvider(groupId));
    ref.invalidate(watchlistTotalsProvider(groupId));
    ref.invalidate(groupRecommendationsProvider(groupId));
    ref.invalidate(myListProvider);
  }

  Future<void> setStatus({
    required String animeId,
    required WatchStatus status,
    String? groupId,
  }) =>
      _run(
        groupId,
        () => ref
            .read(watchlistRepositoryProvider)
            .setStatus(groupId, animeId, status),
      );

  Future<void> setEpisode({
    required String animeId,
    required int episode,
    String? groupId,
  }) =>
      _run(
        groupId,
        () =>
            ref.read(watchlistRepositoryProvider).setEpisode(groupId, animeId, episode),
      );

  Future<void> setFavorite({
    required String animeId,
    required bool isFavorite,
    String? groupId,
  }) =>
      _run(
        groupId,
        () => ref
            .read(watchlistRepositoryProvider)
            .setFavorite(groupId, animeId, isFavorite),
      );

  Future<void> remove({
    required String animeId,
    String? groupId,
  }) =>
      _run(
        groupId,
        () => ref.read(watchlistRepositoryProvider).remove(groupId, animeId),
      );

  /// Esegue la scrittura, ne riletta la lista e rilancia l errore.
  Future<void> _run(String? groupId, Future<void> Function() action) async {
    state = const AsyncLoading();
    try {
      await action();
      state = const AsyncData(null);
    } catch (error, stack) {
      // Lo stato registra l errore e l eccezione viene rilanciata: senza il
      // rilancio la schermata chiuderebbe il foglio degli episodi dicendo
      // "salvato" anche se il backend ha rifiutato la riga.
      state = AsyncError(error, stack);
      rethrow;
    }

    // Dopo una scrittura i totali sono sbagliati (un episodio in piu', un
    // preferito in piu', una voce in piu') quindi vanno riletti insieme alle
    // righe: cifre e elenco che non tornano insieme sono peggio di un secondo
    // di caricamento.
    // Solo la watchlist di gruppo ha cifre separate da rileggere: quella
    // personale si conta dalle righe, che vengono ricaricate qui sotto.
    if (groupId != null) {
      ref.invalidate(watchlistProvider(groupId));
      ref.invalidate(watchlistTotalsProvider(groupId));
    }
    // "La mia lista" e' la watchlist personale: una scrittura senza gruppo la
    // tocca direttamente, una di gruppo no.
    ref.invalidate(myListProvider);
  }
}

final watchlistActionProvider =
    AsyncNotifierProvider<WatchlistActionController, void>(
  WatchlistActionController.new,
  retry: appRetry,
);
