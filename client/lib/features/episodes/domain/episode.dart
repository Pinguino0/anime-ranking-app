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
///
/// Due tipi di indirizzo convivono qui e non sono interscambiabili:
///
///  - [url] e' gia' riproducibile. Vale per sempre e si puo' aprire subito.
///  - [canonicalUrl] e' l'indirizzo del catalogo: la pagina, non il video. Non
///    si apre, e vale finche' quel catalogo esiste.
///
/// Il player non prova mai [canonicalUrl]: chiede a `resolve-source` di
/// trasformarlo in qualcosa di riproducibile e usa quello che torna.
class EpisodeSource {
  const EpisodeSource({
    required this.id,
    this.url,
    this.canonicalUrl,
    required this.type,
    this.quality,
    this.language,
    this.providerSlug,
    this.providerLabel,
  });

  final String id;

  /// Indirizzo gia' riproducibile, quando la fonte e' di quelle che si aprono
  /// senza passare dal resolver.
  ///
  /// `null` per una fonte canonica: non e' un errore, e' il caso normale di chi
  /// ha un provider dietro.
  final String? url;

  /// L'indirizzo da risolvere, quando la fonte ha un provider.
  final String? canonicalUrl;

  final EpisodeSourceType type;
  final String? quality;
  final String? language;

  /// Chi sa risolvere [canonicalUrl].
  final String? providerSlug;

  /// Come si chiama [providerSlug] all'utente.
  final String? providerLabel;

  /// true se questa fonte ha bisogno del resolver prima di essere riprodotta.
  bool get needsResolution => canonicalUrl != null;

  /// true se la fonte e' l'audio originale con sottotitoli.
  ///
  /// Diverso da [isPlayable]: dice quale traccia audio porta la fonte, non se
  /// l'app la sa riprodurre. Serve a ordinare le fonti mettendo davanti la
  /// versione sottotitolata, che e' il default di chi non ha ancora scelto.
  bool get isSubtitled {
    final raw = language?.toLowerCase().trim();
    return raw == 'sub' || raw == 'subit' || raw == 'subs' || raw == 'subbed';
  }

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
    final raw = _asString(language)?.toLowerCase();

    // La lingua e la modalita' audio sono due cose diverse, e qui erano state
    // confuse: `ita` e `sub` finivano nella stessa etichetta `SUB`. Ma `ita`
    // vuol dire che l'audio e' gia' italiano, cioe' doppiaggio, mentre `sub`
    // vuol dire che l'audio e' giapponese con sottotitoli. Un utente italiano
    // che leggeva "720p SUB" su una traccia con audio italiano apriva la
    // sorgente aspettandosi i sottotitoli e si trovava la voce italiana: due
    // righe diverse nella stessa lista, con la stessa etichetta, che
    // descrivevano due cose opposte.
    final languageLabel = switch (raw) {
      // Italiano gia' doppiato: la lingua si puo' nominare per esteso perche'
      // e' la lingua dell'utente, non una scelta di audio.
      'it' || 'ita' || 'italian' => 'ITA',
      // Qui invece la lingua resta originale e cambia la modalita': e'
      // sottotitolato, quindi si dice "SUB" perche' e' questo che l'utente
      // sceglie.
      'sub' || 'subit' || 'subs' || 'subbed' => 'SUB',
      'dub' || 'dubbed' => 'DUB',
      'en' || 'eng' || 'english' => 'ENG',
      'ja' || 'jpn' || 'japanese' => 'JPN',
      final other => other?.toUpperCase(),
    };

    if (qualityLabel == null) return languageLabel ?? type.label;
    if (languageLabel == null) return qualityLabel;
    return '$qualityLabel $languageLabel';
  }

  /// Etichetta che distingue due sorgenti altrimenti identiche.
  ///
  /// [label] descrive il formato, e il formato puo' non bastare: due provider
  /// diversi possono offrire lo stesso 1080p sottotitolato. Senza un
  /// discriminante la riga dei codici mostra due pastiglie uguali e l'utente
  /// non ha modo di sap quale provare per primo — deve indovinare, e se la
  /// prima non parte la seconda sembra essere un'altra copia della stessa.
  ///
  /// Il numero e' la posizione nell'elenco, non un numero di versione: quando
  /// due sorgenti hanno lo stesso formato, "1080p SUB" e "1080p SUB (2)" sono
  /// l'unico modo che ha la pastiglia di dire "prova le due, in quest'ordine".
  /// Il formato resta per primo perche' e' quello che si cerca.
  String labelledAt(int position) {
    final base = label;
    return position <= 1 ? base : '$base ($position)';
  }

  factory EpisodeSource.parse(Map<String, dynamic> row) => EpisodeSource(
        id: _asString(row['id']) ?? '',
        url: _asString(row['source_url']),
        canonicalUrl: _asString(row['canonical_url']),
        type: EpisodeSourceType.fromWire(_asString(row['source_type'])) ??
            EpisodeSourceType.mp4,
        quality: _asString(row['quality']),
        language: _asString(row['language']),
        providerSlug: _asString(row['provider_slug']),
        providerLabel: _asString(row['provider_label']),
      );

  /// L'indirizzo da mettere in pasto al player.
  ///
  /// Fallisce se non ce n'e' nessuno dei due, il che in una lista ben costruita
  /// non accade: una fonte ha sempre un indirizzo riproducibile oppure uno da
  /// risolvere. Restituisce `null` invece di scegliere da sola perche' la scelta
  /// fra "provo a riprodurre" e "chiedo il resolver" e' del player, che sa
  /// cosa puo' fare.
  String? get playbackAddress => url ?? canonicalUrl;
}

