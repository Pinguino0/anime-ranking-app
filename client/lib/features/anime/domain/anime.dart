/// Modello del catalogo anime.
///
/// Un anime vive in due posti e questo file rappresenta entrambi:
///
///  - il **catalogo locale** (`public.anime`), la cache che la Edge Function
///    riempie. Li' ogni anime ha un `id` interno e la UI puo' usarlo subito
///    per votarlo.
///  - la **risposta del catalogo esterno**, quando la ricerca arriva da fuori e
///    l'opera non e' ancora in catalogo. In quel caso `id` e' `null`: non esiste
///    un id su cui votare.
///
/// Per questo [AnimeEntry.id] e' nullable e [AnimeEntry.inCatalog] dice da
/// dove viene il dato. Non e' una difformita: e' l'informazione che permette
/// alla schermata di dire "non l'hai ancora in catalogo" invece di lasciare
/// l'utente davanti a un pulsante che non funziona.
library;

/// Formato dell'opera.
///
/// I valori corrispondono all'enum `public.anime_type` del database e alle
/// etichette dei cataloghi esterni (AniList, Kitsu): cambiarli da una parte
/// sola romperebbe o i filtri o la lettura.
enum AnimeMediaType {
  tv('TV', 'TV'),
  movie('Movie', 'Film'),
  ova('OVA', 'OVA'),
  ona('ONA', 'ONA'),
  special('Special', 'Special'),
  music('Music', 'Musica');

  const AnimeMediaType(this.wire, this.label);

  /// Valore inviato al backend e letto dal database.
  final String wire;

  /// Etichetta mostrata all'utente, in italiano dove ha senso.
  final String label;

  /// Parsing tollerante: un formato sconosciuto non deve far crashare una
  /// lista. Vale `null`, e chi non ha formato semplicemente non lo mostra.
  static AnimeMediaType? fromWire(String? raw) {
    if (raw == null) return null;
    for (final value in values) {
      if (value.wire.toLowerCase() == raw.toLowerCase()) return value;
    }
    return null;
  }
}

/// Stagione di prima messa in onda.
///
/// Le stagioni sono a cavallo d'anno: `winter` comprende dicembre, gennaio e
/// febbraio. Per questo [AnimeSeason.fromMonth] esiste e non si deve dedurre la
/// stagione da `airedFrom.month` a mano: dicembre e `winter`, non `fall`.
enum AnimeSeason {
  winter('winter', 'Inverno'),
  spring('spring', 'Primavera'),
  summer('summer', 'Estate'),
  fall('fall', 'Autunno');

  const AnimeSeason(this.wire, this.label);

  final String wire;
  final String label;

  static AnimeSeason? fromWire(String? raw) {
    if (raw == null) return null;
    for (final value in values) {
      if (value.wire == raw.toLowerCase()) return value;
    }
    return null;
  }

  /// Stagione di un mese (1-12), con le stagioni a cavallo d'anno.
  ///
  /// Restituisce `null` fuori dall'intervallo 1-12 invece di fare un wrapping
  /// silenzioso: un mese 13 non e' dicembre.
  static AnimeSeason? fromMonth(int month) => switch (month) {
    12 || 1 || 2 => winter,
    3 || 4 || 5 => spring,
    6 || 7 || 8 => summer,
    9 || 10 || 11 => fall,
    _ => null,
  };

  /// true se la stagione e quella corrente, calcolata dal mese indicato.
  bool isCurrentAt(int month) => fromMonth(month) == this;
}

/// Stato di messa in onda.
///
/// I tre valori sono gia' i valori dell'enum `public.anime_status`. Il
/// significato conta per la UI: `notYetAired` e' un anime che non e ancora
/// uscito, e mostrarlo con il contatore episodi vuoto senza spiegare nulla
/// confonderebbe.
enum AnimeAirStatus {
  finished('finished_airing', 'Concluso'),
  airing('currently_airing', 'In corso'),
  upcoming('not_yet_aired', 'Non ancora uscito');

  const AnimeAirStatus(this.wire, this.label);

  final String wire;
  final String label;

  static AnimeAirStatus? fromWire(String? raw) {
    if (raw == null) return null;
    for (final value in values) {
      if (value.wire == raw.toLowerCase()) return value;
    }
    return null;
  }
}

