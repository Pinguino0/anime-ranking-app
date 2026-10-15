import 'package:animerank/features/anime/data/anime_repository.dart';
import 'package:animerank/features/anime/domain/anime.dart';
import 'package:animerank/features/anime/presentation/anime_controller.dart';

/// Repository finto per i test del catalogo.
///
/// Filtra davvero in memoria come fa la RPC: un fake che restituisce tutto
/// qualunque cosa gli venga chiesto passerebbe i test di filtro, ma non
/// garantirebbe che il controller mandi i parametri giusti. Qui i filtri sono
/// applicati per davvero, quindi un test che sbaglia un parametro fallisce.
class FakeAnimeRepository implements AnimeRepository {
  FakeAnimeRepository({List<AnimeEntry>? initial}) : _rows = [...?initial];

  final List<AnimeEntry> _rows;

  int localCalls = 0;
  int remoteCalls = 0;
  int seasonCalls = 0;
  int genresCalls = 0;
  int statsCalls = 0;
  int edgeChecks = 0;

  /// Offset richiesti, in ordine: senza questi una paginazione sbagliata
  /// passerebbe il test.
  List<int> localOffsets = [];

  /// Filtri ricevuti, per verificare che la UI li trasmetta.
  List<AnimeFilters> receivedFilters = [];

  /// Query testuali ricevute.
  List<String> receivedQueries = [];

  AnimeFailure? localFailure;
  AnimeFailure? remoteFailure;
  AnimeFailure? seasonFailure;
  AnimeFailure? genresFailure;
  AnimeFailure? statsFailure;

  /// Pagine remote in coda, per simulare la fine della lista.
  List<List<AnimeEntry>>? remotePages;

  /// true se la ricerca remota deve dichiarare "c'e' un'altra pagina".
  bool remoteHasNext = false;

  /// Totale dichiarato dalla ricerca remota.
  int? remoteTotal;

  /// Provenienza dichiarata dalla ricerca remota: `true` simula una risposta
  /// servita dalla cache.
  bool remoteFromCache = false;

  /// Numero di risultati che ogni pagina remota restituisce.
  int remotePageSize = AnimePageSize.size;

  List<AnimeGenre> genresResult = const [];

  AnimeCatalogStats statsResult = AnimeCatalogStats.empty;

  AnimeEdgeHealth edgeResult = AnimeEdgeHealth.ready;

  @override
  Future<AnimePage> searchLocal(
    String query, {
    AnimeFilters filters = AnimeFilters.none,
    int limit = AnimePageSize.size,
    int offset = 0,
  }) async {
    localCalls++;
    localOffsets.add(offset);
    receivedQueries.add(query);
    receivedFilters.add(filters);

    final failure = localFailure;
    if (failure != null) throw failure;

    final matched = _rows
        .where((entry) => _matches(entry, query, filters))
        .toList();
    final slice = offset >= matched.length
        ? const <AnimeEntry>[]
        : matched.skip(offset).take(limit).toList();

    return AnimePage(
      results: List.unmodifiable(slice),
      hasNext: offset + slice.length < matched.length,
      total: matched.length,
      fromCache: true,
    );
  }

  @override
  Future<AnimePage> searchRemote(
    String query, {
    AnimeFilters filters = AnimeFilters.none,
    int limit = AnimePageSize.size,
    int page = 1,
  }) async {
    remoteCalls++;
    receivedQueries.add(query);
    receivedFilters.add(filters);

    final failure = remoteFailure;
    if (failure != null) throw failure;

    final preloaded = remotePages;
    if (preloaded != null) {
      final slice = page - 1 < preloaded.length
          ? preloaded[page - 1]
          : const <AnimeEntry>[];
      return AnimePage(
        results: List.unmodifiable(slice),
        hasNext: remoteHasNext,
        total: remoteTotal,
        fromCache: remoteFromCache,
      );
    }

    // Senza pagine preimpostate costruisce i risultati dai dati in memoria,
    // come farebbe Jikan filtrando per testo.
    final trimmed = query.trim().toLowerCase();
    final matched = trimmed.isEmpty
        ? <AnimeEntry>[]
        : _rows.where((entry) {
            final haystack = entry.title.toLowerCase();
            return haystack.contains(trimmed) ||
                (entry.japaneseTitle?.toLowerCase().contains(trimmed) ??
                    false) ||
                entry.genres.any((g) => g.toLowerCase().contains(trimmed));
          }).toList();

    final slice = matched.take(limit).toList();

    return AnimePage(
      results: List.unmodifiable(slice),
      hasNext: remoteHasNext,
      total: remoteTotal ?? matched.length,
      fromCache: remoteFromCache,
    );
  }

  @override
  Future<List<AnimeEntry>> currentSeason({
    int limit = AnimePageSize.size,
    String? genre,
  }) async {
    seasonCalls++;
    final failure = seasonFailure;
    if (failure != null) throw failure;

    final recent = _rows.where((entry) {
      if (genre != null && genre.isNotEmpty && !entry.genres.contains(genre)) {
        return false;
      }
      return entry.status == AnimeAirStatus.airing || entry.isRecentAt(_now);
    }).toList();

    return List.unmodifiable(recent.take(limit));
  }

  int recentEpisodesCalls = 0;

  /// Anime restituiti dalla RPC "nuovi episodi" finta.
  List<AnimeEntry> recentEpisodesResult = const [];

