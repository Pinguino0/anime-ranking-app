import '../../../core/error/app_failure.dart';

/// Errore sulle operazioni di classifica.
class RankingFailure extends AppFailure {
  const RankingFailure(super.message, {super.isRetryable});
}

/// Una riga della classifica di un gruppo.
///
/// I campi arrivano gia' aggregati dal backend ([public.group_ranking]): il
/// client non ricalcola medie ne pesi, perche' il peso della classifica dipende
/// dalla media del gruppo e una media fatta sul subset paginato darebbe
/// numeri diversi dalla pagina precedente.
class RankingEntry {
  const RankingEntry({
    required this.position,
    required this.animeId,
    required this.title,
    this.italianTitle,
    this.japaneseTitle,
    this.imageUrl,
    this.episodes,
    this.year,
    this.genres = const [],
    this.meanScore,
    this.voteCount = 0,
    this.rankingScore,
    this.myScore,
    this.positionDelta = 0,
  });

  final int position;
  final String animeId;
  final String title;

  /// Titolo italiano, se il catalogo lo conosce. La UI usa [displayTitle].
  final String? italianTitle;
  final String? japaneseTitle;
  final String? imageUrl;
  final int? episodes;
  final int? year;
  final List<String> genres;

  /// Media dei voti del gruppo sull'anime.
  final double? meanScore;

  /// Quante persone hanno votato questo anime nel gruppo.
  final int voteCount;

  /// Punteggio pesato: e' questo il valore che ordina la classifica.
  ///
  /// Non coincide con [meanScore] perche' la media e' "spinta" verso la media
  /// del gruppo, quindi un anime con un solo voto non balza in cima solo per
  /// quello.
  final double? rankingScore;

  /// Il voto dell'utente collegato, se ha votato.
  final double? myScore;

  /// Variazione di posizione rispetto allo snapshot di ieri.
  ///
  /// Positivo significa salita, negativo discesa. Il backend restituisce 0
  /// quando non esiste ancora uno snapshot: non c'e' nulla da confrontare, e
  /// mostrare "-3" per un anime che era primo ieri e primo oggi sarebbe falso.
  final int positionDelta;

  bool get hasMyVote => myScore != null;
  bool get movedUp => positionDelta > 0;
  bool get movedDown => positionDelta < 0;

  /// Titolo mostrato all'utente: italiano se disponibile, altrimenti il titolo
  /// del catalogo. Un solo punto di scelta, come in [AnimeEntry].
  String get displayTitle => italianTitle ?? title;

  /// Testo del voto, senza forzare i decimali inutili.
  ///
  /// La colonna e' numeric: 8.00 e 8 sono lo stesso numero, e mostrare "8.00"
  /// accanto a "7.50" fa sembrare diverse due voti uguali.
  String? get meanScoreLabel => _formatScore(meanScore);

  String? get myScoreLabel => _formatScore(myScore);

  /// Punteggio pesato formattato per la tabella, con "-" se assente.
  ///
  /// Non nullable come gli altri: nella tabella una cella vuota sembrerebbe un
  /// valore perso, mentre "-" dice chiaramente che il dato non c'e'.
  String get rankingScoreLabel => _formatScore(rankingScore) ?? '-';

  static String? _formatScore(double? value) {
    if (value == null) return null;
    final text = value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toStringAsFixed(2);
    // toStringAsFixed(2) aggiunge due zeri: "7.50" va bene, "7.00" no.
    return text.endsWith('.00') ? value.toStringAsFixed(0) : text.replaceFirst(RegExp(r'0$'), '');
  }

  factory RankingEntry.parse(Map<String, dynamic> json) => RankingEntry(
        position: _toInt(json['rank_position']) ?? 0,
        animeId: '${json['anime_id']}',
        title: json['title'] as String? ?? 'Senza titolo',
        italianTitle: json['title_it'] as String?,
        japaneseTitle: json['japanese_title'] as String?,
        imageUrl: json['image_url'] as String?,
        episodes: _toInt(json['episodes']),
        year: _toInt(json['year']),
        genres: [for (final g in (json['genres'] as List? ?? const [])) '$g'],
        meanScore: _toDouble(json['mean_score']),
        voteCount: _toInt(json['vote_count']) ?? 0,
        rankingScore: _toDouble(json['ranking_score']),
        myScore: _toDouble(json['my_score']),
        positionDelta: _toInt(json['position_delta']) ?? 0,
      );

  @override
  bool operator ==(Object other) => other is RankingEntry && other.animeId == animeId;