/// Un anime del catalogo, sia che arrivi dalla cache sia dal catalogo esterno.
class AnimeEntry {
  const AnimeEntry({
    required this.externalId,
    required this.title,
    this.id,
    this.italianTitle,
    this.japaneseTitle,
    this.synopsis,
    this.imageUrl,
    this.trailerUrl,
    this.episodes,
    this.status,
    this.year,
    this.genres = const [],
    this.mediaType,
    this.season,
    this.airedFrom,
    this.airedTo,
    this.score,
    this.scoredBy,
    this.popularity,
    this.duration,
    this.studio,
    this.similarity,
    this.inCatalog = true,
  });

  /// Id esterno del provider (AniList o Kitsu), sempre presente.
  ///
  /// Resta disponibile anche per le righe in catalogo, perche' e' la chiave
  /// con cui la Edge Function riconosce un anime gia' visto e non lo scrive
  /// due volte. Usare l'id interno al suo posto romperebbe questo
  /// riconoscimento: la funzione non conosce gli id di `public.anime`.
  final String externalId;

  /// Id interno di `public.anime`. `null` se l'opera arriva dal catalogo
  /// esterno e non e' ancora stata scritta in catalogo.
  final String? id;

  final String title;

  /// Titolo in italiano, se esiste. `null` se il catalogo non lo conosce: la
  /// UI mostra [displayTitle].
  final String? italianTitle;
  final String? japaneseTitle;
  final String? synopsis;
  final String? imageUrl;
  final String? trailerUrl;
  final int? episodes;
  final AnimeAirStatus? status;
  final int? year;
  final List<String> genres;
  final AnimeMediaType? mediaType;
  final AnimeSeason? season;
  final DateTime? airedFrom;
  final DateTime? airedTo;

  /// Voto medio del catalogo esterno, gia' in scala 0-10. Non e' il voto dato
  /// dall'utente in un gruppo: quello vive in `ratings`.
  final double? score;

  /// Quanti utenti hanno votato nel catalogo esterno. Serve per dare il senso
  /// del voto: 8,4 su 40 utenti e 8,4 su 800.000 non sono la stessa cosa.
  final int? scoredBy;

  /// Quante persone hanno l'opera in lista nel catalogo esterno.
  final int? popularity;

  final String? duration;
  final String? studio;

  /// Quanto il titolo somiglia alla ricerca (0-1), quando il risultato viene
  /// da una ricerca testuale. Serve a ordinare i risultati per pertinenza.
  final double? similarity;

  /// true se l'opera e' gia' nel catalogo locale e [id] e' utilizzabile.
  final bool inCatalog;

  /// Tag per la transizione condivisa fra la card e la scheda.
  ///
  /// Deve essere unico per opera e non per posizione: nella stessa schermata due
  /// card con lo stesso titolo mostrerebbero la stessa immagine che vola verso
  /// la scheda, e a meta' del volo si vedrebbe un poster saltare dal posto
  /// sbagliato. L'id esterno e' la chiave giusta perche' identifica l'opera e
  /// non la sua posizione nella lista, quindi resta valido anche se la lista
  /// viene ricaricata mentre la scheda e' aperta.
  Object get heroTag => 'anime-${externalId.isEmpty ? title : externalId}';

  /// true se si puo' votare questo anime in un gruppo.
  ///
  /// E' [inCatalog] e non basta: senza `id` non c'e' la riga da votare. Il
  /// backend rifiuterebbe il voto e l'utente vedrebbe un errore senza
  /// spiegazione.
  bool get canRate => id != null && inCatalog;

  /// Anno di uscita come testo, per la riga di dettaglio.
  String? get yearLabel => year?.toString();

  /// "TV · 89 episodi · 2013", con le parti che mancano omesse.
  ///
  /// Unire i pezzi solo se ci sono evita le virgole vuote e i doppi spazi che
  /// si vedono quando un dato non e' noto.
  String get factsLabel {
    final parts = <String>[
      if (mediaType != null) mediaType!.label,
      if (episodes != null) '$episodes episodi',
      if (year != null) '$year',
    ];
    return parts.join(' · ');
  }

  /// true se l'opera e uscita abbastanza di recente da interessare la home.
  ///
  /// Non usa `now()` direttamente perche' un modello con date in scadenza deve
  /// poter essere costruito in un test con un riferimento esplicito.
  bool isRecentAt(DateTime now) {
    final from = airedFrom;
    if (from == null) return false;
    return from.isAfter(now.subtract(const Duration(days: 90)));
  }

