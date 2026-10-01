/// Archivio di valori per le schermate che devono aprirsi anche senza rete.
///
/// Solo valori di sola lettura: la cache accelera la lettura, non decide nulla.
/// Ogni scrittura resta a Supabase e ogni cache puo' essere buttata via
/// [delete] senza perdere dati.
///
/// Le chiavi sono stringhe libere con un prefisso per famiglia (`ranking:`,
/// `tournaments:`) cosi' [keysWithPrefix] puo' fare le pulizie per gruppo senza
/// che ogni schermata tenga un indice delle proprie chiavi.
abstract interface class CacheStore {
  /// Il valore salvato, oppure null se non c'e', non e' leggibile o e' scaduto.
  ///
  /// Restituisce null invece di sollevare: una cache illeggibile non e' un
  /// errore dell'app, e' solo una cache che non serve. Chi chiama deve poter
  /// proseguire con i dati di rete senza accorgersi della differenza.
  String? read(String key);

  /// Salva un valore.
  ///
  /// Non solleva: se la scrittura fallisce la schermata mostra comunque i dati
  /// appena scaricati, solo senza cache per la prossima volta.
  Future<void> write(String key, String value);

  Future<void> delete(String key);

  /// Le chiavi che iniziano con [prefix].
  Iterable<String> keysWithPrefix(String prefix);
}

/// Cache che non ricorda niente.
///
/// Serve in due casi: quando [HiveCacheStore.open] fallisce e l'app deve
/// comunque partire, e nei test, dove un disco vero renderebbe i test
/// dipendenti dall'ordine di esecuzione.
class NullCacheStore implements CacheStore {
  const NullCacheStore();

  @override
  String? read(String key) => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}

  @override
  Iterable<String> keysWithPrefix(String prefix) => const [];
}