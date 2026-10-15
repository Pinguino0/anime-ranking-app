import 'dart:convert';

import '../../../core/error/app_failure.dart';
import '../../anime/domain/anime.dart';
import '../../watchlist/domain/watchlist.dart';

/// Errore sulla lettura del feed di attivita' della home.
///
/// Il feed social e' una sezione fra tante: un suo guasto non deve abbattere la
/// home, e per questo ha un errore suo che la sezione sa mostrare da sola.
class HomeFailure extends AppFailure {
  const HomeFailure(super.message, {super.isRetryable});
}

/// Cosa ha fatto un membro di un gruppo.
///
/// I valori di [wire] sono quelli dell'enum `public.activity_type` del
/// database. Sono scritti dai trigger e non dal client: qui si traducono in
/// una frase, e un tipo che non conosciamo viene scartato invece di essere
/// mostrato con un'etichetta inventata.
enum FriendActivityKind {
  rated('rated'),
  ratingChanged('rating_changed'),
  ratingRemoved('rating_removed'),
  watchlistAdded('watchlist_added'),
  watchlistRemoved('watchlist_removed'),
  watchlistStatusChanged('watchlist_status_changed'),
  episodeUpdated('episode_updated'),
  favorited('favorited'),
  unfavorited('unfavorited'),
  commented('commented'),
  achievementUnlocked('achievement_unlocked'),
  tournamentCreated('tournament_created'),
  tournamentStarted('tournament_started'),
  tournamentFinished('tournament_finished'),
  tournamentVote('tournament_vote'),
  duelPlayed('duel_played'),
  joinedGroup('joined_group'),
  leftGroup('left_group');

  const FriendActivityKind(this.wire);

  /// Valore scritto in `activities.type`.
  final String wire;

  /// Parsing tollerante: un tipo sconosciuto vale `null`, e chi legge la riga
  /// la salta. E' meglio una voce in meno che una frase sbagliata.
  static FriendActivityKind? fromWire(String? raw) {
    if (raw == null) return null;
    for (final value in values) {
      if (value.wire == raw) return value;
    }
    return null;
  }

  /// Frase che descrive l'azione, senza soggetto: il nome dell'utente sta
  /// davanti.
  String get actionLabel => switch (this) {
    rated => 'ha votato',
    ratingChanged => 'ha cambiato voto a',
    ratingRemoved => 'ha tolto il voto a',
    watchlistAdded => 'ha messo in lista',
    watchlistRemoved => 'ha tolto dalla lista',
    watchlistStatusChanged => 'ha aggiornato lo stato di',
    episodeUpdated => 'ha aggiornato gli episodi di',
    favorited => 'ha messo tra i preferiti',
    unfavorited => 'ha tolto dai preferiti',
    commented => 'ha commentato',
    achievementUnlocked => 'ha sbloccato un obiettivo',
    tournamentCreated => 'ha creato un torneo',
    tournamentStarted => 'ha avviato un torneo',
    tournamentFinished => 'ha concluso un torneo',
    tournamentVote => 'ha votato in un torneo',
    duelPlayed => 'ha giocato un duello',
    joinedGroup => 'è entrato nel gruppo',
    leftGroup => 'è uscito dal gruppo',
  };
}

/// Una riga del feed "Attivita' degli amici".
///
/// Riguarda sempre un anime: il feed della home racconta cosa i membri dei
/// gruppi hanno fatto con le opere, che e' l'unica cosa che si puo' mostrare
/// con un poster accanto. Le attivita' senza anime (ingressi, obiettivi) non
/// entrano in questa riga.
class FriendActivity {
  const FriendActivity({
    required this.id,
    required this.kind,
    required this.groupId,
    required this.userId,
    required this.userName,
    this.avatarUrl,
    required this.animeId,
    required this.animeTitle,
    this.animeItalianTitle,
    this.imageUrl,
    this.score,
    this.status,
    this.episode,
    required this.createdAt,
  });

  final String id;
  final FriendActivityKind kind;
  final String groupId;

  /// Chi ha compiuto l'azione. Non e' mai l'utente collegato: il feed mostra
  /// gli altri.
  final String userId;
  final String userName;
  final String? avatarUrl;

  /// Id interno dell'anime toccato.
  final String animeId;
  final String animeTitle;
  final String? animeItalianTitle;
  final String? imageUrl;

  /// Voto lasciato, quando l'azione lo porta (`ratings`).
  final double? score;

  /// Stato della watchlist, quando l'azione lo porta.
  final WatchStatus? status;

  /// Numero di episodio, quando l'azione lo porta.
  final int? episode;

  final DateTime createdAt;

  String get animeDisplayTitle => animeItalianTitle ?? animeTitle;

  /// L'anime toccato, ricostruito per aprire la scheda.
  ///
  /// Il feed porta solo id interno, titolo e copertina: la scheda si apre con
  /// quei dati, senza inventare i campi che non abbiamo.
  AnimeEntry get anime => AnimeEntry(
    id: animeId,
    externalId: animeId,
    title: animeTitle,
    italianTitle: animeItalianTitle,
    imageUrl: imageUrl,
  );

  /// Riga di dettaglio sotto l'azione, quando c'e' un dato in piu' da dire.
  String? get detailLabel {
    final rating = score;
    if (rating != null) return 'Voto ${rating.toStringAsFixed(1)}';
    if (status != null) return status!.label;
    if (episode != null) return 'Episodio ${episode!}';
    return null;
  }

  /// Parsing tollerante: `null` quando il tipo non e' riconosciuto o la riga
  /// non ha un anime. Chi legge filtra i `null`.
  static FriendActivity? tryParse(Map<String, dynamic> row) {
    final kind = FriendActivityKind.fromWire(_text(row['type']));
    final animeId = _text(row['anime_id']);
    if (kind == null || animeId == null || animeId.isEmpty) return null;

    final profile = _joined(row['profile']);
    final anime = _joined(row['anime']);
    final meta = _meta(row['metadata']);

    final statusWire = _text(meta['status']);

    return FriendActivity(
      id: _text(row['id']) ?? animeId,
      kind: kind,
      groupId: _text(row['group_id']) ?? '',
      userId: _text(row['user_id']) ?? '',
      userName: _text(profile['username']) ?? 'Membro',
      avatarUrl: _text(profile['avatar_url']),
      animeId: animeId,
      animeTitle: _text(anime['title']) ?? _text(meta['title']) ?? 'Senza titolo',
      animeItalianTitle: _text(anime['title_it']),
      imageUrl: _text(anime['image_url']),
      score: _double(meta['score']),
      status: statusWire == null ? null : WatchStatus.fromWire(statusWire),
      episode:
          _int(meta['episode']) ??
          _int(meta['episode_num']) ??
          _int(meta['current_episode']),
      createdAt: _date(row['created_at']) ?? DateTime.now(),
    );
  }

  /// Le relazioni di PostgREST arrivano come mappa, ma una versione della
  /// libreria puo' consegnarle come lista di un elemento.
  static Map<String, dynamic> _joined(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is List && value.isNotEmpty && value.first is Map) {
      return Map<String, dynamic>.from(value.first as Map);
    }
    return const {};
  }

  /// `metadata` e' `jsonb`: di solito arriva gia' decodificato, ma se il
  /// driver lo consegna come testo va decodificato qui.
  static Map<String, dynamic> _meta(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is String && value.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {
        // Un metadata illeggibile non deve far sparire la riga: la si mostra
        // senza il dettaglio.
      }
    }
    return const {};
  }

  static String? _text(Object? value) {
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    return null;
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static double? _double(Object? value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static DateTime? _date(Object? value) {
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }
}
