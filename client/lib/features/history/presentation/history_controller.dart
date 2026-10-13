import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/presentation/auth_controller.dart';
import '../data/history_repository.dart';
import '../domain/watch_history.dart';

/// Repository dello storico.
///
/// Come gli altri moduli: in produzione non viene inizializzato qui ma
/// sovrascritto in `main`, cosi' un dimenticatoio fallisce subito invece di
/// fingere uno storico vuoto.
final historyRepositoryProvider = Provider<HistoryRepository>((ref) {
  throw StateError('historyRepositoryProvider non e stato inizializzato.');
});

/// Id dell'utente collegato, come dipendenza osservabile.
///
/// Le letture dello storico filtrano per utente dentro le RPC: rigenerarle
/// quando cambia account evita di mostrare, per un istante, la riga di un altro.
/// `null` significa "nessuno collegato", e in quel caso non si chiede nulla.
final _currentUserIdProvider =
    Provider<String?>((ref) => ref.watch(authStatusProvider).user?.id);

/// Anime lasciati a meta', per la riga "Continua da guardare" in home.
///
/// Un [FutureProvider] e non un notifier: non c'e' niente da modificare da qui,
/// si legge e si mostra. Si invalida quando si esce dal player, cosi' la riga
/// riflette subito l'episodio appena lasciato.
final continueWatchingProvider =
    FutureProvider<List<ContinueWatchingItem>>((ref) async {
  final userId = ref.watch(_currentUserIdProvider);
  if (userId == null) return const [];

  final repository = ref.watch(historyRepositoryProvider);
  return repository.continueWatching();
});

/// Cronologia completa, a pagine.
///
/// Il primo caricamento e i successivi stanno nello stesso stato perche' la
/// schermata li mostra come una lista sola: un secondo provider per la seconda
/// pagina obbligherebbe la UI a incollare due liste e a decidere lei quando
/// smettere, che e' esattamente la logica che sta meglio qui.
class WatchHistoryController extends AsyncNotifier<List<WatchHistoryItem>> {
  /// Righe per pagina. Abbastanza da riempire uno schermo, poche da non far
  /// aspettare una richiesta da un secondo quando ce ne sono centinaia.
  static const int pageSize = 40;

  bool _hasMore = true;

  /// Se c'e' ancora qualcosa da chiedere. La schermata lo usa per mostrare o
  /// nascondere "Carica altri": un pulsante che non carica niente e' peggio di
  /// nessun pulsante.
  bool get hasMore => _hasMore;

  @override
  Future<List<WatchHistoryItem>> build() async {
    _hasMore = true;

    // Dipendenza osservata: cambiando account la cronologia si ricostruisce.
    final userId = ref.watch(_currentUserIdProvider);
    if (userId == null) return const [];

    final repository = ref.watch(historyRepositoryProvider);
    final page = await repository.history(limit: pageSize, offset: 0);
    _hasMore = page.length >= pageSize;
    return page;
  }

  /// Aggiunge la pagina successiva in fondo.
  ///
  /// Lascia intatto quello che si sta leggendo se la richiesta fallisce: chi
  /// preme "Carica altri" ha gia' una lista sotto gli occhi, e sostituirla con
  /// una schermata d'errore sarebbe un peggioramento. L'errore risale al
  /// chiamante, che lo mostra come avviso.
  Future<void> loadMore() async {
    final current = state.asData?.value;
    if (current == null || !_hasMore) return;

    final repository = ref.read(historyRepositoryProvider);
    final page =
        await repository.history(limit: pageSize, offset: current.length);

    _hasMore = page.length >= pageSize;
    state = AsyncData([...current, ...page]);
  }

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }
}

final watchHistoryProvider = AsyncNotifierProvider<WatchHistoryController,
    List<WatchHistoryItem>>(WatchHistoryController.new);
