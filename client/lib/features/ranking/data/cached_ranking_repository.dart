import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/cache/cache_status.dart';
import '../../../core/cache/cache_store.dart';
import '../domain/ranking.dart';
import 'ranking_repository.dart';

/// [RankingRepository] che ricorda le pagine gia' lette.
///
/// Solo lettura: quando la rete risponde i dati sono sempre quelli del backend e
/// la copia serve alla prossima apertura; quando la rete manca si mostra
/// l'ultima copia segnacolo come tale, e le pagine non piu' disponibili restano
/// un errore normale.
///
/// Le scritture non passano da qui: dopo un voto il controller invalida la
/// cache del gruppo, cosi' la copia non contraddice quello che si vede.
///
/// Ogni chiave e' per utente, non solo per gruppo: le righe portano anche
/// `myScore`, cioe' il voto di chi guarda. Su un dispositivo condiviso, senza
/// questo, il secondo account aprirebbe la classifica del primo e vedrebbe un
/// voto che non ha mai espresso.
class CachedRankingRepository implements RankingRepository, ProvidesCacheStatus {
  CachedRankingRepository(
    this._inner,
    this._cache, {
    String? Function()? userId,
  }) : _userId = userId ?? (() => null);

  final RankingRepository _inner;
  final CacheStore _cache;

  /// Id dell'utente collegato, letto al momento dell'uso.
  ///
  /// Una funzione e non un valore perche' l'utente cambia senza che la cache
  /// venga ricostruita: la stessa istanza del repository serve il primo e il
  /// secondo login, e con l'id catturato alla costruzione continuerebbe a
  /// scrivere sotto le chiavi dell'account precedente.
  final String? Function() _userId;

  CacheStatus _status = const CacheStatus.fresh();

  @override
  CacheStatus get cacheStatus => _status;

  /// Prefisso delle chiavi di un gruppo, per un utente.
  ///
  /// L'utente viene prima del gruppo: e' lui il confine di sicurezza, e
  /// metterlo per primo permette di buttare via tutto quello di un account con
  /// una scansione di chiave. Il nome del gruppo viene comunque per secondo per
  /// l'invalidazione per gruppo, che resta una scansione di chiavi gia'
  /// raggruppate.
  static String prefix(String groupId, String userId) => 'ranking:$userId:$groupId:';

  /// Prefisso di tutto quello che ha salvato un utente.
  static String userPrefix(String userId) => 'ranking:$userId:';

  /// Chiave di una pagina, oppure null se non c'e' un utente collegato.
  ///
  /// Null invece di una chiave "anONIMO": senza sessione non si sa a chi
  /// appartengono le righe, quindi non si scrive e non si legge. Una classifica
  /// anonima non esiste (le RLS chiedono la membership), quindi il caso non si
  /// presenta mai in uso normale, ma senza questo controllo un errore di timing
  /// sui token lascerebbe leggere la copia dell'ultimo account.
  String? _key(String groupId, int limit, int offset) {
    final userId = _userId();
    if (userId == null || userId.isEmpty) return null;
    return '${prefix(groupId, userId)}$limit:$offset';
  }

  @override
  Future<List<RankingEntry>> ranking(
    String groupId, {
    int limit = 50,
    int offset = 0,
  }) async {
    final key = _key(groupId, limit, offset);

    try {
      final rows = await _inner.ranking(groupId, limit: limit, offset: offset);
      _status = const CacheStatus.fresh();

      // La copia si scrive senza aspettarla: la schermata ha gia' quello che le
      // serve, e bloccare il frame su un flush su disco si vedrebbe.
      if (key != null) unawaited(_cache.write(key, _encode(rows)));

      return rows;
    } on RankingFailure catch (failure) {
      // Un errore di permessi o di validazione non migliora mostrando la copia
      // di prima: l'utente deve vedere il messaggio vero, non classifica vecchia.
      if (!failure.isRetryable) {
        _status = const CacheStatus.fresh();
        rethrow;
      }

      final cached = key == null ? null : _cache.read(key);
      if (cached == null) {
        _status = const CacheStatus.fresh();
        rethrow;
      }

      final decoded = _decode(cached);
      if (decoded == null) {
        _status = const CacheStatus.fresh();
        rethrow;
      }

      _status = CacheStatus(fromCache: true, savedAt: decoded.savedAt);
      return decoded.rows;
    }
  }

/// Buttata la copia di un gruppo.
  ///
  /// Chiamata dopo un voto: le posizioni sono cambiate e mostrare la classifica
  /// di prima sarebbe peggio che non mostrarne una. Riguarda solo l'utente
  /// collegato: la copia di un altro account sullo stesso gruppo resta valida
  /// per lui e buttarla sarebbe una perdita di tempo.
  Future<void> invalidateGroup(String groupId) async {
    final userId = _userId();
    if (userId == null || userId.isEmpty) return;

    for (final key in _cache.keysWithPrefix(prefix(groupId, userId)).toList()) {
      await _cache.delete(key);
    }
  }