/// Una fonte dopo che il resolver l'ha resa riproducibile.
///
/// Questo tipo non entra in [EpisodeSource] e non viene salvato: esiste per il
/// tempo di una riproduzione. E' la copia di `source_url` che i provider veri
/// non possono dare, perche' contiene un token con una scadenza e copre una
/// sola richiesta — metterlo in colonna trasformerebbe il catalogo in un magazzino
/// di link morti, che e' il problema da cui siamo partiti.
///
/// Gli header sono parte del risultato e non un dettaglio: senza `Referer` o
/// `Authorization` molti CDN rispondono 403 anche con l'URL giusto, e il
/// sintomo sarebbe "questa fonte non parte" senza che nessuno capisca perche'.
class ResolvedSource {
  const ResolvedSource({
    required this.sourceId,
    required this.resolvedUrl,
    required this.headers,
    required this.sourceType,
    this.canonicalUrl,
    this.providerSlug,
    this.expiresAt,
  });

  final String sourceId;
  final String resolvedUrl;
  final Map<String, String> headers;
  final EpisodeSourceType sourceType;

  /// L'indirizzo di partenza, per i log di debug.
  final String? canonicalUrl;
  final String? providerSlug;

  /// Quando il link smette di valere. `null` se il provider non lo dichiara,
  /// che e' il caso di un link semplice senza scadenza.
  final DateTime? expiresAt;

  /// true se il link e' ancora buono almeno per un minuto.
  ///
  /// Quel minuto e' il margine perche' la richiesta ci mette: aprire un link che
  /// scade tra due secondi fa fallirebbe il player mentre sembrerebbe un
  /// problema di rete.
  bool get isFresh {
    final expiry = expiresAt;
    if (expiry == null) return true;
    return expiry.isAfter(DateTime.now().add(const Duration(minutes: 1)));
  }

  factory ResolvedSource.parse(Map<String, dynamic> row) => ResolvedSource(
        sourceId: _asString(row['source_id']) ?? '',
        resolvedUrl: _asString(row['resolved_url']) ?? '',
        headers: _asHeaders(row['headers']),
        sourceType: EpisodeSourceType.fromWire(_asString(row['source_type'])) ??
            EpisodeSourceType.mp4,
        canonicalUrl: _asString(row['canonical_url']),
        providerSlug: _nested(row['provider'], 'slug'),
        expiresAt: _asDate(row['expires_at']),
      );
}

/// Una parola dentro un oggetto annidato, se l'oggetto c'e'.
///
/// Il resolver manda `provider: { slug, label, adapter }` invece di tre campi
/// piatti: e' un'informazione che viaggia insieme e che ha senso leggere
/// insieme. Qui si restituisce `null` invece di sollevare, perche' la stessa
/// lettura serve anche quando la risposta e' un errore e quel campo non c'e'.
String? _nested(Object? value, String key) {
  if (value is! Map) return null;
  return _asString(value[key]);
}

/// Gli header vengono dal backend come `Map<String, dynamic>`.
///
/// La conversione e' esplicita perche' i valori arrivano come `Object?`: una
/// `cast` lascerebbe dentro i numeri, e un header con un numero dentro viene
/// rifiutato dal client HTTP in un punto in cui il messaggio d'errore parla di
/// rete e non di header.
Map<String, String> _asHeaders(Object? value) {
  if (value is! Map) return const {};

  return {
    for (final entry in value.entries)
      if (_asString(entry.key) != null && _asString(entry.value) != null)
        entry.key as String: entry.value as String,
  };
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