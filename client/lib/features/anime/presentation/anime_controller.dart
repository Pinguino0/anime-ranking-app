import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/app_retry.dart';
import '../data/anime_repository.dart';
import '../domain/anime.dart';

final animeRepositoryProvider = Provider<AnimeRepository>((ref) {
  throw StateError('animeRepositoryProvider non e stato inizializzato.');
});

/// Stato di una ricerca anime.
///
/// Un controller solo per testo e filtri, perche' i due viaggiano insieme: se
/// fossero due provider separati, ogni tasto digitato dovrebbe ricostruire
/// entrambi e l'infinite scroll non saprebbe quale dei due gli serve.
class AnimeSearchController extends AsyncNotifier<List<AnimeEntry>> {
  /// Testo cercato.
  ///
  /// Vive qui e non come argomento della family: cambia a ogni tasto, e una
  /// family su testo ricreerebbe il controller a ogni carattere, perdendo lo
  /// scroll e la pagina gia' caricati.
  String _query = '';

  AnimeFilters _filters = AnimeFilters.none;

  /// Quante righe sono state caricate finora: e' l'offset della prossima pagina.
  int _loaded = 0;

  /// true se la ricerca corrente e' gia' stata tentata su Jikan.
  ///
  /// Serve a non ripetere la chiamata remota a ogni scroll: Jikan ha limiti
  /// stretti e rilanciarla per ogni pagina sarebbe il modo piu' rapido per
  /// esaurirli.
  bool _triedRemote = false;

  String get query => _query;

  AnimeFilters get filters => _filters;

  /// true se i filtri sono attiivi: alimenta il badge sulla pulsantiera.
  bool get hasActiveFilters => _filters.isActive;

  @override
  Future<List<AnimeEntry>> build() async {
    final repository = ref.watch(animeRepositoryProvider);
    _loaded = 0;
    _triedRemote = false;

    final page = await repository.searchLocal(
      _query,
      filters: _filters,
      limit: AnimePageSize.size,
      offset: 0,
    );

    _loaded = page.results.length;
    ref.read(animePaginationProvider.notifier).reset(hasMore: page.hasNext);
    return page.results;
  }

  /// Imposta il testo e ricarica.
  ///
  /// La ricerca parte subito: il rimando lo fa la schermata con un timer,
  /// perche' a ogni tasto non deve partire una richiesta.
  Future<void> search(String text) async {
    final next = text.trim();
    // Stesso testo: ricaricare azzererebbe la lista per un risultato identico,
    // e l'utente che preme "cerca" su quello che ha gia' scritto si
    // ritroverebbe la pagina persa.
    if (next == _query) return;

    _query = next;
    _triedRemote = false;
    ref.invalidateSelf();
    await future;
  }

  /// Applica filtri nuovi e ricarica dalla prima pagina.
  ///
  /// Riparte dal primo risultato perche' l'ordinamento cambia: la pagina 3 con
  /// i filtri precedenti non ha senso con quelli nuovi.
  Future<void> applyFilters(AnimeFilters filters) async {
    _filters = filters;
    _triedRemote = false;
    // Il pannello si riapre da solo dopo un filtro applicato: aver premuto un
    // pastiglia e vederlo sparire sarebbe come un comando che si annulla.
    ref.read(animeFiltersPanelProvider.notifier).show();
    ref.invalidateSelf();
    await future;
  }

  /// Aggiunge o toglie un genere.
  Future<void> toggleGenre(String genre) =>
      applyFilters(_filters.toggleGenre(genre));

  /// Azzera tutti i filtri.
  Future<void> clearFilters() => applyFilters(AnimeFilters.none);

  void toggleFiltersPanel() =>
      ref.read(animeFiltersPanelProvider.notifier).toggle();

  Future<void> refresh() async {
    _triedRemote = false;
    ref.invalidateSelf();
    await future;
  }

