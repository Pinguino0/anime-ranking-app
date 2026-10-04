/// Modello degli episodi e della visione.
///
/// Le tre cose descritte qui sono legate ma non confuse: un episodio e' un
/// pezzo dell'opera, una sorgente e' un modo di guardarlo, il progresso e'
/// dove l'utente si e' fermato. Stanno in un solo file perche' sono sempre
/// usate insieme, ma i tipi restano separati perche' hanno cyclei di vita
/// diversi: la sorgente cambia quando il backend cambia i file, il progresso
/// cambia ogni dieci secondi, l'episodio non cambia mai.
library;

import '../../../core/error/app_failure.dart';

/// Come si apre una sorgente.
///
/// I tre valori corrispondono all'enum `public.episode_source_type` del
/// database. L'ordine conta perche' decide il fallback: meglio provare `mp4` o
/// `hls`, che l'app sa riprodurre da sola, e usare `iframe` solo come ultima
/// risorsa.
enum EpisodeSourceType {
  mp4('mp4', 'MP4'),
  hls('hls', 'HLS'),
  iframe('iframe', 'Player esterno');

  const EpisodeSourceType(this.wire, this.label);

  /// Valore letto e scritto sul database.
  final String wire;

  /// Come viene chiamata la sorgente all'utente.
  final String label;

  /// Parsing tollerante: un formato nuovo sul backend non deve far crashare
  /// una lista di episodi. Vale `null` e chi non ha formato non la mostra.
  static EpisodeSourceType? fromWire(String? raw) {
    if (raw == null) return null;
    for (final value in values) {
      if (value.wire.toLowerCase() == raw.toLowerCase()) return value;
    }
    return null;
  }
}

/// Un modo di guardare un episodio.
///
/// Una fonte non e' "il video": e' un indirizzo, con una qualita' e una lingua.
/// Lo stesso episodio puo' averne tre, e il player le prova in ordine.
class EpisodeSource {
  const EpisodeSource({
    required this.id,
    required this.url,
    required this.type,
    this.quality,
    this.language,
  });

  final String id;
  final String url;
  final EpisodeSourceType type;
  final String? quality;
  final String? language;

  /// true se l'app puo' riprodurre questa sorgente da sola.
  ///
  /// `iframe` e' falso perche' non si puo' incorporare una pagina web in un
  /// player video senza caricare una WebView dentro l'app, il che significa
  /// eseguire codice di terze parti nel processo dell'app. Il player tratta
  /// quindi questa fonte come "apri il provider", ed e' anche la scelta
  /// onesta: se l'episodio non e' in catalogo con licenza, l'app non finge di
  /// averlo.
  bool get isPlayable => type != EpisodeSourceType.iframe;

  /// Etichetta della pastiglia: "1080p SUB", "720p DUB" e cosi' via.
  ///
  /// Il formato e' quello che l'utente cerca davvero, non "Sorgente 1".
  /// Qualita' e lingua si mettono una dopo l'altra, e quando manca una resta
  /// solo l'altra invece di un separatore appeso a niente.
  String get label {
    final qualityLabel = _asString(quality);
    final languageLabel = switch (_asString(language)?.toLowerCase()) {
      'it' || 'ita' || 'italian' || 'sub' || 'subit' => 'SUB',
      'dub' || 'dubbed' => 'DUB',
      'en' || 'eng' || 'english' => 'ENG',
      'ja' || 'jpn' || 'japanese' => 'JPN',
      final other => other?.toUpperCase(),
    };

    if (qualityLabel == null) return languageLabel ?? type.label;
    if (languageLabel == null) return qualityLabel;
    return '$qualityLabel $languageLabel';
  }

  factory EpisodeSource.parse(Map<String, dynamic> row) => EpisodeSource(
        id: _asString(row['id']) ?? '',
        url: _asString(row['source_url']) ?? '',
        type: EpisodeSourceType.fromWire(_asString(row['source_type'])) ??
            EpisodeSourceType.mp4,
        quality: _asString(row['quality']),
        language: _asString(row['language']),
      );
}

/// Un episodio con tutto quello che la lista sa dire di lui.
///
/// I campi di progresso e voto arrivano gia' uniti dal database
/// (`episodes_for_anime`): se il client li prendesse con query separate
/// dovrebbe riaccostarli a mano, e un id sbagliato mostrerebbe "vista al 42%"
/// sull'episodio sbagliato senza che nessuno se ne accorga.
class Episode {
  const Episode({
    required this.id,
    required this.number,
    this.title,
    this.airedAt,
    this.filler = false,
    this.recap = false,
    this.thumbnail,
    this.sourceCount = 0,
    this.progressTime = 0,
    this.completed = false,
    this.myScore,
    this.communityAverage,
    this.communityCount = 0,
  });

  final String id;

  /// Numero dell'episodio come lo chiama l'utente: 1, 2, 3.
  ///
  /// Non comincia sempre da 1: le stagioni successive e gli episodi speciali
  /// proseguono il conteggio, ed e' quel numero che l'utente cerca quando dice
  /// "l'episodio 14".
  final int number;

