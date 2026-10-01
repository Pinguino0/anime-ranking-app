import 'package:animerank/core/cache/cache_store.dart';

/// Cache in memoria per i test.
///
/// Implementa [CacheStore] come farebbe Hive, cosi' i test del repository con
/// cache esercitano lo stesso codice di produzione invece di una scorciatoia
/// che nasconderebbe i difetti di serializzazione.
class FakeCacheStore implements CacheStore {
  FakeCacheStore([Map<String, String>? initial]) {
    if (initial != null) _values.addAll(initial);
  }

  final Map<String, String> _values = {};

  /// true se una scrittura e' fallita: serve a verificare che un disco che non
  /// collabora non porti a schermate vuote.
  bool failWrites = false;

  /// true se una lettura e' fallita.
  bool failReads = false;

  int writes = 0;
  int deletes = 0;

  /// Chiavi presenti, per controllare cosa e' rimasto.
  Iterable<String> get keys => _values.keys;

  /// Scrive senza passare da [write], per simulare una copia rovinata.
  void writeSync(String key, String value) => _values[key] = value;

  @override
  String? read(String key) {
    if (failReads) return null;
    return _values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) return;
    writes++;
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deletes++;
    _values.remove(key);
  }

  @override
  Iterable<String> keysWithPrefix(String prefix) =>
      _values.keys.where((key) => key.startsWith(prefix)).toList();
}