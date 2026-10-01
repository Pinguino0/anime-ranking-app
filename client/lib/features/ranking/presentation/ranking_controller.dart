import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/cache_status.dart';
import '../../../core/error/app_retry.dart';
import '../data/ranking_repository.dart';
import '../domain/ranking.dart';

final rankingRepositoryProvider = Provider<RankingRepository>((ref) {
  throw StateError('rankingRepositoryProvider non e stato inizializzato.');
});

/// Provenienza dell'ultima lettura per gruppo.
///
/// Provider a parte dal repository perche' la schermata deve poter dire "stai
/// vedendo una copia salvata" anche quando i dati sono arrivati senza errori: se
/// la provenienza vivesse dentro il repository, l'unico modo di sapere che era
/// una copia sarebbe far fallire la lettura, e l'utente vedrebbe una schermata
/// di errore al posto della classifica.
final rankingCacheStatusProvider = NotifierProvider.family<RankingCacheStatusController,
    CacheStatus, String>(RankingCacheStatusController.new);

class RankingCacheStatusController extends Notifier<CacheStatus> {
  RankingCacheStatusController(this.groupId);

  final String groupId;

  @override
  CacheStatus build() => const CacheStatus.fresh();

  void report(CacheStatus status) => state = status;
}

/// Classifica di un gruppo.
///
/// L'id del gruppo arriva dal costruttore e non da un campo `arg`: in
/// Riverpod 3 la factory di una family passa l'argomento al costruttore del
/// notifier, quindi e' l'unico posto dove e' garantito essere disponibile
/// (compreso dentro `refresh`, che non ha piu' accesso alla factory).
class RankingController extends AsyncNotifier<List<RankingEntry>> {
  RankingController(this.groupId);

  final String groupId;

  /// Quante righe sono gia' state caricate.
  ///
  /// Serve come offset della prossima pagina: il backend ordina e pagina in
  /// SQL, quindi l'unico modo di continuare la classifica e' dirgli da dove
  /// riprendere. Resta a zero finche' [build] non e' finito, cosi' un
  /// [loadMore] chiamato durante il caricamento iniziale non leggerebbe righe a
  /// caso.
  int _loaded = 0;

/// true se c'e' un'altra pagina da caricare.
  bool get hasMore => ref.read(rankingPaginationProvider(groupId)).hasMore;

  @override
  Future<List<RankingEntry>> build() async {
    // Ogni ricostruzione riparte dalla prima pagina: dopo un refresh o un voto
    // la classifica e' cambiata e le righe accumulate non hanno piu' un ordine
    // valido, quindi mescolarle con le nuove mostrerebbe doppioni e salti.
    final repository = ref.watch(rankingRepositoryProvider);
    final rows = await repository.ranking(groupId, limit: RankingPage.size, offset: 0);

    _loaded = rows.length;
    ref
        .read(rankingPaginationProvider(groupId).notifier)
        .reset(hasMore: RankingPage.hasMore(rows));
    reportCacheStatus(ref, repository);
    return rows;
  }

  /// Segna da dove arrivano i dati appena letti.
  ///
  /// Solo se il repository sa dirlo: senza cache non c'e' niente da dire, e non
  /// vale la pena far girare la schermata per un valore identico a quello di
  /// prima.
  void reportCacheStatus(Ref ref, RankingRepository repository) {
    if (repository is! ProvidesCacheStatus) return;

    final cache = repository as ProvidesCacheStatus;
    ref.read(rankingCacheStatusProvider(groupId).notifier).report(cache.cacheStatus);
  }

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }

  /// Accoda la pagina successiva.
  ///
  /// Non solleva: un errore in coda non deve svuotare la classifica gia'
  /// caricata. Lo stato resta com'era e [pageError] dice perche' la lista si e'
  /// fermata, cosi' l'utente puo' riprovare senza riaprire la schermata.
  ///
  /// Le righe sono in coda e non rimpiazzate: la posizione di ogni anime e'
  /// quella del ranking e non deve cambiare mentre si scorre.
  Future<void> loadMore() async {
    final current = state.value;
    final pagination = ref.read(rankingPaginationProvider(groupId).notifier);
    if (current == null || pagination.current.isLoadingMore || !pagination.current.hasMore) {
      return;
    }

    pagination.started();

    try {
      final rows = await ref
          .read(rankingRepositoryProvider)
          .ranking(groupId, limit: RankingPage.size, offset: _loaded);

      _loaded += rows.length;
      pagination.finished(hasMore: RankingPage.hasMore(rows));

      final repository = ref.read(rankingRepositoryProvider);
      reportCacheStatus(ref, repository);
      state = AsyncData([...current, ...rows]);
    } on RankingFailure catch (e) {
      pagination.failed(e);
    } catch (_) {
      pagination.failed(const RankingFailure('Altre righe non disponibili. Riprova.'));
    }
  }
}

