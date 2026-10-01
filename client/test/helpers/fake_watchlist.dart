import 'package:animerank/features/watchlist/data/watchlist_repository.dart';
import 'package:animerank/features/watchlist/domain/watchlist.dart';

/// Watchlist finta per i test.
///
/// Tiene le voci in una mappa per `anime_id` e replica le regole del backend
/// sui limiti: se il finto accettasse un numero di episodi che il trigger
/// rifiuterebbe, i test passerebbero mentre l'app mostrerebbe un errore.
class FakeWatchlistRepository implements WatchlistRepository {
  FakeWatchlistRepository({List<WatchlistEntry>? initial})
      : _entries = {
          for (final e in initial ?? const <WatchlistEntry>[]) e.animeId: e,
        };

  final Map<String, WatchlistEntry> _entries;

  int entriesCalls = 0;
  int totalsCalls = 0;

  /// Anime rimossi, nell'ordine delle chiamate.
  List<String> removed = [];

  /// Cambiamenti di stato, come "animeId|stato".
  List<String> statusChanges = [];

  /// Cambiamenti di episodi, come "animeId|numero".
  List<String> episodeChanges = [];

  /// Cambiamenti di preferito, come "animeId|true|false".
  List<String> favoriteChanges = [];

  WatchlistFailure? entriesFailure;
  WatchlistFailure? totalsFailure;

  /// Fallimento di ogni scrittura: la schermata usa gli stessi codici per
  /// stato, episodi, preferito e rimozione, quindi un solo interruttore basta
  /// e un test per uno solo non copre gli altri tre.
  WatchlistFailure? writeFailure;

  WatchlistTotals totalsResult = const WatchlistTotals();

  @override
  Future<List<WatchlistEntry>> entries(String groupId) async {
    entriesCalls++;

    final failure = entriesFailure;
    if (failure != null) throw failure;

    return List.unmodifiable(_entries.values.where((e) => e.groupId == groupId));
  }

  @override
  Future<WatchlistTotals> totals(String groupId) async {
    totalsCalls++;

    final failure = totalsFailure;
    if (failure != null) throw failure;

    return totalsResult;
  }

  @override
  Future<void> setStatus(String groupId, String animeId, WatchStatus status) async {
    _fail('status');
    statusChanges.add('$animeId|${status.wire}');

    final existing = _entries[animeId];
    _entries[animeId] = existing == null
        ? WatchlistEntry(
            id: animeId,
            groupId: groupId,
            animeId: animeId,
            status: status,
          )
        : existing.copyWith(status: status);
  }

  @override
  Future<void> setEpisode(String groupId, String animeId, int episode) async {
    _fail('episode');

    final existing = _entries[animeId];
    final error = WatchlistValidators.episodeError(episode: episode, total: existing?.episodes);
    if (error != null) throw WatchlistFailure(error);

    episodeChanges.add('$animeId|$episode');
    if (existing != null) {
      _entries[animeId] = existing.copyWith(currentEpisode: episode);
    }
  }

  @override
  Future<void> setFavorite(String groupId, String animeId, bool isFavorite) async {
    _fail('favorite');
    favoriteChanges.add('$animeId|$isFavorite');

    final existing = _entries[animeId];
    if (existing != null) {
      _entries[animeId] = existing.copyWith(isFavorite: isFavorite);
    }
  }

  @override
  Future<void> remove(String groupId, String animeId) async {
    _fail('remove');
    removed.add(animeId);
    _entries.remove(animeId);
  }

  void _fail(String operation) {
    final failure = writeFailure;
    if (failure != null) throw failure;
  }
}

/// Voce di watchlist di comodo per i test.
WatchlistEntry buildWatchlistEntry({
  String animeId = 'a1',
  String groupId = 'g1',
  WatchStatus status = WatchStatus.watching,
  int currentEpisode = 5,
  bool isFavorite = false,
  String title = 'Cowboy Bebop',
  int? episodes = 12,
  bool airing = false,
}) =>
    WatchlistEntry(
      id: 'w-$animeId',
      groupId: groupId,
      animeId: animeId,
      status: status,
      currentEpisode: currentEpisode,
      isFavorite: isFavorite,
      title: title,
      episodes: episodes,
      year: 1998,
      airing: airing,
    );
