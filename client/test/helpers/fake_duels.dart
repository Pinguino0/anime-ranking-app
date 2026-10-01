import 'package:animerank/features/duels/data/duels_repository.dart';
import 'package:animerank/features/duels/domain/duels.dart';

/// Duelli finti per i test.
///
/// Non e' una mappa di risposte gia' scritte: ricalcola l'Elo partendo dai
/// duelli registrati, con la stessa formula di `duel_elo` (`start + K * (S - E)`
/// applicata a entrambi i contendenti). Cosi' i test su schermata vedono la
/// classifica che si muove davvero dopo una scelta, e un test che passa qui non
/// puo' nascondere un Elo calcolato in modo diverso dal backend.
class FakeDuelsRepository implements DuelsRepository {
  FakeDuelsRepository({
    List<DuelPair>? pairs,
    List<DuelStanding>? standings,
  })  : _pairs = List.of(pairs ?? const <DuelPair>[]),
        _fixedStandings = standings == null ? null : List.of(standings);

  final List<DuelPair> _pairs;

  /// Classifica imposta a mano, se c'e'.
  ///
  /// Serve per i test di sola schermata (posizioni, formattazione, stato
  /// vuoto) senza dover registrare duelli per ottenerla.
  final List<DuelStanding>? _fixedStandings;

  /// Un duello registrato: chi lo ha fatto, fra quali due anime e chi ha scelto.
  final List<_PlayedDuel> _played = [];

  int nextPairCalls = 0;
  int standingsCalls = 0;

  /// Scelte registrate, come "coppia|scelto".
  List<String> played = [];

  DuelsFailure? nextPairFailure;
  DuelsFailure? standingsFailure;
  DuelsFailure? playFailure;

  @override
  Future<DuelPair?> nextPair(String groupId) async {
    nextPairCalls++;

    final failure = nextPairFailure;
    if (failure != null) throw failure;

    // Come `next_duel_pair`: salta le coppie non giocabili (due id uguali o
    // vuoti) e quelle gia' giocate da questo utente.
    for (final pair in _pairs) {
      if (!pair.isPlayable) continue;
      if (_hasPlayed(pair)) continue;
      return pair;
    }

    return null;
  }

  @override
  Future<List<DuelStanding>> standings(String groupId) async {
    standingsCalls++;

    final failure = standingsFailure;
    if (failure != null) throw failure;

    final fixed = _fixedStandings;
    if (fixed != null) return List.unmodifiable(fixed);

    return _computeStandings();
  }

  @override
  Future<void> play(String groupId, DuelPair pair, String selectedAnimeId) async {
    final failure = playFailure;
    if (failure != null) throw failure;

    final error = pair.validate(selectedAnimeId);
    if (error != null) throw error;

    played.add('${pair.animeAId}/${pair.animeBId}|$selectedAnimeId');
    _played.add(_PlayedDuel(
      animeAId: pair.animeAId,
      animeBId: pair.animeBId,
      selectedAnimeId: selectedAnimeId,
      titles: {pair.animeAId: pair.titleA, pair.animeBId: pair.titleB},
    ));
  }

  bool _hasPlayed(DuelPair pair) => _played.any(
        (d) =>
            (d.animeAId == pair.animeAId && d.animeBId == pair.animeBId) ||
            (d.animeAId == pair.animeBId && d.animeBId == pair.animeAId),
      );

  /// Ricalcola la classifica come fa la funzione SQL.
  List<DuelStanding> _computeStandings() {
    final elo = <String, int>{};
    final counts = <String, int>{};
    final titles = <String, String>{};

    for (final duel in _played) {
      titles[duel.animeAId] = duel.titles[duel.animeAId] ?? 'Senza titolo';
      titles[duel.animeBId] = duel.titles[duel.animeBId] ?? 'Senza titolo';

      final eloA = elo[duel.animeAId] ?? DuelElo.starting;
      final eloB = elo[duel.animeBId] ?? DuelElo.starting;
      final expectedA = _expected(eloA, eloB);
      final expectedB = _expected(eloB, eloA);

      final scoreA = duel.selectedAnimeId == duel.animeAId ? 1 : 0;
      final scoreB = duel.selectedAnimeId == duel.animeBId ? 1 : 0;

      elo[duel.animeAId] = (eloA + DuelElo.factor * (scoreA - expectedA)).round();
      elo[duel.animeBId] = (eloB + DuelElo.factor * (scoreB - expectedB)).round();
      counts[duel.animeAId] = (counts[duel.animeAId] ?? 0) + 1;
      counts[duel.animeBId] = (counts[duel.animeBId] ?? 0) + 1;
    }

    final rows = [
      for (final entry in elo.entries)
        DuelStanding(
          // La posizione la calcola il client: `duel_elo` restituisce gia'
          // l'elenco ordinato senza numeri.
          position: 0,
          animeId: entry.key,
          title: titles[entry.key] ?? 'Senza titolo',
          elo: entry.value,
          duelCount: counts[entry.key] ?? 0,
        ),
    ]..sort((a, b) {
        final byElo = b.elo.compareTo(a.elo);
        return byElo != 0 ? byElo : a.animeId.compareTo(b.animeId);
      });

    return [
      for (var i = 0; i < rows.length && i < DuelsPage.size; i++)
        DuelStanding(
          position: i + 1,
          animeId: rows[i].animeId,
          title: rows[i].title,
          elo: rows[i].elo,
          duelCount: rows[i].duelCount,
        ),
    ];
  }

  /// Probabilita' attesa di vittoria dell'anime con [elo] contro [opponentElo].
  static double _expected(int elo, int opponentElo) =>
      1 / (1 + _pow10((opponentElo - elo) / 400));

  static double _pow10(double exponent) {
    var result = 1.0;
    var steps = exponent;
    while (steps > 0) {
      result *= 10;
      steps -= 1;
    }
    while (steps < 0) {
      result /= 10;
      steps += 1;
    }
    return result;
  }
}

class _PlayedDuel {
  const _PlayedDuel({
    required this.animeAId,
    required this.animeBId,
    required this.selectedAnimeId,
    required this.titles,
  });

  final String animeAId;
  final String animeBId;
  final String selectedAnimeId;
  final Map<String, String> titles;
}

/// Coppia di comodo per i test.
DuelPair buildDuelPair({
  String animeAId = 'a1',
  String animeBId = 'a2',
  String titleA = 'Cowboy Bebop',
  String titleB = 'Trigun',
  String? imageA = 'https://img/bebop.jpg',
  String? imageB = 'https://img/trigun.jpg',
}) =>
    DuelPair(
      animeAId: animeAId,
      animeBId: animeBId,
      titleA: titleA,
      titleB: titleB,
      imageA: imageA,
      imageB: imageB,
    );

/// Riga di classifica di comodo per i test.
DuelStanding buildDuelStanding({
  int position = 1,
  String animeId = 'a1',
  String title = 'Cowboy Bebop',
  int elo = 1000,
  int duelCount = 0,
  String? imageUrl = 'https://img/bebop.jpg',
}) =>
    DuelStanding(
      position: position,
      animeId: animeId,
      title: title,
      elo: elo,
      duelCount: duelCount,
      imageUrl: imageUrl,
    );
