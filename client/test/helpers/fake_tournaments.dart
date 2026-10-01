import 'package:animerank/features/tournaments/data/tournaments_repository.dart';
import 'package:animerank/features/tournaments/domain/tournaments.dart';

/// Tornei finti per i test.
///
/// Il bracket e' generato come fa `create_tournament` (tutti i turni subito,
/// anime solo al primo) e la votazione risolve le partite a cascata come
/// `resolve_tournament_match`: un test che passa qui non puo' nascondere una
/// schermata che mostra turni vuoti in modo diverso dal backend.
class FakeTournamentsRepository implements TournamentsRepository {
  FakeTournamentsRepository({
    List<Tournament>? tournaments,
    List<TournamentMatch>? matches,
    List<TournamentStanding>? standings,
    List<TournamentVote>? votes,
    this.currentUserId = 'u1',
  })  : _tournaments = List.of(tournaments ?? const <Tournament>[]),
        _matches = List.of(matches ?? const <TournamentMatch>[]),
        _standings = List.of(standings ?? const <TournamentStanding>[]),
        _votes = List.of(votes ?? const <TournamentVote>[]);

  final List<Tournament> _tournaments;
  final List<TournamentMatch> _matches;
  final List<TournamentStanding> _standings;
  final List<TournamentVote> _votes;

  @override
  final String currentUserId;

  int listCalls = 0;
  int bracketCalls = 0;
  int votesCalls = 0;
  int standingsCalls = 0;

  /// Voti emessi, come "scontro|anime".
  List<String> castVotes = [];

  /// Tornei creati, come "nome|numeroAnime".
  List<String> created = [];

  /// Tornei eliminati.
  List<String> deleted = [];

  TournamentsFailure? listFailure;
  TournamentsFailure? bracketFailure;
  TournamentsFailure? votesFailure;
  TournamentsFailure? standingsFailure;
  TournamentsFailure? createFailure;
  TournamentsFailure? voteFailure;
  TournamentsFailure? deleteFailure;

  /// Membri del gruppo: se il numero e' uguale ai voti ricevuti lo scontro si
  /// chiude, come in `resolve_tournament_match`.
  int memberCount = 1;

  /// true se l'ultimo voto ha chiuso il suo scontro.
  ///
  /// Esposto perche' la schermata lo annuncia: senza, un test non distinguerebbe
  /// "voto registrato" da "scontro chiuso e vincente avanti".
  bool lastVoteClosed = false;

  @override
  Future<List<Tournament>> list(String groupId) async {
    listCalls++;

    final failure = listFailure;
    if (failure != null) throw failure;

    return List.unmodifiable(_tournaments.where((t) => t.groupId == groupId));
  }

  @override
  Future<TournamentBracket> bracket(String tournamentId) async {
    bracketCalls++;

    final failure = bracketFailure;
    if (failure != null) throw failure;

    final tournament = _tournaments.where((t) => t.id == tournamentId);
    if (tournament.isEmpty) {
      throw const TournamentsFailure('Torneo non trovato.');
    }

    return TournamentBracket.parse(
      tournament: tournament.first,
      matchRows: [
        for (final match in _matches.where((m) => m.tournamentId == tournamentId))
          {
            'id': match.id,
            'tournament_id': match.tournamentId,
            'round_number': match.roundNumber,
            'match_number': match.matchNumber,
            'status': match.status.wire,
            'anime_a_id': match.animeAId,
            'anime_b_id': match.animeBId,
            'anime_a': {'title': match.animeATitle, 'image_url': match.animeAImageUrl},
            'anime_b': {'title': match.animeBTitle, 'image_url': match.animeBImageUrl},
            'winner_anime_id': match.winnerAnimeId,
            'next_slot': match.nextSlot,
            'finished_at': match.finishedAt?.toIso8601String(),
          },
      ],
    );
  }

  @override
  Future<List<TournamentVote>> votes(List<String> matchIds) async {
    votesCalls++;

    final failure = votesFailure;
    if (failure != null) throw failure;

    return List.unmodifiable(_votes.where((v) => matchIds.contains(v.matchId)));
  }

  @override
  Future<List<TournamentStanding>> standings(String tournamentId) async {
    standingsCalls++;

    final failure = standingsFailure;
    if (failure != null) throw failure;

    return List.unmodifiable(_standings);
  }