  /// true se l'opera risulta ancora in corso a [now].
  bool isAiringAt(DateTime now) {
    if (status == AnimeAirStatus.airing) return true;
    final to = airedTo;
    // Senza data di fine non si puo' concludere che sia finito: e' in corso.
    if (to == null) return false;
    return to.isAfter(now);
  }

  /// Crea un'entry da una riga delle RPC (`anime_search`,
  /// `anime_current_season`) o dalla risposta della Edge Function.
  ///
  /// I due formati hanno le stesse chiavi, quindi un solo parser: se i due
  /// divergessero, la UI mostrerebbe gli stessi campi vuoti a seconda della
  /// provenienza.
  factory AnimeEntry.parse(Map<String, dynamic> row) {
    // `id` e' assente nella risposta del catalogo esterno e valore esplicito
    // `null` in quella della cache: i due casi si distinguono perche' in
    // entrambi il risultato e' "non votabile", ma `inCatalog` dice il perche'.
    final rawId = row['id'];
    final id = rawId is String && rawId.isNotEmpty ? rawId : null;

    return AnimeEntry(
      externalId: _string(row['external_id']) ?? '',
      id: id,
      title: _string(row['title']) ?? 'Senza titolo',
      italianTitle: _string(row['title_it']),
      japaneseTitle: _string(row['japanese_title']),
      synopsis: _string(row['synopsis']),
      imageUrl: _string(row['image_url']),
      trailerUrl: _string(row['trailer_url']),
      episodes: _int(row['episodes']),
      status: AnimeAirStatus.fromWire(_string(row['status'])),
      year: _int(row['year']),
      genres: _stringList(row['genres']),
      mediaType: AnimeMediaType.fromWire(_string(row['media_type'])),
      season: AnimeSeason.fromWire(_string(row['season'])),
      airedFrom: _date(row['aired_from']),
      airedTo: _date(row['aired_to']),
      score: _double(row['score']),
      scoredBy: _int(row['scored_by']),
      popularity: _int(row['popularity']),
      duration: _string(row['duration']),
      studio: _string(row['studio']),
      similarity: _double(row['similarity']),
      inCatalog: row['in_catalog'] == true,
    );
  }

  /// true se questa e' la stessa opera, per evitare duplicati quando una ricerca
  /// incontra la stessa anime in due pagine.
  bool sameAs(AnimeEntry other) =>
      other.externalId.isNotEmpty && other.externalId == externalId;

  /// Titolo mostrato all'utente: quello italiano quando c'e', altrimenti il
  /// titolo del catalogo (romaji o inglese a seconda della riga).
  ///
  /// Un solo posto che decide come intitolare l'opera, perche' la UI deve
  /// mostrare lo stesso nome ovunque (home, ricerca, scheda): se ognuno
  /// scegliesse per conto proprio, l'utente vedrebbe l'anime chiamato in due
  /// modi nella stessa schermata.
  String get displayTitle => italianTitle ?? title;

  static String? _string(Object? value) {
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    return null;
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    // Postgres restituisce i bigint come stringa per non perdere precisione
    // nel JSON: `scored_by` e `popularity` arrivano come testo.
    if (value is String) return int.tryParse(value);
    return null;
  }

  static double? _double(Object? value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    // Anche numeric arriva come stringa.
    if (value is String) return double.tryParse(value);
    return null;
  }

  static DateTime? _date(Object? value) {
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  static List<String> _stringList(Object? value) {
    if (value is List) {
      return value
          .whereType<String>()
          .where((item) => item.trim().isNotEmpty)
          .toList();
    }
    return const [];
  }
}

/// Un'opera correlata a un anime (sequel, prequel, ...).
///
/// La relazione arriva dalla RPC `anime_related`, che restituisce la stessa
/// forma di una ricerca piu' il campo `relation_type`, quindi l'[entry] si
/// costruisce con lo stesso parser del catalogo. Quando l'opera correlata non
/// e' ancora in catalogo, `entry.inCatalog` e' false: la scheda si apre
/// comunque, con il suo avviso.
class RelatedAnime {
  const RelatedAnime({required this.relationType, required this.entry});