  /// Carica la pagina successiva.
  ///
  /// Nessun errore sollevato: un fallimento in coda non deve svuotare i
  /// risultati gia' mostrati. Lo stato della paginazione dice perche' la lista
  /// si e' fermata.
  Future<void> loadMore() async {
    final current = state.value;
    final pagination = ref.read(animePaginationProvider.notifier);
    if (current == null ||
        pagination.current.isLoadingMore ||
        !pagination.current.hasMore) {
      return;
    }

    pagination.started();

    try {
      final page = await ref
          .read(animeRepositoryProvider)
          .searchLocal(
            _query,
            filters: _filters,
            limit: AnimePageSize.size,
            offset: _loaded,
          );

      _loaded += page.results.length;
      pagination.finished(hasMore: page.hasNext);

      // Deduplicazione per externalId: due pagine possono toccarsi se il
      // catalogo cambia fra una richiesta e l'altra (un anime appena inserito
      // sposta tutto di una posizione). Senza questo controllo l'utente vede
      // lo stesso anime due volte e pensa che sia un bug.
      state = AsyncData(_merge(current, page.results));
    } on AnimeFailure catch (e) {
      pagination.failed(e);
    } catch (_) {
      pagination.failed(
        const AnimeFailure('Altre righe non disponibili. Riprova.'),
      );
    }
  }

  /// Se la ricerca locale non ha dato nulla, prova su Jikan.
  ///
  /// E' il passaggio che rende il catalogo che si costruisce da solo: la
  /// ricerca locale trova solo cio' che e' gia' stato cercato da qualcun
  /// altro. Senza questo passaggio, il primo utente a cercare un anime
  /// riceverebbe sempre zero risultati e sembrerebbe che l'app sia vuota.
  ///
  /// [forced] serve al pulsante "cerca su Jikan": senza, un tocco ripetuto non
  /// farebbe nulla e sembrerebbe un pulsante morto.
  Future<void> searchRemote({bool forced = false}) async {
    final current = state.value ?? const [];
    final pagination = ref.read(animePaginationProvider.notifier);

    // Non ha senso cercare su Jikan un catalogo vuoto in partenza o mentre
    // gia' sta caricando: due richieste sovrapposte su Jikan peggiorano solo
    // la quota.
    if (pagination.current.isLoadingMore) return;
    if (!forced && (_query.isEmpty || _triedRemote)) return;
    if (!forced && current.isNotEmpty) return;

    pagination.started();

    try {
      final page = await ref
          .read(animeRepositoryProvider)
          .searchRemote(
            _query,
            filters: _filters,
            limit: AnimePageSize.size,
            page: 1,
          );

      _triedRemote = true;
      pagination.finished(hasMore: page.hasNext);

      // I risultati di Jikan hanno `id` null finche' la cache non li ha
      // scritti. Se la scrittura e' riuscita, la ricerca locale successiva li
      // restituisce con l'id, quindi non si tenta di costruirlo qui: inventare
      // un id darebbe un voto destinato a fallire.
      state = AsyncData(_merge(current, page.results));
    } on AnimeFailure catch (e) {
      pagination.failed(e);
    } catch (_) {
      pagination.failed(
        const AnimeFailure('Ricerca online non riuscita. Riprova.'),
      );
    }
  }

  /// Unisce due liste togliendo i duplicati per `externalId`.
  ///
  /// L'ordine si conserva: i risultati nuovi stanno dopo quelli gia' caricati,
  /// perche' durante lo scroll l'ordine non deve cambiare sotto gli occhi di
  /// chi sta leggendo.
  List<AnimeEntry> _merge(List<AnimeEntry> current, List<AnimeEntry> incoming) {
    if (incoming.isEmpty) return current;

    final seen = {for (final entry in current) entry.externalId};
    final additions = <AnimeEntry>[
      for (final entry in incoming)
        if (seen.add(entry.externalId)) entry,
    ];

    if (additions.isEmpty) return current;
    return [...current, ...additions];
  }
}

/// Quante righe si caricano per volta.
///
/// 24 e' il numero di risultati che Jikan restituisce per richiesta e anche la
/// dimensione dichiarata in `AppConfig`: chiedere di piu' alla Edge Function
/// verrebbe troncato da Jikan, quindi non ha senso.
class AnimePageSize {
  const AnimePageSize._();

  static const int size = 24;
}

/// Come procede il caricamento delle pagine.
///
/// Provider separato dal controller perche' la schermata deve poter distinguere
/// "sto caricando la prima pagina" (scheletro a schermo intero) da "sto
/// caricando la successiva" (riga di spinner in fondo alla lista). Se lo stato
/// fosse un campo del notifier, la schermata non verrebbe avvisata quando
/// cambia.
@immutable
class AnimePagination {
  const AnimePagination({
    this.hasMore = false,
    this.isLoadingMore = false,
    this.error,
  });

  final bool hasMore;
  final bool isLoadingMore;

  /// Errore dell'ultima pagina, se c'e' stato.
  ///
  /// Fuori dallo stato `AsyncValue` perche' un errore in coda non rende errata
  /// la lista: renderizzerebbe anche il fallimento come schermata vuota e
  /// farebbe sparire i risultati gia' trovati.
  final AnimeFailure? error;

