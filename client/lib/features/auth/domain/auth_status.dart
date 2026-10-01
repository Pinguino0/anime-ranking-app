import 'package:supabase_flutter/supabase_flutter.dart';

/// Stato di autenticazione, in forma chiusa.
///
/// E' una `sealed class` perche' i due casi siano esaustivi: in [AuthStatus]
/// non esiste una terza variabile "caricamento". Supabase ripristina la
/// sessione da disco in modo sincrono prima di far partire l'app, quindi al
/// primo frame la risposta e' gia definitiva.
///
/// Il nome e' [AuthStatus] e non `AuthState` per non collidere con
/// `AuthState` di supabase_flutter, che descrive un evento del canale auth e
/// non lo stato dell'app.
sealed class AuthStatus {
  const AuthStatus();

  /// L'utente e collegato.
  const factory AuthStatus.signedIn(User user) = AuthSignedIn;

  /// Nessuna sessione attiva: l'app mostra il login.
  const factory AuthStatus.signedOut() = AuthSignedOut;

  /// Traduce una sessione Supabase nello stato dell'app.
  factory AuthStatus.fromSession(Session? session) {
    final user = session?.user;
    return user == null ? const AuthStatus.signedOut() : AuthStatus.signedIn(user);
  }

  /// true quando c'e' un utente collegato.
  bool get isSignedIn => this is AuthSignedIn;

  /// L'utente collegato, o null se non c'e'.
  User? get user => switch (this) {
        final AuthSignedIn s => s.user,
        AuthSignedOut() => null,
      };
}

/// Utente collegato.
final class AuthSignedIn extends AuthStatus {
  const AuthSignedIn(this.user);

  @override
  final User user;

  @override
  bool operator ==(Object other) => other is AuthSignedIn && other.user.id == user.id;

  @override
  int get hashCode => user.id.hashCode;
}

/// Nessuna sessione.
final class AuthSignedOut extends AuthStatus {
  const AuthSignedOut();

  @override
  bool operator ==(Object other) => other is AuthSignedOut;

  @override
  int get hashCode => (AuthSignedOut).hashCode;
}