  @override
  int get hashCode => animeId.hashCode;
}

/// Le classifiche "speciali" piu' citate.
///
/// Sono tre query quasi identiche che il backend espone come una sola
/// ([public.special_rankings]): qui sono un enum perche' il nome viaggia come
/// stringa e un valore libero allowerebbe di scrivere "most-voted" per errore
/// ricevendo silenziosamente zero righe.
enum SpecialRankingKind {
  top('top', 'I più votati dal gruppo', 'Media pesata: i titoli che il gruppo ama di più.'),
  mostVoted('most_voted', 'I più discussi', 'Più anime hanno ricevuto un voto in assoluto.'),
  divisive('divisive', 'I più divisivi', 'Dove le opinioni divergono di più. Almeno 3 voti.');

  const SpecialRankingKind(this.wire, this.title, this.description);

  /// Valore da passare al backend.
  final String wire;
  final String title;
  final String description;

  static SpecialRankingKind fromWire(String? raw) =>
      SpecialRankingKind.values.firstWhere((k) => k.wire == raw, orElse: () => SpecialRankingKind.top);
}

/// Una riga di classifica speciale.
///
/// Il backend espone le tre classifiche con le stesse due colonne (`value` e
/// `secondary`) e cambia solo il significato, scambiandole dove serve. Per
/// questo [kind] fa parte della riga: senza, non c'e' modo di sapere se 8.5
/// indica una media o una distanza, e l'etichetta sarebbe inventata.
class SpecialRankingEntry {
  const SpecialRankingEntry({
    required this.kind,
    required this.position,
    required this.animeId,
    required this.title,
    this.italianTitle,
    this.imageUrl,
    required this.value,
    required this.secondary,
  });

  final SpecialRankingKind kind;
  final int position;
  final String animeId;
  final String title;

  /// Titolo italiano, se il catalogo lo conosce. La UI usa [displayTitle].
  final String? italianTitle;
  final String? imageUrl;

  /// Titolo mostrato all'utente: italiano se disponibile, altrimenti il titolo
  /// del catalogo.
  String get displayTitle => italianTitle ?? title;

  /// Metrica principale, quella su cui e' ordinata la classifica.
  final double value;

  /// Metrica di contorno.
  final double secondary;

  factory SpecialRankingEntry.parse(Map<String, dynamic> json, {required SpecialRankingKind kind}) =>
      SpecialRankingEntry(
        kind: kind,
        position: _toInt(json['rank_position']) ?? 0,
        animeId: '${json['anime_id']}',
        title: json['title'] as String? ?? 'Senza titolo',
        italianTitle: json['title_it'] as String?,
        imageUrl: json['image_url'] as String?,
        value: _toDouble(json['value']) ?? 0,
        secondary: _toDouble(json['secondary']) ?? 0,
      );

  /// Etichetta e testo formattato della metrica principale.
  (String, String) get valueLabel => switch (kind) {
        // La media arriva gia' arrotondata a due cifre dal backend: mostrarla
        // com'e' evita di fare un secondo arrotondamento lato client.
        SpecialRankingKind.top => ('Media', _trim(value)),
        SpecialRankingKind.mostVoted => ('Voti', value.round().toString()),
        SpecialRankingKind.divisive => ('Distanza', _trim(value)),
      };

  /// Etichetta e testo formattato della metrica di contorno.
  (String, String) get secondaryLabel => switch (kind) {
        SpecialRankingKind.top => ('Voti', secondary.round().toString()),
        SpecialRankingKind.mostVoted => ('Media', _trim(secondary)),
        SpecialRankingKind.divisive => ('Voti', secondary.round().toString()),
      };

  static String _trim(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
}

/// Totali del gruppo, da [public.group_stats].
///
/// Il backend restituisce un jsonb: le sezioni "miglior anime" e simili sono
/// oggetti annidati che possono valere null (nessun voto, nessun genere), quindi
/// ogni parte va trattata come facoltativa.
class GroupStats {
  const GroupStats({
    this.memberCount = 0,
    this.animeRated = 0,
    this.totalVotes = 0,
    this.groupMean = 0,
    this.topAnime,
    this.mostVotedAnime,
    this.mostDivisiveAnime,
    this.topGenre,
    this.scoreDistribution = const {},
  });

  final int memberCount;
  final int animeRated;
  final int totalVotes;

  /// Media di tutti i voti del gruppo: il riferimento con cui confrontare un
  /// singolo anime.
  final double groupMean;

  final StatsHighlight? topAnime;
  final StatsHighlight? mostVotedAnime;
  final StatsHighlight? mostDivisiveAnime;
  final String? topGenre;

