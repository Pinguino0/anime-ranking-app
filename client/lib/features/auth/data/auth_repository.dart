import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/error/app_failure.dart';
import '../domain/auth_status.dart';

// Le schermate che mostrano un errore di autenticazione devono poterlo
// nominare senza sapere da quale layer arriva: si riesporta qui, che e' il
// punto in cui l'errore viene sollevato.
export '../../../core/error/app_failure.dart' show AuthFailure;

/// Esito di una registrazione.
///
/// Supabase puo' rispondere in due modi a seconda che la conferma email sia
/// attiva: se e' attiva la risposta contiene solo l'utente senza sessione, se
/// e' disattivata contiene gia' la sessione e l'utente entra subito. La UI
/// deve quindi distinguere i due casi invece di assumere sempre "fatto".
enum SignUpOutcome {
  /// Inviata email di conferma: l'utente deve cliccare il link prima di entrare.
  needsEmailConfirmation,

  /// Sessione gia' attiva: si puo' entrare subito.
  alreadySignedIn,
}

/// Errore di autenticazione con messaggio gia' tradotto in italiano.
///
/// [AuthFailure] arriva da core/error/app_failure.dart: e' l'unico tipo di
/// errore che questo repository lascia sfuggire, cosi' le schermate non
/// devono mai importare le eccezioni di Supabase.
///
/// I messaggi di Supabase sono in inglese e non parlano dell'esigenza
/// dell'utente: ogni errore noto viene mappato su una frase utile, quelli
/// sconosciuti diventano un messaggio generico.

/// Contratto delle operazioni di autenticazione.
///
/// Esiste come interfaccia separata da [SupabaseAuthRepository] perche' i
/// test non possano parlare con Supabase: iniettano un finto e verificano il
/// comportamento dell'app (redirect, errori mostrati, campi invalidati) senza
/// rete e senza dipendere dallo stato del progetto remoto.
abstract interface class AuthRepository {
  /// Sessione attuale, o null se l'utente non e' collegato.
  Session? get currentSession;

  /// Emesso a ogni cambio di sessione, inclusa l'uscita.
  Stream<AuthStatus> watch();

  /// Collega un utente esistente.
  ///
  /// Tappa [AuthFailure] se le credenziali non sono valide.
  Future<void> signIn({required String email, required String password});

  /// Registra un utente nuovo.
  ///
  /// [userName] finisce in `raw_user_meta_data`, dove il trigger
  /// `handle_new_user()` lo legge per creare il profilo. Se il nome scelto e'
  /// gia' preso il backend non fallisce: assegna un nome generato al posto
  /// suo. Tappa [AuthFailure] se l'email e' gia' registrata.
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    String? userName,
  });

  /// Invia l'email di recupero password.
  ///
  /// Non segnala mai se l'indirizzo esiste: rispondere diversamente
  /// consentirebbe di enumerare gli account registrati.
  Future<void> sendPasswordReset(String email);

  /// Scollega l'utente.
  Future<void> signOut();
}

/// Implementazione reale, delegata a Supabase Auth.
class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._client);

  final SupabaseClient _client;

  @override
  Session? get currentSession => _client.auth.currentSession;

  @override
  Stream<AuthStatus> watch() => _client.auth.onAuthStateChange.map(
        (event) => AuthStatus.fromSession(event.session),
      );

  @override
  Future<void> signIn({required String email, required String password}) async {
    try {
      await _client.auth.signInWithPassword(email: email.trim(), password: password);
    } on AuthException catch (e) {
      throw AuthFailure(_messageForSignIn(e.message));
    } catch (_) {
      // Rete assente o timeout: il tipo di errore dipende dal client HTTP
      // sottostante e non vale la pena enumerarlo. All'utente basta sapere
      // che il problema non sono le credenziali.
      throw const AuthFailure('Connessione assente o troppo lenta. Riprova.');
    }
  }

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    String? userName,
  }) async {
    try {
      final response = await _client.auth.signUp(
        email: email.trim(),
        password: password,
        data: (userName == null || userName.isEmpty) ? null : {'username': userName},
      );

      // Con la conferma email attiva Supabase risponde con user e sessione
      // null. Se manca la sessione, l'utente deve prima confermare l'indirizzo.
      return response.session == null
          ? SignUpOutcome.needsEmailConfirmation
          : SignUpOutcome.alreadySignedIn;
    } on AuthException catch (e) {
      throw AuthFailure(_messageForSignUp(e.message));
    } catch (_) {
      throw const AuthFailure('Connessione assente o troppo lenta. Riprova.');
    }
  }

  @override
  Future<void> sendPasswordReset(String email) async {
    try {
      await _client.auth.resetPasswordForEmail(
        email.trim(),
        redirectTo: 'io.animerank.app://reset-password',
      );
    } on AuthException {
      // Il messaggio non distingue "email inesistente" per non rivelare quali
      // account sono registrati: l'utente vede sempre la stessa conferma.
      return;
    } catch (_) {
      throw const AuthFailure('Connessione assente o troppo lenta. Riprova.');
    }
  }

  @override
  Future<void> signOut() async {
    await _client.auth.signOut();
  }

  /// Traduce i messaggi di Supabase in italiano.
  ///
  /// Supabase restituisce testo inglese libero, quindi si cerca per
  /// sotto-stringa invece di fare confronto esatto: una traduzione o un
  /// refactor lato server non deve far comparire un messaggio tecnico.
  String _messageForSignIn(String raw) {
    final m = raw.toLowerCase();
    if (m.contains('invalid login')) {
      return 'Email o password sbagliate.';
    }
    if (m.contains('email not confirmed')) {
      return 'Devi prima confermare la tua email.';
    }
    return 'Accesso non riuscito. Riprova.';
  }

  String _messageForSignUp(String raw) {
    final m = raw.toLowerCase();
    if (m.contains('already registered') || m.contains('already been registered')) {
      return 'Questa email e gia registrata. Prova a collegarti.';
    }
    if (m.contains('password should be at least')) {
      return 'La password deve essere lunga almeno 6 caratteri.';
    }
    if (m.contains('unable to validate email')) {
      return 'Questo indirizzo email non e valido.';
    }
    if (m.contains('rate limit') || m.contains('too many')) {
      return 'Troppe richieste. Attendi qualche minuto e riprova.';
    }
    return 'Registrazione non riuscita. Riprova.';
  }
}