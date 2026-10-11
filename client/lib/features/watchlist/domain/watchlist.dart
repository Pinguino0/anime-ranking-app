import '../../../core/error/app_failure.dart';

/// Errore sulle operazioni di watchlist.
class WatchlistFailure extends AppFailure {
  const WatchlistFailure(super.message, {super.isRetryable});
}

/// Stato di un anime dentro la watchlist.
///
/// I valori di [wire] sono le etichette dell enum SQL `watchlist_status`: sono
/// scritti direttamente in `watchlists.status`, quindi non si possono rinominare
/// senza una nuova migration.
enum WatchStatus {
  planned('planned', 'Da iniziare', 'Non hai ancora iniziato questo anime.'),
  watching('watching', 'In visione', 'Lo stai guardando adesso.'),
  completed('completed', 'Completato', 'Lo hai finito.'),
  dropped('dropped', 'Droppato', 'Lo hai lasciato indietro.'),
  paused('paused', 'In pausa', 'Riprenderai piu tardi.');

  const WatchStatus(this.wire, this.label, this.hint);

  final String wire;
  final String label;
  final String hint;

  /// Ordine con cui gli stati compaiono nella schermata.
  ///
  /// Non e l ordine dell enum SQL (che mette `planned` per primo e `dropped`
  /// quasi ultimo): quello utile qui e "cosa sto facendo adesso", quindi prima
  /// quello in visione, poi da iniziare, e gli stati conclusi in fondo.
  static const List<WatchStatus> displayOrder = [
    watching,
    planned,
    paused,
    completed,
    dropped,
  ];

  static WatchStatus fromWire(String? raw) => WatchStatus.values.firstWhere(
        (s) => s.wire == raw,
        orElse: () => WatchStatus.planned,
      );
}

/// Una riga di watchlist con i dati dell anime gia' uniti.
///
/// Vale sia per la watchlist personale (`personal_watchlist`, senza gruppo) sia
/// per quella condivisa di un gruppo (`watchlists`). Il join con l anime e'
/// fatto da PostgREST (`anime:anime_id (...)`) perche' l anime non ha una
/// tabella di watchlist dedicata: la lista si legge tutta da una richiesta,
/// senza una seconda chiamata per arricchirla.
class WatchlistEntry {
  const WatchlistEntry({
    required this.id,
    this.groupId,
    required this.animeId,
    required this.status,
    this.currentEpisode = 0,
    this.isFavorite = false,
    this.userId,
    this.userName,
    this.message,
    this.isMine = false,
    this.title = 'Senza titolo',
    this.italianTitle,
    this.imageUrl,
    this.episodes,
    this.year,
    this.genres = const [],
    this.airing = false,
    this.updatedAt,
  });

  final String id;
  /// Gruppo della voce; `null` quando la voce e' nella watchlist personale.
  final String? groupId;

  final String animeId;

  /// Chi ha messo l'anime nella lista. Nella watchlist di un gruppo serve a
  /// mostrare "consigliato da" seguito dal nome; nella lista personale e' l'utente stesso.
  final String? userId;
  final String? userName;

  /// Messaggio lasciato con il consiglio (lista di gruppo), `null` se assente.
  final String? message;

  /// true se la voce e' dell'utente collegato.
  ///
  /// Lo decide il repository confrontando `user_id` con la sessione: cosi' la
  /// schermata di gruppo sa quali voci puo' modificare senza interrogare
  /// l'autenticazione per ogni riga. Vale sempre `true` per la lista personale.
  final bool isMine;
  final WatchStatus status;
  final int currentEpisode;
  final bool isFavorite;
  final String title;

  /// Titolo italiano, se il catalogo lo conosce. La UI usa [displayTitle].
  final String? italianTitle;
  final String? imageUrl;

  /// Titolo mostrato all'utente: italiano se disponibile, altrimenti il titolo
  /// del catalogo.
  String get displayTitle => italianTitle ?? title;

  /// Episodi totali, quando il catalogo li conosce.
  ///
  /// null per gli anime ancora in corso o non censiti: e il caso normale, non un
  /// dato mancante da recuperare.
  final int? episodes;
  final int? year;
  final List<String> genres;

  /// true se il catalogo dice che l anime e ancora in trasmissione.
  final bool airing;
  final DateTime? updatedAt;

  /// true se l utente ha segnato almeno un episodio.
  bool get hasStarted => currentEpisode > 0;

