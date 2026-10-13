import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/watch_history.dart';

/// Letture sullo storico di visione.
///
/// Due operazioni sole, entrambe di sola lettura: la scrittura del progresso
/// resta dove e' sempre stata, in `watch_progress` dal repository degli
/// episodi. Qui si legge quello che quel repository scrive, con l'ordinamento e
/// il "un episodio per anime" lasciati alle funzioni del database.
abstract interface class HistoryRepository {
  /// Anime lasciati a meta', dal piu' recente.
  Future<List<ContinueWatchingItem>> continueWatching({int limit = 12});

  /// Cronologia completa, dal piu' recente, a pagine.
  Future<List<WatchHistoryItem>> history({int limit = 60, int offset = 0});
}

class SupabaseHistoryRepository implements HistoryRepository {
  const SupabaseHistoryRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<ContinueWatchingItem>> continueWatching({int limit = 12}) async {
    try {
      final rows = await _client.rpc(
        'continue_watching',
        params: {'_limit': limit},
      );

      return [
        for (final row in _rows(rows)) ContinueWatchingItem.parse(_map(row)),
      ]..sort((a, b) => _byRecency(a.updatedAt, b.updatedAt));
    } on PostgrestException catch (e) {
      throw _translate(e);
    } on HistoryFailure {
      rethrow;
    } catch (_) {
      throw const HistoryFailure(
        'Non si riesce a leggere dove eri rimasto.',
        isRetryable: true,
      );
    }
  }

  @override
  Future<List<WatchHistoryItem>> history({
    int limit = 60,
    int offset = 0,
  }) async {
    try {
      final rows = await _client.rpc(
        'watch_history',
        params: {'_limit': limit, '_offset': offset},
      );

      return [
        for (final row in _rows(rows)) WatchHistoryItem.parse(_map(row)),
      ];
    } on PostgrestException catch (e) {
      throw _translate(e);
    } on HistoryFailure {
      rethrow;
    } catch (_) {
      throw const HistoryFailure(
        'Cronologia non raggiungibile. Riprova.',
        isRetryable: true,
      );
    }
  }

  /// Dal piu' recente. La query del database ordina gia', ma l'ordine non e'
  /// parte del contratto di una funzione SQL: riordinare qui costa nulla e
  /// tiene la riga corretta anche se un giorno la query cambia.
  static int _byRecency(DateTime? a, DateTime? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return b.compareTo(a);
  }

  List<Object?> _rows(Object? raw) => switch (raw) {
        final List<Object?> list => list,
        _ => const [],
      };

  Map<String, dynamic> _map(Object? row) =>
      row is Map ? Map<String, dynamic>.from(row) : const <String, dynamic>{};

  HistoryFailure _translate(PostgrestException e) {
    // La RPC non esiste ancora: la migration dello storico non e' stata
    // applicata. Distinguerlo dal "riprova" evita di ripetere all'infinito un
    // errore che non passa da solo.
    if (e.code == '42883' ||
        e.message.contains('function') && e.message.contains('does not exist')) {
      return const HistoryFailure(
        'Storico non ancora attivo. Applica la migration dello storico.',
      );
    }

    return const HistoryFailure(
      'Operazione non riuscita. Riprova.',
      isRetryable: true,
    );
  }
}