  AnimePagination copyWith({
    bool? hasMore,
    bool? isLoadingMore,
    AnimeFailure? error,
  }) => AnimePagination(
    hasMore: hasMore ?? this.hasMore,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    error: error,
  );
}

class AnimePaginationController extends Notifier<AnimePagination> {
  @override
  AnimePagination build() => const AnimePagination();

  AnimePagination get current => state;

  /// Riparte dalla prima pagina e azzera l'errore in coda, che dopo un cambio
  /// di filtri non descrive piu' nulla.
  void reset({required bool hasMore}) =>
      state = AnimePagination(hasMore: hasMore);

  void started() => state = state.copyWith(isLoadingMore: true);

  /// Fine caricamento: azzera l'errore precedente. Senza questo, dopo un
  /// tentativo riuscito resterebbe il messaggio del fallimento precedente e la
  /// lista mostrerebbe un errore vecchio su risultati nuovi.
  void finished({required bool hasMore}) =>
      state = AnimePagination(hasMore: hasMore);

  void failed(AnimeFailure error) =>
      state = state.copyWith(isLoadingMore: false, error: error);
}

final animePaginationProvider =
    NotifierProvider<AnimePaginationController, AnimePagination>(
      AnimePaginationController.new,
    );

/// Pannello dei filtri aperto o chiuso.
///
/// Provider a se' stante e non un campo del controller di ricerca: aprirlo o
/// chiuderlo non cambia nulla dei risultati, quindi non deve passare da
/// `invalidateSelf` e far ripartire una ricerca che l'utente non ha chiesto di
/// ripetere.
class AnimeFiltersPanelController extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;

  void show() => state = true;
}

final animeFiltersPanelProvider =
    NotifierProvider<AnimeFiltersPanelController, bool>(
      AnimeFiltersPanelController.new,
    );

final animeSearchProvider =
    AsyncNotifierProvider<AnimeSearchController, List<AnimeEntry>>(
      AnimeSearchController.new,
      retry: appRetry,
    );

/// Anime usciti di recente: la home della ricerca.
class RecentAnimeController extends AsyncNotifier<List<AnimeEntry>> {
  @override
  Future<List<AnimeEntry>> build() =>
      ref.watch(animeRepositoryProvider).currentSeason();

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

final recentAnimeProvider =
    AsyncNotifierProvider<RecentAnimeController, List<AnimeEntry>>(
      RecentAnimeController.new,
      retry: appRetry,
    );

/// Generi disponibili, per costruire le pastiglie filtro.
class AnimeGenresController extends AsyncNotifier<List<AnimeGenre>> {
  @override
  Future<List<AnimeGenre>> build() =>
      ref.watch(animeRepositoryProvider).genres();

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

final animeGenresProvider =
    AsyncNotifierProvider<AnimeGenresController, List<AnimeGenre>>(
      AnimeGenresController.new,
      retry: appRetry,
    );

/// Riepilogo del catalogo per la testata.
///
/// Se non e' disponibile non blocca la ricerca: [AnimeCatalogStats.empty] basta
/// e la schermata semplicemente non mostra il contatore. Un errore qui sarebbe
/// sproporzionato rispetto a cosa serve sapere.
class AnimeStatsController extends AsyncNotifier<AnimeCatalogStats> {
  @override
  Future<AnimeCatalogStats> build() async {
    try {
      return await ref.watch(animeRepositoryProvider).stats();
    } catch (_) {
      return AnimeCatalogStats.empty;
    }
  }

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

final animeStatsProvider =
    AsyncNotifierProvider<AnimeStatsController, AnimeCatalogStats>(
      AnimeStatsController.new,
      retry: appRetry,
    );

/// Stato dell'Edge Function.
///
/// Non e' un errore ma un dato: durante una beta e' normale che la funzione non
/// sia ancora stata deployata, e la UI deve poterlo dire senza presentarsi come
/// un guasto.
class AnimeEdgeController extends AsyncNotifier<AnimeEdgeHealth> {
  @override
  Future<AnimeEdgeHealth> build() async {
    try {
      return await ref.watch(animeRepositoryProvider).checkEdge();
    } catch (_) {
      return AnimeEdgeHealth.failing;
    }
  }
}

final animeEdgeProvider =
    AsyncNotifierProvider<AnimeEdgeController, AnimeEdgeHealth>(
      AnimeEdgeController.new,
      retry: appRetry,
    );
