import 'app_failure.dart';

/// Politica di retry per i provider.
///
/// Riverpod 3 ritenta da solo un provider che fallisce, con attese crescenti.
/// Per i provider dell'app questo e' quasi sempre sbagliato: quasi tutti gli
/// errori che arrivano dal backend sono decisioni del server ("permessi
/// insufficienti", "il owner non puo lasciare il gruppo", "codice non
/// valido") e non transienti. Ritentarli significa interrogare il server
/// decine di volte per ottenere sempre la stessa risposta, mentre l'utente
/// vede uno spinner invece del messaggio d'errore.
///
/// La regola e' quindi: si ritenta solo se l'errore e' dichiarato
/// [AppFailure.isRetryable], e con attese crescenti ma limitate a poche
/// tentativi, cosi' un errore di rete non viene abbandonato subito ma non
/// arriva nemmeno a insistere per minuti.
typedef AppRetry = Duration? Function(int retryCount, Object error);

/// Numero massimo di tentativi automatici.
///
/// Tre tentativi coprono la maggior parte dei disturbi reali (connessione che
/// salta e torna) senza trasformare un errore permanente in un silenzio lungo.
const int _maxRetries = 3;

/// Ritenta solo gli errori dichiarati ripetibili.
///
/// Usare [AppFailure.isRetryable] come criterio, e non "tutti gli errori", e'
/// il punto: senza questo controllo un "permessi insufficienti" verrebbe
/// ritentato con lo stesso identico risultato, e l'errore non arriverebbe mai
/// all'utente che potrebbe sistemarlo.
Duration? appRetry(int retryCount, Object error) {
  if (error is! AppFailure || !error.isRetryable) return null;
  if (retryCount >= _maxRetries) return null;

  // Attese di 1s, 2s, 4s: abbastanza da superare un calo di rete, non tanto
  // da far aspettare l'utente con uno spinner che sembra bloccato.
  return Duration(seconds: 1 << retryCount);
}