  /// Avanzamento da 0 a 1, null se il totale non e noto.
  ///
  /// Diviso per zero quando `episodes` e 0 o null: un progresso inventato
  /// mostrerebbe una barra vuota piena, o un NaN a schermo.
  double? get progress {
    final total = episodes;
    if (total == null || total <= 0) return null;
    return (currentEpisode / total).clamp(0, 1);
  }

  /// "5 / 12", oppure solo "5" quando il totale non e noto.
  String get episodeLabel =>
      episodes == null ? '$currentEpisode' : '$currentEpisode / $episodes';

  /// Dettagli secondari: stato in corso, anno, episodi.
  ///
  /// Uno solo per riga: in watchlist le righe sono gia lunghe (copertina,
  /// stato, episodi, preferito) e aggiungere i generi le farebbe andare a capo
  /// su due righe diverse.
  String get meta {
    final parts = <String>[
      if (airing) 'in corso',
      if (year != null) '$year',
      if (episodes != null) '$episodes episodi',
    ];

    return parts.join(' · ');
  }

  factory WatchlistEntry.parse(Map<String, dynamic> json, {String? mineId}) {
    // Il join su una chiave esterna arriva come oggetto, ma una versione
    // della libreria puo' consegnarlo come lista di un elemento: senza questa
    // difesa l anime mostrerebbe "Senza titolo" e nessun avviso.
    final anime = _joinedMap(json['anime']);
    // `profile:user_id (username)` per sapere chi ha messo l'anime in lista.
    final profile = _joinedMap(json['profile']);

    final animeId = _text(json['anime_id']) ?? '';
    final userId = _text(json['user_id']);

    return WatchlistEntry(
      id: _text(json['id']) ?? animeId,
      // `null` nella watchlist personale, dove `group_id` non esiste proprio.
      groupId: _text(json['group_id']),
      animeId: animeId,
      status: WatchStatus.fromWire(_text(json['status'])),
      currentEpisode: _toInt(json['current_episode']) ?? 0,
      isFavorite: json['is_favorite'] == true,
      userId: userId,
      userName: _text(profile['username']),
      message: _text(json['message']),
      isMine: userId != null && userId == mineId,
      title: anime['title'] as String? ?? 'Senza titolo',
      italianTitle: anime['title_it'] as String?,
      imageUrl: anime['image_url'] as String?,
      episodes: _toInt(anime['episodes']),
      year: _toInt(anime['year']),
      genres: _strings(anime['genres']),
      airing: anime['status'] == 'currently_airing',
      updatedAt: DateTime.tryParse('${json['updated_at']}'),
    );
  }

  WatchlistEntry copyWith({
    WatchStatus? status,
    int? currentEpisode,
    bool? isFavorite,
  }) =>
      WatchlistEntry(
        id: id,
        groupId: groupId,
        animeId: animeId,
        status: status ?? this.status,
        currentEpisode: currentEpisode ?? this.currentEpisode,
        isFavorite: isFavorite ?? this.isFavorite,
        userId: userId,
        userName: userName,
        message: message,
        isMine: isMine,
        title: title,
        italianTitle: italianTitle,
        imageUrl: imageUrl,
        episodes: episodes,
        year: year,
        genres: genres,
        airing: airing,
        updatedAt: updatedAt,
      );

  @override
  bool operator ==(Object other) => other is WatchlistEntry && other.animeId == animeId;

  @override
  int get hashCode => animeId.hashCode;
}

/// Un consiglio di visione registrato in `anime_recommendations`.
///
/// `toUserId`/`toUserName` sono `null` quando il consiglio era "a tutti i
/// membri del gruppo".
class AnimeRecommendation {
  const AnimeRecommendation({
    required this.id,
    required this.groupId,
    required this.animeId,
    required this.fromUserId,
    required this.fromUserName,
    this.toUserId,
    this.toUserName,
    this.message,
    this.createdAt,
  });

  final String id;
  final String groupId;
  final String animeId;
  final String fromUserId;
  final String fromUserName;

  /// Destinatario; `null` per un consiglio "a tutti".
  final String? toUserId;
  final String? toUserName;

  final String? message;
  final DateTime? createdAt;

  bool get forEveryone => toUserId == null;

  factory AnimeRecommendation.parse(Map<String, dynamic> json) {
    final from = _joinedMap(json['from_profile']);
    final to = _joinedMap(json['to_profile']);

    return AnimeRecommendation(
      id: _text(json['id']) ?? '',
      groupId: _text(json['group_id']) ?? '',
      animeId: _text(json['anime_id']) ?? '',
      fromUserId: _text(json['from_user_id']) ?? '',
      fromUserName: _text(from['username']) ?? '',
      toUserId: _text(json['to_user_id']),
      toUserName: _text(to['username']),
      message: _text(json['message']),
      createdAt: DateTime.tryParse('${json['created_at']}'),
    );
  }
}