  /// Tipo di relazione AniList: `SEQUEL`, `PREQUEL`, `SIDE_STORY`, ...
  final String relationType;

  final AnimeEntry entry;

  factory RelatedAnime.parse(Map<String, dynamic> row) => RelatedAnime(
    relationType: _string(row['relation_type']) ?? 'OTHER',
    entry: AnimeEntry.parse(row),
  );

  /// Etichetta italiana del tipo di relazione.
  String get relationLabel => switch (relationType) {
    'PREQUEL' => 'Prequel',
    'SEQUEL' => 'Sequel',
    'SIDE_STORY' => 'Storia collaterale',
    'PARENT' => 'Storia principale',
    'ALTERNATIVE' => 'Alternativa',
    'SPIN_OFF' => 'Spin-off',
    'SUMMARY' => 'Riepilogo',
    _ => 'Correlato',
  };

  /// I tipi che vale la pena mostrare in scheda.
  ///
  /// Fuori restano `CHARACTER`, `OTHER`, `ADAPTATION` e i `SUMMARY`: sono
  /// collegamenti poco affidabili (speciali, riassunti, schede di personaggi)
  /// che riempirebbero la sezione senza dire all'utente cosa guardare dopo.
  static const Set<String> meaningfulTypes = {
    'PREQUEL',
    'SEQUEL',
    'SIDE_STORY',
    'PARENT',
    'ALTERNATIVE',
    'SPIN_OFF',
  };

  bool get isMeaningful => meaningfulTypes.contains(relationType);

  static String? _string(Object? value) {
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    return null;
  }
}

/// Una tappa dell'ordine di visione ("da dove iniziare").
///
/// La catena arriva gia' ordinata dalla RPC `anime_watch_order`: [position]
/// parte da 1 e [isStart] marca la prima opera, quella da cui cominciare. La
/// scheda mostra la sezione solo quando la catena ha piu' di un'opera: con una
/// sola voce non c'e' nessun ordine da comunicare.
class WatchOrderItem {
  const WatchOrderItem({
    required this.position,
    required this.isStart,
    required this.entry,
  });

  /// Posizione nella catena, da 1.
  final int position;

  /// true per la prima opera: e' il punto di partenza.
  final bool isStart;

  final AnimeEntry entry;

  factory WatchOrderItem.parse(Map<String, dynamic> row) => WatchOrderItem(
    position: AnimeEntry._int(row['position']) ?? 1,
    isStart: row['is_start'] == true,
    entry: AnimeEntry.parse(row),
  );
}

/// Un genere disponibile con il numero di anime che lo hanno.
class AnimeGenre {
  const AnimeGenre({required this.name, required this.count});

  final String name;
  final int count;

  factory AnimeGenre.parse(Map<String, dynamic> row) => AnimeGenre(
    name: _name(row['genre']),
    count: AnimeEntry._int(row['anime_count']) ?? 0,
  );

  static String _name(Object? value) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return 'Sconosciuto';
  }
}

/// Riepilogo del catalogo, per la testata della ricerca.
///
/// Serve a distinguere tre situazioni che sembrano uguali e non lo sono:
/// catalogo vuoto, filtri troppo restrittivi, ricerca senza risultati. La UI
/// mostra un messaggio diverso per ciascuna.
class AnimeCatalogStats {
  const AnimeCatalogStats({
    this.totalAnime = 0,
    this.lastSyncedAt,
    this.currentSeason,
    this.airingNow = 0,
    this.newestAiredFrom,
  });

  /// Quanti anime ci sono in catalogo.
  final int totalAnime;

  /// Ultimo caricamento riuscito. `null` se il catalogo non e' mai stato
  /// riempito.
  final DateTime? lastSyncedAt;

  final AnimeSeason? currentSeason;

  /// Quanti sono in onda adesso.
  final int airingNow;

  /// Data di uscita del piu' recente.
  final DateTime? newestAiredFrom;

  /// true se il catalogo non contiene ancora nulla.
  ///
  /// E' il caso in cui la ricerca restituira' zero risultati non perche' la
  /// ricerca e' sbagliata, ma perche' nessuno ha ancora cercato niente: il
  /// messaggio e' completamente diverso e deve dirlo.
  bool get isEmpty => totalAnime == 0;

