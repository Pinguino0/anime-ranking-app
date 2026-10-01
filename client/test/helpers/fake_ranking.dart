import 'package:animerank/features/ranking/data/ranking_repository.dart';
import 'package:animerank/features/ranking/domain/ranking.dart';

/// Repository finto per i test.
///
/// Tiene i dati in memoria e conta le chiamate: i test verificano che la UI
/// chieda davvero al repository e che dopo un voto le schermate dipendanti
/// vengano ricaricate.
class FakeRankingRepository implements RankingRepository {
  FakeRankingRepository({List<RankingEntry>? initial}) : _rows = [...?initial];

  final List<RankingEntry> _rows;

  int rankingCalls = 0;
  int specialCalls = 0;
  int statsCalls = 0;
  int rateCalls = 0;

  /// Argomenti ricevuti, per controllare che la UI passi i dati giusti.
  List<String> requestedGroups = [];
  List<String> specialKinds = [];

  /// Offset iniziali richiesti, in ordine.
  ///
  /// Senza questi una paginazione sbagliata passerebbe il test: si vedrebbe solo
  /// il numero di chiamate, non che la seconda chiede davvero le righe dopo la
  /// prima.
  List<int> offsets = [];

  /// Voti registrati, come "groupId|animeId|score".
  List<String> votes = [];

  RankingFailure? rankingFailure;
  RankingFailure? specialFailure;
  RankingFailure? statsFailure;
  RankingFailure? rateFailure;

  /// Statistiche restituite da [stats].
  ///
  /// Non puo' chiamarsi `stats` come il metodo che lo restituisce: in Dart un
  /// campo e un metodo non possono condividere il nome.
  GroupStats statsResult = const GroupStats();

  @override
  Future<List<RankingEntry>> ranking(String groupId, {int limit = 50, int offset = 0}) async {
    rankingCalls++;
    requestedGroups.add(groupId);
    offsets.add(offset);
    final failure = rankingFailure;
    if (failure != null) throw failure;

    final slice = offset >= _rows.length
        ? const <RankingEntry>[]
        : _rows.skip(offset).take(limit).toList();

    return List.unmodifiable(slice);
  }

  @override
  Future<List<SpecialRankingEntry>> special(
    String groupId,
    SpecialRankingKind kind, {
    int limit = 20,
  }) async {
    specialCalls++;
    requestedGroups.add(groupId);
    specialKinds.add(kind.wire);
    final failure = specialFailure;
    if (failure != null) throw failure;

    // Le speciali si derivano dalle righe normali cosi' il finto resta
    // coerente: se un test cambia una riga e poi legge una speciale, i numeri
    // tornano come con il backend.
    final ordered = switch (kind) {
      SpecialRankingKind.top => [..._rows]
        ..sort((a, b) => (b.meanScore ?? 0).compareTo(a.meanScore ?? 0)),
      SpecialRankingKind.mostVoted => [..._rows]
        ..sort((a, b) => b.voteCount.compareTo(a.voteCount)),
      // Il backend esclude sotto i 3 voti: replicarlo evita che un test
      // passi con righe che il server non restituirebbe.
      SpecialRankingKind.divisive => _rows.where((r) => r.voteCount >= 3).toList(),
    };

    return List.unmodifiable([
      for (final (i, row) in ordered.take(limit).indexed)
        SpecialRankingEntry(
          kind: kind,
          position: i + 1,
          animeId: row.animeId,
          title: row.title,
          imageUrl: row.imageUrl,
          value: switch (kind) {
            SpecialRankingKind.top => row.meanScore ?? 0,
            SpecialRankingKind.mostVoted => row.voteCount.toDouble(),
            SpecialRankingKind.divisive => 0,
          },
          secondary: switch (kind) {
            SpecialRankingKind.top => row.voteCount.toDouble(),
            SpecialRankingKind.mostVoted => row.rankingScore ?? 0,
            SpecialRankingKind.divisive => row.voteCount.toDouble(),
          },
        ),
    ]);
  }

  @override
  Future<GroupStats> stats(String groupId) async {
    statsCalls++;
    requestedGroups.add(groupId);
    final failure = statsFailure;
    if (failure != null) throw failure;
    return statsResult;
  }

  @override
  Future<void> rate(String groupId, String animeId, double score) async {
    rateCalls++;
    votes.add('$groupId|$animeId|$score');
    final failure = rateFailure;
    if (failure != null) throw failure;
  }
}

/// Riga di classifica di comodo per i test.
RankingEntry buildRankingEntry({
  String animeId = 'a1',
  String title = 'Cowboy Bebop',
  int position = 1,
  double? meanScore = 8.5,
  int voteCount = 4,
  double? rankingScore = 8.1,
  double? myScore,
  int positionDelta = 0,
  List<String> genres = const ['Action', 'Space'],
  int? year = 1998,
  int? episodes = 26,
  String? imageUrl,
}) =>
    RankingEntry(
      position: position,
      animeId: animeId,
      title: title,
      imageUrl: imageUrl,
      year: year,
      episodes: episodes,
      genres: genres,
      meanScore: meanScore,
      voteCount: voteCount,
      rankingScore: rankingScore,
      myScore: myScore,
      positionDelta: positionDelta,
    );
