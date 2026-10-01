/// Provenienza dell'ultima lettura di una schermata.
class CacheStatus {
  const CacheStatus({this.fromCache = false, this.savedAt});

  /// Costruito da [CacheStatus.fresh].
  const CacheStatus.fresh() : fromCache = false, savedAt = null;

  /// true se i dati sono arrivati dalla cache invece che dalla rete.
  final bool fromCache;

  /// Quando i dati in cache sono stati scritti, se arrivano dalla cache.
  final DateTime? savedAt;
}

/// Repository che sa dire da dove arriva l'ultima lettura.
///
/// Un'interfaccia a parte invece di un metodo su [Object]: i repository senza
/// cache semplicemente non la implementano, e il controller verifica con un
/// `is` invece di dover conoscere ogni implementazione concreta.
abstract interface class ProvidesCacheStatus {
  /// Provenienza dell'ultima lettura completata.
  ///
  /// Vale per l'ultima chiamata finita, non per una in volo: mentre si aspetta
  /// la rete non si sa ancora cosa rispondera'.
  CacheStatus get cacheStatus;
}