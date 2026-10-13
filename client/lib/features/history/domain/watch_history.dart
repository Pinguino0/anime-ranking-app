import '../../../core/error/app_failure.dart';

/// Errore sulle letture dello storico di visione.
class HistoryFailure extends AppFailure {
  const HistoryFailure(super.message, {super.isRetryable});
}

/// Un anime lasciato a meta': alimenta la riga "Continua da guardare".
///
/// E' per ANIME e non per episodio, ed e' una scelta del backend: se ho lasciato
/// a meta' la E3 e poi la E4, la riga e' una sola — la E4, la piu' recente. Due
/// card dello stesso anime affiancate sembrerebbero due titoli diversi.
class ContinueWatchingItem {
  const ContinueWatchingItem({
    required this.animeId,
    required this.animeTitle,
    this.imageUrl,
    required this.episodeId,
    required this.episodeNumber,
    required this.currentSeconds,
    this.updatedAt,
  });

  final String animeId;
  final String animeTitle;
  final String? imageUrl;
  final String episodeId;
  final int episodeNumber;

  /// Secondo a cui riprendere. Il player lo rilegge comunque da solo: qui serve
  /// solo a dirlo sulla card.
  final int currentSeconds;

  final DateTime? updatedAt;

  /// "Riprendi da 12:34", o senza posizione quando e' a zero.
  String get resumeLabel {
    if (currentSeconds <= 0) return 'Riprendi';
    return 'Riprendi da ${formatClock(currentSeconds)}';
  }

  factory ContinueWatchingItem.parse(Map<String, dynamic> row) =>
      ContinueWatchingItem(
        animeId: _asString(row['anime_id']) ?? '',
        animeTitle: _asString(row['anime_title']) ?? 'Senza titolo',
        imageUrl: _asString(row['image_url']),
        episodeId: _asString(row['episode_id']) ?? '',
        episodeNumber: _asInt(row['episode_num']) ?? 0,
        currentSeconds: _asInt(row['current_seconds']) ?? 0,
        updatedAt: _asDate(row['updated_at']),
      );
}

/// Una voce della cronologia: un episodio aperto, col punto in cui si e' fermato.
///
/// A differenza di [ContinueWatchingItem] qui c'e' un episodio per riga e ci
/// stanno anche quelli completati: la cronologia racconta cosa si e' guardato,
/// non cosa resta da guardare.
class WatchHistoryItem {
  const WatchHistoryItem({
    required this.animeId,
    required this.animeTitle,
    this.imageUrl,
    required this.episodeId,
    required this.episodeNumber,
    required this.currentSeconds,
    required this.completed,
    this.updatedAt,
  });

  final String animeId;
  final String animeTitle;
  final String? imageUrl;
  final String episodeId;
  final int episodeNumber;
  final int currentSeconds;
  final bool completed;
  final DateTime? updatedAt;

  /// "Episodio 7", con il titolo dell'anime tenuto a parte.
  String get episodeLabel => 'Episodio $episodeNumber';

  /// Cosa dire al posto della posizione: finito o a che minuto.
  String get progressLabel {
    if (completed) return 'Visto';
    if (currentSeconds <= 0) return 'Aperto';
    return 'Fermato a ${formatClock(currentSeconds)}';
  }

  factory WatchHistoryItem.parse(Map<String, dynamic> row) => WatchHistoryItem(
        animeId: _asString(row['anime_id']) ?? '',
        animeTitle: _asString(row['anime_title']) ?? 'Senza titolo',
        imageUrl: _asString(row['image_url']),
        episodeId: _asString(row['episode_id']) ?? '',
        episodeNumber: _asInt(row['episode_num']) ?? 0,
        currentSeconds: _asInt(row['current_seconds']) ?? 0,
        completed: row['completed'] == true,
        updatedAt: _asDate(row['updated_at']),
      );
}

/// Secondi come `m:ss` o `h:mm:ss`.
///
/// Non `intl`: la durata di un video non e' una data, e `DateFormat` su una
/// durata darebbe un fuso orario che non c'entra nulla. La formattazione a mano
/// e' piu' corta di un import e non sbaglia.
String formatClock(int seconds) {
  final safe = seconds < 0 ? 0 : seconds;
  final h = safe ~/ 3600;
  final m = (safe % 3600) ~/ 60;
  final s = safe % 60;

  final mm = h > 0 ? m.toString().padLeft(2, '0') : m.toString();
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

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

DateTime? _asDate(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}