  @override
  Future<List<AnimeEntry>> recentEpisodes({int limit = 20}) async {
    recentEpisodesCalls++;
    return List.unmodifiable(recentEpisodesResult.take(limit));
  }

  int popularCalls = 0;

  /// Anime restituiti dalla query "più popolari" finta.
  ///
  /// `null` significa "ordina davvero i dati in memoria per popolarita'": un
  /// test che vuole verificare l'ordinamento lascia il campo vuoto, uno che
  /// vuole controllare quali titoli compaiono lo riempie.
  List<AnimeEntry>? popularResult;

  AnimeFailure? popularFailure;

  @override
  Future<List<AnimeEntry>> popular({int limit = 20}) async {
    popularCalls++;
    final failure = popularFailure;
    if (failure != null) throw failure;

    final pool =
        popularResult ??
        ([..._rows]
          ..sort(
            (a, b) => (b.popularity ?? 0).compareTo(a.popularity ?? 0),
          ));

    return List.unmodifiable(pool.take(limit));
  }

  @override
  Future<List<AnimeGenre>> genres() async {
    genresCalls++;
    final failure = genresFailure;
    if (failure != null) throw failure;
    return List.unmodifiable(genresResult);
  }

  @override
  Future<AnimeCatalogStats> stats() async {
    statsCalls++;
    final failure = statsFailure;
    if (failure != null) throw failure;
    return statsResult;
  }

  @override
  Future<AnimeEdgeHealth> checkEdge() async {
    edgeChecks++;
    return edgeResult;
  }

  int relatedCalls = 0;

  /// Relazioni restituite dalla RPC finta.
  List<RelatedAnime> relatedResult = const [];

  @override
  Future<List<RelatedAnime>> related(String animeId) async {
    relatedCalls++;
    return relatedResult;
  }

  int watchOrderCalls = 0;

  /// Ordine di visione restituito dalla RPC finta.
  List<WatchOrderItem> watchOrderResult = const [];

  @override
  Future<List<WatchOrderItem>> watchOrder(String animeId) async {
    watchOrderCalls++;
    return watchOrderResult;
  }

  /// Riferimento temporale per "uscito di recente".
  ///
  /// Fisso e non `DateTime.now()`: i test devono dare lo stesso risultato
  /// oggi e tra un anno.
  static final DateTime _now = DateTime(2026, 10, 1);

  /// Applica gli stessi filtri della RPC.
  ///
  /// Le regole sono identiche a `anime_matches_filters`: i generi sono AND, e un
  /// valore assente non soddisfa un filtro che lo richiede.
  bool _matches(AnimeEntry entry, String query, AnimeFilters filters) {
    final trimmed = query.trim().toLowerCase();
    if (trimmed.isNotEmpty) {
      final haystack = [
        entry.title,
        if (entry.japaneseTitle != null) entry.japaneseTitle!,
        ...entry.genres,
      ].join(' ').toLowerCase();
      if (!haystack.contains(trimmed)) return false;
    }

    for (final genre in filters.genres) {
      if (!entry.genres.contains(genre)) return false;
    }

    if (filters.mediaType != null && entry.mediaType != filters.mediaType) {
      return false;
    }
    if (filters.season != null && entry.season != filters.season) return false;
    if (filters.status != null && entry.status != filters.status) return false;
    if (filters.yearFrom != null &&
        (entry.year == null || entry.year! < filters.yearFrom!)) {
      return false;
    }
    if (filters.yearTo != null &&
        (entry.year == null || entry.year! > filters.yearTo!)) {
      return false;
    }
    if (filters.minScore != null &&
        (entry.score == null || entry.score! < filters.minScore!)) {
      return false;
    }
    if (filters.minEpisodes != null &&
        (entry.episodes == null || entry.episodes! < filters.minEpisodes!)) {
      return false;
    }
    if (filters.maxEpisodes != null &&
        (entry.episodes == null || entry.episodes! > filters.maxEpisodes!)) {
      return false;
    }

    return true;
  }
}

/// Helper per costruire entry nei test.
///
/// I valori di default sono scelti perche' un anime di prova realistico
/// passi i filtri piu' comuni: senza episodi non si puo' provare il filtro
/// episodi, senza generi non quello sui generi.
AnimeEntry animeFixture({
  String externalId = '1',
  String? id,
  String title = 'Anime di prova',
  String? japaneseTitle,
  String? synopsis,
  String? imageUrl,
  int? episodes = 12,
  AnimeAirStatus? status = AnimeAirStatus.finished,
  int? year = 2024,
  List<String> genres = const ['Action'],
  AnimeMediaType? mediaType = AnimeMediaType.tv,
  AnimeSeason? season = AnimeSeason.spring,
  DateTime? airedFrom,
  DateTime? airedTo,
  double? score = 8.0,
  int? scoredBy = 1000,
  int? popularity = 5000,
  String? duration = '24 min',
  String? studio,
  double? similarity,
  bool inCatalog = true,
}) => AnimeEntry(
  externalId: externalId,
  id: id ?? 'id-$externalId',
  title: title,
  japaneseTitle: japaneseTitle,
  synopsis: synopsis,
  imageUrl: imageUrl,
  episodes: episodes,
  status: status,
  year: year,
  genres: genres,
  mediaType: mediaType,
  season: season,
  airedFrom: airedFrom ?? DateTime(2024, 1, 6),
  airedTo: airedTo,
  score: score,
  scoredBy: scoredBy,
  popularity: popularity,
  duration: duration,
  studio: studio,
  similarity: similarity,
  inCatalog: inCatalog,
);