/// Come procede il caricamento delle pagine successive.
///
/// Provider a se' stante e non un campo del [RankingController]: la schermata
/// ascolta questo valore, e un campo mutabile dentro il notifier non la
/// avviserebbe che lo spinner e' finito o che c'e' un errore da mostrare.
@immutable
class RankingPagination {
  const RankingPagination({this.hasMore = false, this.isLoadingMore = false, this.error});

  /// true se l'ultima pagina letta era piena, quindi probabilmente ce n'e' un
  /// altra.
  ///
  /// Si basa sulla pagina appena ricevuta, non sul totale accumulato: contando
  /// le righe in memoria la risposta cambierebbe a ogni pagina ("ora ci sono
  /// 100 righe, non 50, quindi non c'e' piu' niente") e la lista si fermerebbe
  /// dopo la seconda pagina.
  final bool hasMore;

  /// true mentre una pagina successiva e' in volo.
  ///
  /// Senza questo guardia due scroll rapidi aprirebbero due richieste sulla
  /// stessa pagina e la seconda accoderebbe le stesse righe due volte.
  final bool isLoadingMore;

  /// Errore dell'ultima pagina, se c'e' stato.
  ///
  /// Fuori dallo stato `AsyncValue` della classifica perche' un fallimento in
  /// coda non rende errata la lista: se lo facesse sparirebbero anche le righe
  /// gia' caricate, che sono buone.
  final RankingFailure? error;

  RankingPagination copyWith({bool? hasMore, bool? isLoadingMore, RankingFailure? error}) =>
      RankingPagination(
        hasMore: hasMore ?? this.hasMore,
        isLoadingMore: isLoadingMore ?? this.isLoadingMore,
        error: error,
      );
}

class RankingPaginationController extends Notifier<RankingPagination> {
  RankingPaginationController(this.groupId);

  final String groupId;

  @override
  RankingPagination build() => const RankingPagination();

  /// Lo stato corrente.
  ///
  /// Esposto perche' il chiamante controlla due condizioni in una volta sola
  /// ("sto caricando e non ci sono piu' pagine"): leggere lo stato due volte
  /// potrebbe dare due risposte diverse se nel frattempo cambia.
  RankingPagination get current => state;

  /// Riparte dalla prima pagina: dopo un refresh o un voto l'errore in coda non
  /// descrive piu' nulla.
  void reset({required bool hasMore}) =>
      state = RankingPagination(hasMore: hasMore);

  void started() => state = state.copyWith(isLoadingMore: true);

  void finished({required bool hasMore}) => state = RankingPagination(hasMore: hasMore);

  void failed(RankingFailure error) => state = state.copyWith(isLoadingMore: false, error: error);
}

final rankingPaginationProvider =
    NotifierProvider.family<RankingPaginationController, RankingPagination, String>(
  RankingPaginationController.new,
);

final rankingProvider =
    AsyncNotifierProvider.family<RankingController, List<RankingEntry>, String>(
  RankingController.new,
  retry: appRetry,
);

/// Quante righe si caricano per volta.
///
/// La classifica e' paginata lato server perche' un gruppo molto attivo puo'
/// avere centinaia di anime votati e portarli tutti sul telefono costerebbe piu'
/// di quanto vale: le prime posizioni sono le uniche che si leggono davvero.
class RankingPage {
  const RankingPage._();

  static const int size = 50;

  /// true se il backend ha restituito una pagina piena, quindi probabilmente ce
  /// n'e' un'altra.
  ///
  /// Il backend tronca comunque a 200 righe per richiesta: se il gruppo ne ha
  /// di piu', l'utente vede i primi 200 e la voce resta coerente invece di
  /// sparire e lasciare senza capire se mancano righe o no.
  static bool hasMore(List<RankingEntry> rows) => rows.length == size;
}

