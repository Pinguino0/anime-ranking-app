import '../../../core/error/app_failure.dart';

/// Errore sulle operazioni di torneo.
class TournamentsFailure extends AppFailure {
  const TournamentsFailure(super.message, {super.isRetryable});
}

/// Stato del torneo.
///
/// `setup` esiste nello schema ma non e' raggiungibile: `create_tournament`
/// nasce gia' `ongoing` e nessuna funzione ci torna. Resta in domain perche'
/// senza il valore una versione futura del backend che lo usasse mostrerebbe
/// "in corso" per un torneo mai partito.
enum TournamentStatus {
  setup('setup', 'Da iniziare'),
  ongoing('ongoing', 'In corso'),
  completed('completed', 'Concluso');

  const TournamentStatus(this.wire, this.label);

  final String wire;
  final String label;

  static TournamentStatus fromWire(Object? raw) {
    final value = raw is String ? raw : '';
    return switch (value) {
      'completed' => TournamentStatus.completed,
      'setup' => TournamentStatus.setup,
      _ => TournamentStatus.ongoing,
    };
  }
}

/// Stato di uno scontro.
enum TournamentMatchStatus {
  pending('pending'),
  finished('finished');

  const TournamentMatchStatus(this.wire);

  final String wire;

  static TournamentMatchStatus fromWire(Object? raw) =>
      raw == 'finished' ? TournamentMatchStatus.finished : TournamentMatchStatus.pending;
}

/// Un torneo del gruppo.
class Tournament {
  const Tournament({
    required this.id,
    required this.groupId,
    required this.name,
    required this.status,
    required this.bracketSize,
    this.createdBy,
    this.creatorName,
    this.championAnimeId,
    this.championTitle,
    this.championImageUrl,
    this.createdAt,
    this.completedAt,
  });

  final String id;
  final String groupId;
  final String name;
  final TournamentStatus status;
  final int bracketSize;
  final String? createdBy;
  final String? creatorName;
  final String? championAnimeId;
  final String? championTitle;
  final String? championImageUrl;
  final DateTime? createdAt;
  final DateTime? completedAt;

  bool get isCompleted => status == TournamentStatus.completed;

  /// Numero di round del bracket: il log2 della dimensione.
  ///
  /// Non viene dal backend: `create_tournament` genera i turni finche'
  /// 2^n >= bracket_size, quindi si ricava dai due numeri che arrivano.
  int get rounds {
    var size = bracketSize;
    var result = 0;
    while (size > 1) {
      size = size ~/ 2;
      result++;
    }
    return result;
  }

  factory Tournament.parse(Map<String, dynamic> json) {
    final champion = _object(json['champion']);
    final creator = _object(json['creator']);

    return Tournament(
      id: _text(json['id']) ?? '',
      groupId: _text(json['group_id']) ?? '',
      name: _text(json['name']) ?? 'Senza nome',
      status: TournamentStatus.fromWire(json['status']),
      bracketSize: _toInt(json['bracket_size']) ?? 0,
      createdBy: _text(json['created_by']),
      creatorName: _text(creator['username']),
      championAnimeId: _text(json['champion_anime_id']),
      championTitle: _text(champion['title']),
      championImageUrl: _text(champion['image_url']),
      createdAt: _date(json['created_at']),
      completedAt: _date(json['completed_at']),
    );
  }
}

/// Uno scontro del bracket.
///
/// Anime e vincitore arrivano gia' uniti dalla query: mostrarli richiederebbe una
/// richiesta per id su ogni riga, e fra il primo e il secondo render il
/// tabellone mostrerebbe dati diversi.
class TournamentMatch {
  const TournamentMatch({
    required this.id,
    required this.tournamentId,
    required this.roundNumber,
    required this.matchNumber,
    required this.status,
    this.animeAId,
    this.animeBId,
    this.animeATitle,
    this.animeBTitle,
    this.animeAImageUrl,
    this.animeBImageUrl,
    this.winnerAnimeId,
    this.finishedAt,
    this.nextSlot,
  });