  /// Buttata tutta la copia di un utente.
  ///
  /// Va chiamata al logout: e' il momento in cui la copia smette di essere
  /// leggibile dal punto di vista di chi sta usando il telefono. Senza questa
  /// pulizia il nome del profilo precedente resterebbe in chiaro su disco
  /// (i titoli e i voti sono dentro le righe, ma anche loro dicono a chi apre
  /// il telefono chi frequentava quell'app).
  Future<void> invalidateUser(String userId) async {
    for (final key in _cache.keysWithPrefix(userPrefix(userId)).toList()) {
      await _cache.delete(key);
    }
  }

  @override
  Future<List<SpecialRankingEntry>> special(
    String groupId,
    SpecialRankingKind kind, {
    int limit = 20,
  }) =>
      // Le classifiche speciali non le metto in cache: sono tre elenchi brevi e
      // derivati, il vantaggio di ricaricarli e' nulla rispetto al rischio di
      // mostrare "piu' amati" di due settimane fa' accanto alla classifica
      // fresca.
      _inner.special(groupId, kind, limit: limit);

  @override
  Future<GroupStats> stats(String groupId) => _inner.stats(groupId);

  @override
  Future<void> rate(String groupId, String animeId, double score) async {
    await _inner.rate(groupId, animeId, score);
    await invalidateGroup(groupId);
  }

  /// Serializza la pagina.
  ///
  /// JSON e non la serializzazione di Hive: il formato leggibile rende la cache
  /// ispezionabile e un formato cambiato fra versioni si riconosce subito
  /// invece di restituire spazzatura tipizzata come se fosse una classifica.
  static String _encode(List<RankingEntry> rows) => jsonEncode({
        'saved_at': DateTime.now().toIso8601String(),
        'rows': [for (final row in rows) _toJson(row)],
      });

  static Map<String, dynamic> _toJson(RankingEntry row) => {
        'rank_position': row.position,
        'anime_id': row.animeId,
        'title': row.title,
        'title_it': row.italianTitle,
        'japanese_title': row.japaneseTitle,
        'image_url': row.imageUrl,
        'episodes': row.episodes,
        'year': row.year,
        'genres': row.genres,
        'mean_score': row.meanScore,
        'vote_count': row.voteCount,
        'ranking_score': row.rankingScore,
        'my_score': row.myScore,
        'position_delta': row.positionDelta,
      };

  static _CachedPage? _decode(String raw) => _CachedPage.tryParse(raw);
}

/// Una pagina salvata con il momento in cui e' stata scritta.
@immutable
class _CachedPage {
  const _CachedPage({required this.rows, required this.savedAt});

  final List<RankingEntry> rows;
  final DateTime savedAt;

  /// Ricostruisce la pagina, oppure null se la copia non e' piu' leggibile.
  ///
  /// Null invece di eccezione: una copia scritta da un'altra versione o
  /// troncata e' rumore, e il backend resta il fonte autorevole.
  static _CachedPage? tryParse(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;

      final savedAt = DateTime.tryParse('${json['saved_at']}');
      if (savedAt == null) return null;

      final rows = json['rows'];
      if (rows is! List) return null;

      return _CachedPage(
        savedAt: savedAt,
        rows: [
          for (final row in rows)
            if (row is Map) RankingEntry.parse(Map<String, dynamic>.from(row)),
        ],
      );
    } catch (_) {
      // Cache scritta da un'altra versione o troncata: si butta via e si legge
      // dalla rete, che e' comunque il fonte autorevole.
      return null;
    }
  }
}