import 'package:hive_ce_flutter/hive_flutter.dart';

import 'cache_store.dart';

/// [CacheStore] su una box Hive.
///
/// Solo stringhe: la cache non ha schemi da migrare e un valore illeggibile
/// (casa cambiata, chiavi cambiate fra versioni) si butta ricominciando
/// invece di far esplodere la lettura di una schermata.
class HiveCacheStore implements CacheStore {
  HiveCacheStore(this._box);

  final Box<String> _box;

  /// Nome della box.
  ///
  /// Il suffisso di versione serve per poter buttare via tutto quello scritto da
  /// versioni precedenti dell'app cambiando una stringa, senza dover migrare
  /// cio' che si leggeva.
  static const boxName = 'anime_rank_cache_v1';

  /// Apre la cache, o restituisce una cache vuota se il disco non collabora.
  ///
  /// Non lascia propagare l'errore: senza cache l'app funziona (fa solo piu'
  /// richieste di rete), mentre un'eccezione qui lascerebbe l'utente con una
  /// schermata bianca e nessun modo di recuperare.
  static Future<CacheStore> open() async {
    try {
      await Hive.initFlutter();
      return HiveCacheStore(await Hive.openBox<String>(boxName));
    } catch (_) {
      return const NullCacheStore();
    }
  }

  @override
  String? read(String key) {
    try {
      return _box.get(key);
    } catch (_) {
      // Una box aperta in sola lettura o corrotta non deve impedire di mostrare
      // quello che si riesce a prendere dal resto.
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _box.put(key, value);
    } catch (_) {
      // La schermata ha gia' i dati freschi: perdere la copia su disco non
      // cambia nulla fino alla prossima apertura.
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _box.delete(key);
    } catch (_) {}
  }

  @override
  Iterable<String> keysWithPrefix(String prefix) => [
        for (final key in _box.keys)
          if ('$key'.startsWith(prefix)) '$key',
      ];
}