  final String id;
  final String tournamentId;
  final int roundNumber;
  final int matchNumber;
  final TournamentMatchStatus status;
  final String? animeAId;
  final String? animeBId;
  final String? animeATitle;
  final String? animeBTitle;
  final String? animeAImageUrl;
  final String? animeBImageUrl;
  final String? winnerAnimeId;
  final DateTime? finishedAt;
  final int? nextSlot;

  bool get isFinished => status == TournamentMatchStatus.finished;

  /// Entrambi i contendenti ci sono: e' l'unico caso in cui si puo' votare.
  ///
  /// Il bracket viene generato interamente all'inizio, quindi dal secondo turno
  /// in poi gli scontri esistono gia' ma sono vuoti: senza questo controllo
  /// l'app offrirebbe di votare per un posto ancora libero.
  bool get isVotable =>
      status == TournamentMatchStatus.pending && animeAId != null && animeBId != null;

  bool hasContender(String? animeId) =>
      animeId != null && (animeId == animeAId || animeId == animeBId);

  bool isWinner(String? animeId) => animeId != null && animeId == winnerAnimeId;

  factory TournamentMatch.parse(Map<String, dynamic> json) {
    final animeA = _object(json['anime_a']);
    final animeB = _object(json['anime_b']);

    return TournamentMatch(
      id: _text(json['id']) ?? '',
      tournamentId: _text(json['tournament_id']) ?? '',
      roundNumber: _toInt(json['round_number']) ?? 0,
      matchNumber: _toInt(json['match_number']) ?? 0,
      status: TournamentMatchStatus.fromWire(json['status']),
      animeAId: _text(json['anime_a_id']),
      animeBId: _text(json['anime_b_id']),
      animeATitle: _text(animeA['title']),
      animeBTitle: _text(animeB['title']),
      animeAImageUrl: _text(animeA['image_url']),
      animeBImageUrl: _text(animeB['image_url']),
      winnerAnimeId: _text(json['winner_anime_id']),
      finishedAt: _date(json['finished_at']),
      nextSlot: _toInt(json['next_slot']),
    );
  }
}

/// Un turno del bracket.
class TournamentRound {
  const TournamentRound({
    required this.number,
    required this.matches,
    required this.totalRounds,
  });

  final int number;
  final List<TournamentMatch> matches;

  /// Round totali del torneo, per dare un nome al turno.
  final int totalRounds;

  /// "Finale", "Semifinali" o "Turno N".
  ///
  /// In un bracket da 8 l'ultimo turno e la finale e il penultimo sono le
  /// semifinali: con i soli numeri l'utente dovrebbe contare le colonne per
  /// capire quale si sta giocando.
  String get label {
    if (number == totalRounds) return 'Finale';
    if (number == totalRounds - 1 && totalRounds >= 2) return 'Semifinali';
    return 'Turno $number';
  }
}

/// Il tabellone completo di un torneo.
///
/// I turni sono derivati, non letti: il backend manda tutte le partite insieme e
/// l'unico modo per sapere a quale turno appartiene una partita e'
/// `round_number`.
class TournamentBracket {
  const TournamentBracket({required this.tournament, required this.rounds});

  final Tournament tournament;
  final List<TournamentRound> rounds;

  int get matchesCount =>
      rounds.fold(0, (sum, round) => sum + round.matches.length);

  /// Scontri aperti, cioe' quelli su cui si puo' ancora votare.
  int get openMatches => rounds.fold(
        0,
        (sum, round) => sum + round.matches.where((m) => m.isVotable).length,
      );

  /// Il torneo e finito e ha un campione.
  bool get hasChampion => tournament.isCompleted && tournament.championAnimeId != null;