  factory AnimeCatalogStats.parse(Map<String, dynamic> row) =>
      AnimeCatalogStats(
        totalAnime: AnimeEntry._int(row['total_anime']) ?? 0,
        lastSyncedAt: AnimeEntry._date(row['last_synced_at']),
        currentSeason: AnimeSeason.fromWire(AnimeEntry._string(row['season'])),
        airingNow: AnimeEntry._int(row['airing_now']) ?? 0,
        newestAiredFrom: AnimeEntry._date(row['newest_aired']),
      );

  static AnimeCatalogStats get empty => const AnimeCatalogStats();
}

/// Filtri attivi sulla ricerca.
///
/// Tutti opzionali e tutti nullable perche' "nessun filtro" e' il caso piu'
/// comune. Il backend accetta esattamente questi campi e `null` significa "non
/// filtrare": e' la stessa semantica che ha lato SQL, quindi la UI e la RPC
/// non possono divergere.
class AnimeFilters {
  const AnimeFilters({
    this.genres = const [],
    this.mediaType,
    this.season,
    this.status,
    this.yearFrom,
    this.yearTo,
    this.minScore,
    this.minEpisodes,
    this.maxEpisodes,
  });

  /// Generi: tutti devono essere presenti (AND, non OR).
  final List<String> genres;
  final AnimeMediaType? mediaType;
  final AnimeSeason? season;

  /// Stato di trasmissione: "solo gli anime in corso" e' una domanda che
  /// l'utente fa spesso, e senza questo campo non si puo' porla.
  final AnimeAirStatus? status;
  final int? yearFrom;
  final int? yearTo;
  final double? minScore;
  final int? minEpisodes;
  final int? maxEpisodes;

  /// true se nessun filtro e' attivo: serve a mostrare il pulsante "azzera"
  /// e a non aggiungere parametri inutili alla query.
  bool get isEmpty =>
      genres.isEmpty &&
      mediaType == null &&
      season == null &&
      status == null &&
      yearFrom == null &&
      yearTo == null &&
      minScore == null &&
      minEpisodes == null &&
      maxEpisodes == null;

  /// true se c'e' almeno un filtro attivo.
  bool get isActive => !isEmpty;

  /// Quanti filtri sono attivi, per il badge sulla pulsantiera.
  int get activeCount {
    var count = 0;
    // I generi sono un filtro solo: due generi selezionati restano un
    // criterio ("categoria: Action, Fantasy"), non due voci di elenco.
    if (genres.isNotEmpty) count++;
    if (mediaType != null) count++;
    if (season != null) count++;
    if (status != null) count++;
    if (yearFrom != null || yearTo != null) count++;
    if (minScore != null) count++;
    if (minEpisodes != null || maxEpisodes != null) count++;
    return count;
  }

  AnimeFilters copyWith({
    List<String>? genres,
    AnimeMediaType? mediaType,
    AnimeSeason? season,
    AnimeAirStatus? status,
    int? yearFrom,
    int? yearTo,
    double? minScore,
    int? minEpisodes,
    int? maxEpisodes,
    bool clearMediaType = false,
    bool clearSeason = false,
    bool clearStatus = false,
    bool clearYear = false,
    bool clearScore = false,
    bool clearEpisodes = false,
  }) => AnimeFilters(
    genres: genres ?? this.genres,
    mediaType: clearMediaType ? null : (mediaType ?? this.mediaType),
    season: clearSeason ? null : (season ?? this.season),
    status: clearStatus ? null : (status ?? this.status),
    yearFrom: clearYear ? null : (yearFrom ?? this.yearFrom),
    yearTo: clearYear ? null : (yearTo ?? this.yearTo),
    minScore: clearScore ? null : (minScore ?? this.minScore),
    minEpisodes: clearEpisodes ? null : (minEpisodes ?? this.minEpisodes),
    maxEpisodes: clearEpisodes ? null : (maxEpisodes ?? this.maxEpisodes),
  );

  /// Aggiunge o toglie un genere.
  ///
  /// Toglierlo quando e' gia' presente e' il comportamento atteso da una
  /// pastiglia filtrante: toccare due volte la deseleziona.
  AnimeFilters toggleGenre(String genre) {
    final next = List<String>.from(genres);
    if (next.remove(genre)) {
      return copyWith(genres: next);
    }
    next.add(genre);
    return copyWith(genres: next);
  }

  static const AnimeFilters none = AnimeFilters();
}