  /// Voti per voto intero: chiavi "0".."10", valori conteggi.
  final Map<int, int> scoreDistribution;

  bool get isEmpty => memberCount == 0 && totalVotes == 0 && animeRated == 0;

  /// Il massimo della distribuzione, per disegnare le barre.
  int get distributionPeak {
    var peak = 0;
    for (final count in scoreDistribution.values) {
      if (count > peak) peak = count;
    }
    return peak;
  }

  factory GroupStats.parse(Map<String, dynamic> json) => GroupStats(
        memberCount: _toInt(json['member_count']) ?? 0,
        animeRated: _toInt(json['anime_rated']) ?? 0,
        totalVotes: _toInt(json['total_votes']) ?? 0,
        groupMean: _toDouble(json['group_mean']) ?? 0,
        topAnime: _highlight(json['top_anime']),
        mostVotedAnime: _highlight(json['most_voted_anime']),
        mostDivisiveAnime: _highlight(json['most_divisive_anime']),
        topGenre: json['top_genre'] as String?,
        scoreDistribution: _distribution(json['score_distribution']),
      );

  /// Chiavi della distribuzione dei voti.
  ///
  /// Il backend manda una `jsonb_object_agg` su `floor(score)::int`, quindi le
  /// chiavi sono stringhe numeriche ("7", non 7). Una chiave che non si
  /// convertsi viene scartata: una barra con una chiave "null" non saprebbe
  /// dove scriversi.
  static Map<int, int> _distribution(Object? raw) {
    if (raw is! Map) return const {};

    final result = <int, int>{};
    for (final entry in raw.entries) {
      final score = int.tryParse('${entry.key}');
      if (score != null) result[score] = _toInt(entry.value) ?? 0;
    }
    return result;
  }

  static StatsHighlight? _highlight(Object? raw) {
    if (raw is! Map) return null;
    return StatsHighlight(
      animeId: '${raw['anime_id']}',
      title: raw['title'] as String? ?? 'Senza titolo',
      italianTitle: raw['title_it'] as String?,
      imageUrl: raw['image_url'] as String?,
      value: _toDouble(raw['mean'] ?? raw['votes'] ?? raw['spread']),
    );
  }
}

/// Un anime citato nelle statistiche di gruppo.
class StatsHighlight {
  const StatsHighlight({
    required this.animeId,
    required this.title,
    this.italianTitle,
    this.imageUrl,
    this.value,
  });

  final String animeId;
  final String title;

  /// Titolo italiano, se il catalogo lo conosce. La UI usa [displayTitle].
  final String? italianTitle;
  final String? imageUrl;

  /// Titolo mostrato all'utente: italiano se disponibile, altrimenti il titolo
  /// del catalogo.
  String get displayTitle => italianTitle ?? title;

  /// La metrica che caratterizza questa voce: media, voti o distanza, a seconda
  /// della sezione. Il backend manda una chiave diversa in ogni caso e qui si
  /// tiene solo il numero, con l'etichetta a carico della UI.
  final double? value;
}

/// Regole sui voti.
///
/// Replica [public.is_valid_rating]: 0..10 con passo 0.5. Un voto di 7.3
/// sembra ragionevole all'utente ma il CHECK del database lo rifiuta, quindi si
/// blocca qui: altrimenti l'errore arriverebbe dopo aver gia' mostrato la
/// classifica ottimistica.
class RatingValidators {
  const RatingValidators._();

  static const double min = 0;
  static const double max = 10;
  static const double step = 0.5;

  /// true se il voto e' accettato dal database.
  static bool isValid(double value) =>
      value >= min && value <= max && (value * 2) % 1 == 0;

  static String? error(double value) {
    if (value < min || value > max) return 'Il voto va da 0 a 10.';
    if (!isValid(value)) return 'Il voto va a passo $step.';
    return null;
  }
}

/// Conversione da numeric/bigint di Postgres.
///
/// Il driver JSON restituisce i numeri come `int` quando sono interi e `double`
/// quando hanno decimali, e per gli interi grandi arriva come `num` che puo'
/// eccedere il range di `int`. Trattarli con `as num` senza controllo fa
/// crashare il parsing su una risposta valida.
int? _toInt(Object? raw) => switch (raw) {
      final num n => n.toInt(),
      final String s => int.tryParse(s),
      _ => null,
    };

double? _toDouble(Object? raw) => switch (raw) {
      final num n => n.toDouble(),
      final String s => double.tryParse(s),
      _ => null,
    };
