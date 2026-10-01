/// Errore di dominio con messaggio gia' pronto per l'utente.
///
/// I repository non lasciano passare le eccezioni del driver HTTP: arriverebbero
/// alla UI come stringhe tecnicheinglesi. Ogni strato (auth, gruppi, ...)
/// definisce il proprio sottotipo e sa tradurre i propri codici di errore in
/// italiano; la UI conosce solo [AppFailure].
class AppFailure implements Exception {
  const AppFailure(this.message, {this.isRetryable = false});

  final String message;

  /// true se vale la pena riprovare piu' tardi, tipicamente perche' il
  /// problema e' di rete.
///
/// Serve alla UI per decidere se proporre "Riprova" o no: un errore di
  /// permessi non migliora aspettando.
  final bool isRetryable;

  @override
  String toString() => message;
}

/// Errore di autenticazione.
class AuthFailure extends AppFailure {
  const AuthFailure(super.message, {super.isRetryable});
}

/// Errore sulle operazioni di un gruppo.
class GroupsFailure extends AppFailure {
  const GroupsFailure(super.message, {super.isRetryable});
}