/// Classifiche speciali di un gruppo.
///
/// L'argomento e' una tupla `(groupId, kind)` invece di un oggetto con due
/// campi: e' il tipo che la family accetta direttamente e i due valori hanno
/// tipi diversi, quindi scambiarli romperebbe l'analisi statica.
class SpecialRankingController extends AsyncNotifier<List<SpecialRankingEntry>> {
  SpecialRankingController(this.groupId, this.kind);

  final String groupId;
  final SpecialRankingKind kind;

  @override
  Future<List<SpecialRankingEntry>> build() =>
      ref.watch(rankingRepositoryProvider).special(groupId, kind, limit: 20);

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

/// Chiave delle classifiche speciali: gruppo e tipo.
///
/// Un record invece di una classe con due campi perche' e' gia' il tipo che la
/// family accetta (`(String, SpecialRankingKind)`), e i due valori hanno tipi
/// diversi: scambiarli nella chiamata romperebbe l'analisi statica.
typedef SpecialRankingKey = (String, SpecialRankingKind);

final specialRankingProvider =
    AsyncNotifierProvider.family<SpecialRankingController, List<SpecialRankingEntry>,
        SpecialRankingKey>(
  // La factory riceve un solo argomento (il record intero), quindi i due campi
  // vanno destrutturati qui: scrivere due parametri non compilerebbe.
  (key) => SpecialRankingController(key.$1, key.$2),
  retry: appRetry,
);

/// Statistiche di un gruppo.
class GroupStatsController extends AsyncNotifier<GroupStats> {
  GroupStatsController(this.groupId);

  final String groupId;

  @override
  Future<GroupStats> build() => ref.watch(rankingRepositoryProvider).stats(groupId);

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

final groupStatsProvider = AsyncNotifierProvider.family<GroupStatsController, GroupStats, String>(
  GroupStatsController.new,
  retry: appRetry,
);

/// Voti dell'utente collegato.
///
/// Un controller invece di chiamare il repository dalla schermata: dopo un
/// voto devono aggiornarsi classifica, classifiche speciali e statistiche, e
/// farlo in un punto solo evita che una schermata si aggiorni e l'altra no.
class RatingController extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  /// true se un voto e' in corso.
  ///
  /// Serve a disabilitare i pulsanti: due voti in volo sullo stesso anime
  /// possono tornare nell'ordine sbagliato e l'ultimo risposta sovrascriverebbe
  /// la prima, lasciando a schermo un voto che non e' quello scelto.
  bool get isSaving => state.isLoading;

  /// Registra il voto e ricalcola tutto quello che ne dipende.
  ///
  /// Lo stato passa per [AsyncLoading] cosi' la UI sa che sta salvando: senza,
  /// il tocco successivo resterebbe attivo e l'utente potrebbe votare due volte
  /// lo stesso anime senza accorgersene.
  Future<void> rate({
    required String groupId,
    required String animeId,
    required double score,
  }) async {
    state = const AsyncLoading();
    try {
      await ref.read(rankingRepositoryProvider).rate(groupId, animeId, score);
      state = const AsyncData(null);
    } catch (error, stack) {
      // Lo stato registra l'errore e l'eccezione viene rilanciata: senza il
      // rilancio chi chiama `rate` non saprebbe che il voto non e' stato
      // salvato, e mostrerebbe una conferma che non corrisponde ai dati.
      state = AsyncError(error, stack);
      rethrow;
    }

    // Il voto cambia media, conteggio e pesi: la classifica letta prima e'
    // semplicemente sbagliata, quindi va riletta. Le classifiche speciali non
    // cambiano sempre (la "divisivi" puo' restare identica), ma invalidarle
    // costa una richiesta solo all'apertura e lascia i numeri coerenti fra
    // loro: due schermate che si contraddicono sono peggio di un secondo di
    // caricamento.
    ref.invalidate(rankingProvider(groupId));
    ref.invalidate(groupStatsProvider(groupId));

    for (final kind in SpecialRankingKind.values) {
      ref.invalidate(specialRankingProvider((groupId, kind)));
    }
  }
}

final ratingProvider = AsyncNotifierProvider<RatingController, void>(
  RatingController.new,
  retry: appRetry,
);