/// Totali della watchlist, da `personal_stats`.
///
/// Non sono la somma delle righe visibili: `watched_count` conta tutto quello
/// che e' in watchlist anche con gli stati conclusi, ed e' quello che serve per
/// le cifre in alto.
class WatchlistTotals {
  const WatchlistTotals({
    this.rated = 0,
    this.entries = 0,
    this.watching = 0,
    this.completed = 0,
    this.dropped = 0,
    this.favorites = 0,
    this.episodes = 0,
    this.hours = 0,
  });

  /// Anime votati nel gruppo: voti e watchlist sono due elenchi diversi, e
  /// senza questo numero non si capisce quale dei due e pieno.
  final int rated;

  /// Anime in watchlist, qualsiasi stato.
  final int entries;
  final int watching;
  final int completed;
  final int dropped;
  final int favorites;

  /// Episodi segnati, solo per quello che e' in visione o completato.
  final int episodes;

  /// Stima delle ore, calcolata dal backend con 0.75 minuti per episodio.
  final double hours;

  factory WatchlistTotals.parse(Map<String, dynamic> json) => WatchlistTotals(
        rated: _toInt(json['rated_count']) ?? 0,
        entries: _toInt(json['watched_count']) ?? 0,
        watching: _toInt(json['watching']) ?? 0,
        completed: _toInt(json['completed']) ?? 0,
        dropped: _toInt(json['dropped']) ?? 0,
        favorites: _toInt(json['favorites']) ?? 0,
        episodes: _toInt(json['episodes_watched']) ?? 0,
        hours: _toDouble(json['estimated_hours']) ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is WatchlistTotals &&
      other.rated == rated &&
      other.entries == entries &&
      other.watching == watching &&
      other.completed == completed &&
      other.dropped == dropped &&
      other.favorites == favorites &&
      other.episodes == episodes &&
      other.hours == hours;

  @override
  int get hashCode => Object.hash(
        rated,
        entries,
        watching,
        completed,
        dropped,
        favorites,
        episodes,
        hours,
      );
}

/// Controlli sugli episodi.
///
/// Replica il trigger `check_watchlist_episode` di `007_watchlists.sql`: il
/// backend rifiuta comunque, ma far fallire qui evita una richiesta e lascia
/// l errore accanto al contatore invece che in un banner lontano.
class WatchlistValidators {
  const WatchlistValidators._();

  /// Messaggio d errore per un numero di episodi non valido, null se va bene.
  ///
  /// Il testo del caso "troppo avanti" e' identico a quello del trigger, cosi'
  /// che la stessa cosa venga detta nello stesso modo sia lato client che lato
  /// server.
  static String? episodeError({required int episode, int? total}) {
    if (episode < 0) {
      return 'Gli episodi non possono essere negativi.';
    }

    if (total != null && total > 0 && episode > total) {
      return 'Episodio $episode superiore ai $total episodi disponibili';
    }

    return null;
  }
}

/// Quante righe si caricano per volta.
///
/// Una watchlist per utente sta in poche decine di righe: il limite serve a non
/// far scaricare un elenco enorme senza mostrarlo, non a paginare sul serio.
class WatchlistPage {
  const WatchlistPage._();

  static const int size = 200;

  static bool hasMore(List<WatchlistEntry> rows) => rows.length == size;
}

/// Conversione da numeric/bigint di Postgres.
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

String? _text(Object? raw) => switch (raw) {
      final String s when s.isNotEmpty => s,
      final num n => '$n',
      _ => null,
    };

List<String> _strings(Object? raw) => switch (raw) {
      final List<Object?> list => [for (final e in list) if (e is String) e],
      _ => const [],
    };

/// Normalizza un join PostgREST in una mappa.
///
/// Una chiave esterna arriva come oggetto, ma alcune versioni della libreria
/// la consegnano come lista di un elemento.
Map<String, dynamic> _joinedMap(Object? raw) => switch (raw) {
      final Map<Object?, Object?> map => Map<String, dynamic>.from(map),
      final List<Object?> list when list.isNotEmpty && list.first is Map =>
        Map<String, dynamic>.from(list.first as Map),
      _ => const <String, dynamic>{},
    };