  factory TournamentBracket.parse({
    required Tournament tournament,
    required List<Map<String, dynamic>> matchRows,
  }) {
    final byRound = <int, List<TournamentMatch>>{};

    for (final row in matchRows) {
      final match = TournamentMatch.parse(row);
      byRound.putIfAbsent(match.roundNumber, () => []).add(match);
    }

    final numbers = byRound.keys.toList()..sort();
    // I turni sono quelli dichiarati dal torneo (log2 della taglia), non
    // l'ultimo numero letto nelle righe: se mancasse la finale, contando le
    // righe un bracket da 4 mostrerebbe "Semifinali" al posto di "Turno 1".
    final totalRounds = tournament.rounds;

    return TournamentBracket(
      tournament: tournament,
      rounds: [
        for (final number in numbers)
          TournamentRound(
            number: number,
            totalRounds: totalRounds,
            matches: byRound[number]!
              ..sort((a, b) => a.matchNumber.compareTo(b.matchNumber)),
          ),
      ],
    );
  }
}

/// Riga di classifica del torneo, da `tournament_standings`.
class TournamentStanding {
  const TournamentStanding({
    required this.animeId,
    required this.title,
    required this.isOut,
    required this.matchesWon,
    required this.votesReceived,
    this.imageUrl,
  });

  final String animeId;
  final String title;
  final bool isOut;
  final int matchesWon;
  final int votesReceived;
  final String? imageUrl;

  factory TournamentStanding.parse(Map<String, dynamic> json) => TournamentStanding(
        animeId: _text(json['anime_id']) ?? '',
        title: _text(json['title']) ?? 'Senza titolo',
        // Postgres restituisce un boolean come `true`/`false` via PostgREST,
        // ma una colonna boolean puo' arrivare come stringa se letta da un
        // join testuale: `isOut` deve essere un booleano anche in quel caso.
        isOut: json['is_out'] == true || json['is_out'] == 'true',
        matchesWon: _toInt(json['matches_won']) ?? 0,
        votesReceived: _toInt(json['votes_received']) ?? 0,
        imageUrl: _text(json['image_url']),
      );
}

/// Un voto su uno scontro.
class TournamentVote {
  const TournamentVote({
    required this.matchId,
    required this.userId,
    required this.animeId,
  });

  final String matchId;
  final String userId;
  final String animeId;

  factory TournamentVote.parse(Map<String, dynamic> json) => TournamentVote(
        matchId: _text(json['match_id']) ?? '',
        userId: _text(json['user_id']) ?? '',
        animeId: _text(json['anime_id']) ?? '',
      );
}

/// Conteggio dei voti di uno scontro.
///
/// `tournament_matches` non ha colonne di vote e nessuna RPC le restituisce: i
/// numeri si contano sui voti letti dal client. La RLS permette ai membri del
/// gruppo di leggerli, quindi il conteggio e' possibile senza aggregazioni
/// server.
class MatchTally {
  const MatchTally({
    required this.matchId,
    this.votesA = 0,
    this.votesB = 0,
    this.myAnimeId,
  });

  final String matchId;
  final int votesA;
  final int votesB;

  /// Anime votato dall'utente collegato, null se non ha votato.
  final String? myAnimeId;

  int get total => votesA + votesB;

  /// Voti per uno dei due contendenti, 0 se l'id non e' fra i due.
  ///
  /// Il confronto passa per `hasContender`: con un anime nullo o estraneo il
  /// risultato deve essere 0, non il numero dell'altro lato.
  int votesFor(TournamentMatch match, String? animeId) => switch (animeId) {
        null => 0,
        _ when animeId == match.animeAId => votesA,
        _ when animeId == match.animeBId => votesB,
        _ => 0,
      };

  bool isMine(String? animeId) => animeId != null && animeId == myAnimeId;
}

/// Conteggi e voto dell'utente su uno scontro.
typedef MatchTallies = Map<String, MatchTally>;