  @override
  Future<Tournament> create({
    required String groupId,
    required String name,
    required List<String> animeIds,
  }) async {
    final nameError = TournamentValidators.nameError(name);
    if (nameError != null) throw TournamentsFailure(nameError);

    final participantsError = TournamentValidators.participantsError(animeIds);
    if (participantsError != null) throw TournamentsFailure(participantsError);

    final failure = createFailure;
    if (failure != null) throw failure;

    created.add('$name|${animeIds.length}');

    final tournament = buildTournament(
      id: 't${_tournaments.length + 1}',
      groupId: groupId,
      name: name,
      bracketSize: animeIds.length,
    );
    _tournaments.add(tournament);

    // Le partite del primo turno nascono con il bracket, come in SQL: senza,
    // la schermata aprirebbe un tabellone vuoto dopo la creazione.
    final pairs = animeIds.length ~/ 2;
    for (var i = 0; i < pairs; i++) {
      _matches.add(
        buildMatch(
          id: 'm${_matches.length + 1}',
          tournamentId: tournament.id,
          roundNumber: 1,
          matchNumber: i + 1,
          animeAId: animeIds[i * 2],
          animeBId: animeIds[i * 2 + 1],
          animeATitle: 'Anime ${animeIds[i * 2]}',
          animeBTitle: 'Anime ${animeIds[i * 2 + 1]}',
        ),
      );
    }

    return tournament;
  }

  @override
  Future<bool> vote({required String matchId, required String animeId}) async {
    final failure = voteFailure;
    if (failure != null) throw failure;

    final index = _votes.indexWhere(
      (v) => v.matchId == matchId && v.userId == currentUserId,
    );
    if (index >= 0) {
      _votes[index] = TournamentVote(
        matchId: matchId,
        userId: currentUserId,
        animeId: animeId,
      );
    } else {
      _votes.add(TournamentVote(matchId: matchId, userId: currentUserId, animeId: animeId));
    }
    castVotes.add('$matchId|$animeId');

    // Lo scontro si chiude solo con i voti di tutti i membri, e solo allora il
    // vincente passa al turno dopo.
    lastVoteClosed = _votesForMatch(matchId).length >= memberCount;
    return lastVoteClosed;
  }

  @override
  Future<void> delete(String tournamentId) async {
    final failure = deleteFailure;
    if (failure != null) throw failure;

    deleted.add(tournamentId);
    _tournaments.removeWhere((t) => t.id == tournamentId);
  }

  List<TournamentVote> _votesForMatch(String matchId) =>
      _votes.where((v) => v.matchId == matchId).toList();

  /// Voto gia' registrato su uno scontro.
  TournamentVote? voteOf(String matchId) {
    for (final vote in _votes) {
      if (vote.matchId == matchId && vote.userId == currentUserId) return vote;
    }
    return null;
  }
}

/// Torneo di comodo per i test.
Tournament buildTournament({
  String id = 't1',
  String groupId = 'g1',
  String name = 'Coppa del venerdi',
  TournamentStatus status = TournamentStatus.ongoing,
  int bracketSize = 8,
  String creatorName = 'marco',
  String? championAnimeId,
  String? championTitle,
}) =>
    Tournament(
      id: id,
      groupId: groupId,
      name: name,
      status: status,
      bracketSize: bracketSize,
      createdBy: 'u1',
      creatorName: creatorName,
      championAnimeId: championAnimeId,
      championTitle: championTitle,
      championImageUrl: championTitle == null ? null : 'https://img/champion.jpg',
    );

/// Scontro di comodo per i test.
TournamentMatch buildMatch({
  String id = 'm1',
  String tournamentId = 't1',
  int roundNumber = 1,
  int matchNumber = 1,
  String? animeAId = 'a1',
  String? animeBId = 'a2',
  String? animeATitle = 'Cowboy Bebop',
  String? animeBTitle = 'Trigun',
  TournamentMatchStatus status = TournamentMatchStatus.pending,
  String? winnerAnimeId,
}) =>
    TournamentMatch(
      id: id,
      tournamentId: tournamentId,
      roundNumber: roundNumber,
      matchNumber: matchNumber,
      status: status,
      animeAId: animeAId,
      animeBId: animeBId,
      animeATitle: animeATitle,
      animeBTitle: animeBTitle,
      animeAImageUrl: 'https://img/bebop.jpg',
      animeBImageUrl: 'https://img/trigun.jpg',
      winnerAnimeId: winnerAnimeId,
    );

/// Riga di classifica di comodo per i test.
TournamentStanding buildStanding({
  String animeId = 'a1',
  String title = 'Cowboy Bebop',
  bool isOut = false,
  int matchesWon = 0,
  int votesReceived = 0,
}) =>
    TournamentStanding(
      animeId: animeId,
      title: title,
      isOut: isOut,
      matchesWon: matchesWon,
      votesReceived: votesReceived,
      imageUrl: 'https://img/bebop.jpg',
    );

/// Voto di comodo per i test.
TournamentVote buildVote({
  String matchId = 'm1',
  String userId = 'u1',
  String animeId = 'a1',
}) =>
    TournamentVote(matchId: matchId, userId: userId, animeId: animeId);