import 'package:animerank/features/episodes/data/episodes_repository.dart';
import 'package:animerank/features/episodes/domain/episode.dart';

/// Repository finto degli episodi.
///
/// Tiene in memoria quello che e' stato scritto e conta le chiamate, cosi' i
/// test possano verificare quante volte si e' salvato il progresso: conta e'
/// parte del contratto di [WatchProgressSaver], non un dettaglio.
class FakeEpisodesRepository implements EpisodesRepository {
  FakeEpisodesRepository({
    List<Episode>? episodes,
    Map<String, List<EpisodeSource>>? sourcesByEpisode,
    this.failWith,
  })  : episodes = episodes ?? [],
        sourcesByEpisode = sourcesByEpisode ?? {};

  List<Episode> episodes;

  /// Fonti per id episodio.
  ///
  /// Il nome non puo' essere `sources`: quello e' gia' il metodo
  /// dell'interfaccia, e un campo omonimo lo nasconderebbe — `sources(...)`
  /// chiamerebbe il campo e il finto non implementerebbe piu' il contratto.
  final Map<String, List<EpisodeSource>> sourcesByEpisode;

  /// Se valorizzato, ogni operazione fallisce con questa failure.
  final EpisodesFailure? failWith;

  /// Ultimo progresso scritto: id -> secondi.
  final Map<String, int> savedSeconds = {};

  /// Episodi segnati come finiti.
  final Set<String> completed = {};

  /// Chiamate a [saveProgress], una per salvataggio.
  int progressWrites = 0;

  /// Voti registrati, id episodio -> punteggio.
  final Map<String, double?> ratings = {};

  @override
  Future<List<Episode>> forAnime(String animeId) async {
    _maybeFail();
    return episodes;
  }

  @override
  Future<List<EpisodeSource>> sources(String episodeId) async {
    _maybeFail();
    return sourcesByEpisode[episodeId] ?? const [];
  }

  @override
  Future<double?> rate(String episodeId, double? score) async {
    _maybeFail();
    ratings[episodeId] = score;
    return score;
  }

  @override
  Future<void> saveProgress(
    String episodeId,
    int currentTime, {
    bool? completed,
  }) async {
    _maybeFail();
    progressWrites++;
    savedSeconds[episodeId] = currentTime;
    if (completed ?? false) this.completed.add(episodeId);
  }

  @override
  Future<int?> progress(String episodeId) async => savedSeconds[episodeId];

  void _maybeFail() {
    final failure = failWith;
    if (failure != null) throw failure;
  }
}

/// Un episodio di prova con i campi gia' valorizzati.
Episode episodeFixture({
  String id = 'ep-1',
  int number = 1,
  String? title,
  int sourceCount = 1,
  int progressTime = 0,
  bool isCompleted = false,
  double? myScore,
  double? communityAverage,
  int communityCount = 0,
  bool filler = false,
  bool recap = false,
}) =>
    Episode(
      id: id,
      number: number,
      title: title,
      sourceCount: sourceCount,
      progressTime: progressTime,
      completed: isCompleted,
      myScore: myScore,
      communityAverage: communityAverage,
      communityCount: communityCount,
      filler: filler,
      recap: recap,
    );

/// Una fonte di prova.
EpisodeSource sourceFixture({
  String id = 'src-1',
  String url = 'https://cdn.example/ep1.mp4',
  EpisodeSourceType type = EpisodeSourceType.mp4,
  String? quality = '1080p',
  String? language = 'ita',
}) =>
    EpisodeSource(
      id: id,
      url: url,
      type: type,
      quality: quality,
      language: language,
    );