/// Costruisce i conteggi partendo dai voti grezzi.
///
/// Una funzione e non un metodo di [MatchTally]: il conteggio dipende da quale
/// anime occupa il primo o il secondo slot, e quello e` un dato dello scontro,
/// non del totale.
MatchTallies tallyMatches({
  required List<TournamentMatch> matches,
  required List<TournamentVote> votes,
  required String currentUserId,
}) {
  final byMatch = <String, List<TournamentVote>>{};
  for (final vote in votes) {
    byMatch.putIfAbsent(vote.matchId, () => []).add(vote);
  }

  return {
    for (final match in matches)
      match.id: _tally(match, byMatch[match.id], currentUserId),
  };
}

MatchTally _tally(
  TournamentMatch match,
  List<TournamentVote>? votes,
  String currentUserId,
) {
  var votesA = 0;
  var votesB = 0;
  String? myAnimeId;

  for (final vote in votes ?? const <TournamentVote>[]) {
    if (!match.hasContender(vote.animeId)) continue;
    if (vote.animeId == match.animeAId) {
      votesA++;
    } else {
      votesB++;
    }
    if (vote.userId == currentUserId) myAnimeId = vote.animeId;
  }

  return MatchTally(
    matchId: match.id,
    votesA: votesA,
    votesB: votesB,
    myAnimeId: myAnimeId,
  );
}

/// Controlli di validazione prima di chiamare il backend.
///
/// Replicano i CHECK e le `raise exception` delle RPC: l'utente vede un
/// messaggio in italiano invece di un errore Postgres.
class TournamentValidators {
  const TournamentValidators._();

  /// Dimensioni accettate da `create_tournament`.
  static const List<int> bracketSizes = [2, 4, 8, 16];

  static bool isValidBracketSize(int size) => bracketSizes.contains(size);

  /// 1-60 caratteri dopo il trim (`tournaments_name_length`).
  static String? nameError(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Dai un nome al torneo.';
    if (trimmed.length > 60) return 'Il nome puo essere lungo al massimo 60 caratteri.';
    return null;
  }

  /// Lista di anime da mettere in gara.
  ///
  /// Controlla anche i duplicati: `create_tournament` li rifiuta con 'Nella
  /// lista ci sono anime duplicati', e un anime ripetuto occuperebbe un posto
  /// del bracket senza poter mai vincere.
  static String? participantsError(List<String> animeIds) {
    if (!isValidBracketSize(animeIds.length)) {
      return 'Scegli 2, 4, 8 o 16 anime: una potenza di due, altrimenti il tabellone non si chiude.';
    }

    if (animeIds.toSet().length != animeIds.length) {
      return 'Nella lista ci sono anime duplicati.';
    }

    return null;
  }

/// La taglia ammessa piu' vicina al numero di scelte.
///
/// A parita' di distanza sceglie la taglia maggiore: con 3 scelte aggiungerne
/// una e' meno distruttivo che scartarne una, e con 6 scelte aggiungerne due e'
/// comunque meno fastidioso che toglierne due.
///
/// Serve al pulsante "genera": con 5 scelte porta a 4 o 8, senza far decidere
/// a mano quale delle due ha senso.
  static int nearestBracketSize(int count) {
    var best = bracketSizes.first;
    for (final size in bracketSizes) {
      if ((size - count).abs() <= (best - count).abs()) best = size;
    }
    return best;
  }
}

DateTime? _date(Object? raw) {
  final text = _text(raw);
  return text == null ? null : DateTime.tryParse(text);
}

Map<String, dynamic> _object(Object? raw) =>
    raw is Map ? Map<String, dynamic>.from(raw) : const {};

int? _toInt(Object? raw) => switch (raw) {
      final num n => n.toInt(),
      final String s => int.tryParse(s),
      _ => null,
    };

String? _text(Object? raw) => switch (raw) {
      final String s when s.isNotEmpty => s,
      final num n => '$n',
      _ => null,
    };