  final String? title;
  final DateTime? airedAt;

  /// Episodi di riempimento.
  ///
  /// Non sono inutili, ma sono diversi dal racconto principale: il badge serve
  /// perche' un utente che segue la trama deve poterli saltare senza chiedere.
  final bool filler;

  /// Riepilogo di episodi precedenti.
  final bool recap;
  final String? thumbnail;

  /// Quante fonti attive ha. Zero vuol dire che non c'e' niente da aprire, e
  /// la UI lo dice invece di mostrare un player vuoto.
  final int sourceCount;

  /// Secondi gia' guardati.
  final int progressTime;

  final bool completed;

  /// Voto personale su questo episodio, distinto dal voto dell'opera.
  final double? myScore;

  /// Media dei voti di tutti sulla community.
  final double? communityAverage;
  final int communityCount;

  /// true se l'utente ha gia' iniziato ma non finito.
  bool get started => progressTime > 0 && !completed;

  /// true se l'episodio si puo' aprire.
  bool get isPlayable => sourceCount > 0;

  /// "Episodio 7" quando il numero basta, "Episodio 7 · Ricordi" quando c'e'
  /// anche un titolo.
  String get titleLabel {
    final name = _asString(title);
    return name == null ? 'Episodio $number' : 'Episodio $number · $name';
  }

  /// Quota di visione come valore fra 0 e 1.
  ///
  /// `null` quando non si sa la durata totale: il database conosce il tempo
  /// guardato ma non la durata dell'episodio, e senza la durata una barra
  /// sarebbe un'invenzione. Con il valore c'e' pero' un accorgimento utile: un
  /// episodio finito si marca a 1 anche senza conoscere la durata, altrimenti
  /// l'ultima riga resterebbe piu' corta delle altre per sempre.
  double? progressFraction(Duration? total) {
    if (completed) return 1;
    if (total == null || total.inSeconds <= 0) return null;

    final fraction = progressTime / total.inSeconds;
    if (fraction < 0) return 0;
    return fraction > 1 ? 1 : fraction;
  }

  factory Episode.parse(Map<String, dynamic> row) => Episode(
        id: _asString(row['id']) ?? '',
        number: _asInt(row['episode_num']) ?? 0,
        title: _asString(row['title']),
        airedAt: _asDate(row['aired_at']),
        filler: row['filler'] == true,
        recap: row['recap'] == true,
        thumbnail: _asString(row['thumbnail']),
        sourceCount: _asInt(row['source_count']) ?? 0,
        progressTime: _asInt(row['progress_time']) ?? 0,
        completed: row['completed'] == true,
        myScore: _asDouble(row['my_score']),
        communityAverage: _asDouble(row['community_avg']),
        communityCount: _asInt(row['community_count']) ?? 0,
      );

  /// Copia dell'episodio con il solo voto personale cambiato.
  ///
  /// Serve dopo un voto: rileggere tutta la lista dal backend mostrerebbe il
  /// nuovo numero solo dopo una richiesta di rete, e intanto il cursore
  /// riporterebbe indietro quello vecchio, che e' gia' stato scritto.
  Episode withMyScore(double? score) => Episode(
        id: id,
        number: number,
        title: title,
        airedAt: airedAt,
        filler: filler,
        recap: recap,
        thumbnail: thumbnail,
        sourceCount: sourceCount,
        progressTime: progressTime,
        completed: completed,
        myScore: score,
        communityAverage: communityAverage,
        communityCount: communityCount,
      );
}

/// Errore sulle operazioni sugli episodi.
///
/// Estende [AppFailure] come le altre failure del progetto, cosi' la schermata
/// puo' tradurre l'errore una volta sola invece che per ogni modulo.
class EpisodesFailure extends AppFailure {
  const EpisodesFailure(super.message, {super.isRetryable});
}

/// Tag dell'Hero di un episodio.
///
/// Va costruito da una funzione e non inline: le due schermate che mostrano lo
/// stesso episodio — la lista e il player — devono produrre lo stesso tag, o il
/// volo dell'immagine non troverebbe la sua destinazione.
String episodeHeroTag(String episodeId) => 'episode-$episodeId';

/// Letture difensive sui valori che arrivano da PostgREST.
///
/// Sono funzioni di file e non metodi di una classe perche' servono sia a
/// [EpisodeSource] sia a [Episode], che sono due classi diverse.
///
/// Il caso che le rende necessarie e' Postgres che restituisce `bigint` e
/// `numeric` come stringhe per non perdere precisione nel JSON: senza la
/// conversione esplicita un conteggio arriverebbe a schermo con un punto
/// decimale.
///
/// Ritornano `null` su un tipo sconosciuto invece di tirare un'eccezione: una
/// colonna inesistente non deve far crashare una lista di episodi, deve
/// mostrare un campo vuoto che l'utente puo' ignorare.
String? _asString(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return null;
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

double? _asDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

DateTime? _asDate(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}