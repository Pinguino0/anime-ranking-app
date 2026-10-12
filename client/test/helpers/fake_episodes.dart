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
    this.failResolutionWith,
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

  /// Se valorizzato, [resolveSource] fallisce con questa failure.
  ///
  /// Separato da [failWith] perche' i due non capitano insieme: il fallback
  /// automatico del player si prova facendo fallire solo la risoluzione di una
  /// fonte, mentre le liste di episodi devono continuare a funzionare. Con un
  /// solo interruttore non si potrebbe scrivere quel test.
  final SourceResolutionFailure? failResolutionWith;

  /// Risoluzioni per id fonte.
  ///
  /// Se [resolveById] e' valorizzato si usa quello, altrimenti la risposta viene
  /// costruita da [resolvedFor] a partire dall'id della fonte. Il secondo
  /// caso e' il default perche' basta un id per costruire una risposta valida e
  /// i test non devono accorgersi del resolver.
  final Map<String, ResolvedSource> resolvedById = {};

  /// Ultimo progresso scritto: id -> secondi.
  final Map<String, int> savedSeconds = {};

  /// Episodi segnati come finiti.
  final Set<String> completed = {};

  /// Chiamate a [saveProgress], una per salvataggio.
  int progressWrites = 0;

  /// Voti registrati, id episodio -> punteggio.
  final Map<String, double?> ratings = {};

  /// Chiamate a [resolveSource], una per apertura.
  ///
  /// Contate come [progressWrites] perche' il punto del test e' lo stesso: se
  /// il player risolvesse due volte lo stesso episodio consumerebbe due token,
  /// e sul provider vero la seconda chiamata costerebbe una richiesta inutili.
  int resolutionCalls = 0;

  /// Chiamate a [forAnime], una per lettura dell'elenco.
  ///
  /// Serve a verificare che la lista a schermo venga riletta solo quando la
  /// sincronizzazione ha davvero aggiunto qualcosa.
  int forAnimeCalls = 0;

  @override
  Future<List<Episode>> forAnime(String animeId) async {
    _maybeFail();
    forAnimeCalls++;
    return episodes;
  }

  @override
  Future<List<EpisodeSource>> sources(String episodeId) async {
    _maybeFail();
    return sourcesByEpisode[episodeId] ?? const [];
  }

  @override
  Future<ResolvedSource> resolveSource(String sourceId) async {
    resolutionCalls++;

    final failure = failResolutionWith;
    if (failure != null) throw failure;

    final prepared = resolvedById[sourceId];
    if (prepared != null) return prepared;

    return resolvedFor(sourceId);
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

  /// Ultimo riferimento al provider restituito, anime -> record (o `null`).
  final Map<String, EpisodeProviderRef?> providerRefs = {};

  /// Episodi "nuovi" che [syncEpisodes] deve dichiarare, anime -> quanti.
  final Map<String, int> syncAdded = {};

  /// Anime di cui e' stata chiesta la sincronizzazione, in ordine.
  final List<String> syncCalls = [];

  /// Ritardo artificiale di [syncEpisodes].
  ///
  /// Serve a osservare il caso "due giri in parallelo": senza un attesa il
  /// primo giro finirebbe prima che il secondo cominci, e la guardia non
  /// verrebbe mai esercitata.
  Duration syncDelay = Duration.zero;

  @override
  Future<EpisodeProviderRef?> providerRef(String animeId) async {
    _maybeFail();
    return providerRefs[animeId];
  }

  @override
  Future<int> syncEpisodes(String animeId) async {
    _maybeFail();
    syncCalls.add(animeId);
    if (syncDelay > Duration.zero) await Future<void>.delayed(syncDelay);
    return syncAdded[animeId] ?? 0;
  }

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
///
/// Di default ha un `url` gia' riproducibile, che e' il caso semplice e non
/// richiede il resolver. Per provare la risoluzione si passa
/// `canonicalUrl` lasciando `url` a `null`: e' la combinazione che il backend
/// produce davvero, e senza di essa il player prenderebbe sempre la strada
/// diretta e il fallback del resolver non verrebbe mai esercitato.
EpisodeSource sourceFixture({
  String id = 'src-1',
  String? url = 'https://cdn.example/ep1.mp4',
  String? canonicalUrl,
  String? providerSlug,
  String? providerLabel,
  EpisodeSourceType type = EpisodeSourceType.mp4,
  String? quality = '1080p',
  String? language = 'ita',
}) =>
    EpisodeSource(
      id: id,
      url: url,
      canonicalUrl: canonicalUrl,
      providerSlug: providerSlug,
      providerLabel: providerLabel,
      type: type,
      quality: quality,
      language: language,
    );

/// Una risoluzione di prova.
///
/// La scadenza e' lontana di proposito: un test che verifica il fallback non
/// deve diventare rosso solo perche' e' passato un minuto, e il caso del link
/// gia' scaduto ha un test suo.
ResolvedSource resolvedFor(
  String sourceId, {
  String url = 'https://cdn.example/ep1.mp4?token=abc',
  EpisodeSourceType sourceType = EpisodeSourceType.mp4,
  Map<String, String>? headers,
  Duration expiresIn = const Duration(minutes: 5),
}) =>
    ResolvedSource(
      sourceId: sourceId,
      resolvedUrl: url,
      headers: headers ??
          const {
            'Referer': 'https://example.com/',
            'Authorization': 'Bearer abc',
          },
      sourceType: sourceType,
      canonicalUrl: 'https://api.example.com/watch/$sourceId',
      providerSlug: 'mock',
      expiresAt: DateTime.now().add(expiresIn),
    );

/// Una risoluzione gia' scaduta.
///
/// Serve a coprire il caso in cui il link e' scaduto prima ancora di arrivare
/// al player: il player deve accorgersene e passare alla fonte successiva,
/// invece di provare a riprodurre un indirizzo che il provider non acceta piu'.
ResolvedSource expiredFor(String sourceId) => ResolvedSource(
      sourceId: sourceId,
      resolvedUrl: 'https://cdn.example/ep1.mp4?token=scaduto',
      headers: const {},
      sourceType: EpisodeSourceType.mp4,
      expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
    );