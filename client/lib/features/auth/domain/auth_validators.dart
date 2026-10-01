/// Validazione dei campi del modulo di autenticazione.
///
/// Le regole qui dentro sono la copia lato client di vincoli che il database
/// impose comunque: servono a dare un riscontro immediato, non a sostituire il
/// controllo del server. Se le due copie divergono, la UI sembra accettare
/// valori che il backend rifiuta, che e' il caso peggiore.
///
/// Fonte: `profiles_username_format` in 002_profiles.sql.
library;

class AuthValidators {
  const AuthValidators._();

  /// Stesso pattern del CHECK `^[A-Za-z0-9_]{3,24}$` sul database.
  static final RegExp _usernameFormat = RegExp(r'^[A-Za-z0-9_]{3,24}$');

  /// Cifre almeno in una parte della password.
  ///
  /// Vale solo per la password, non per il nome utente: il database non ha
  /// alcun requisito numerico sul nome e imporre qui una cifra significherebbe
  /// rifiutare nomi che il backend accetterebbe, costringendo tutti a scrivere
  /// roba come "mario1". Sul nome la regola e' una sola: il CHECK del database.
  static final RegExp _hasDigit = RegExp(r'[0-9]');

  /// Stessa soglia di `supabase.auth` (GoTrue): 6 caratteri.
  static const int minPasswordLength = 6;

  static const int minUsernameLength = 3;
  static const int maxUsernameLength = 24;

  /// true se il nome rispetta il formato del database.
  static bool isValidUsernameFormat(String value) => _usernameFormat.hasMatch(value);

  /// Messaggio d'errore per il nome, o null se il valore e' accettabile.
  ///
  /// Restituisce una stringa invece di un booleno perche' l'utente deve sapere
  /// perche' il campo e' rosso: "non valido" da solo fa indovinare.
  static String? usernameError(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return 'Scegli un nome utente.';
    if (v.length < minUsernameLength) {
      return 'Almeno $minUsernameLength caratteri.';
    }
    if (v.length > maxUsernameLength) {
      return 'Massimo $maxUsernameLength caratteri.';
    }
    if (!_usernameFormat.hasMatch(v)) {
      return 'Solo lettere, cifre e underscore. Niente spazi o accenti.';
    }
    return null;
  }

  /// Messaggio d'errore per l'email, o null se valida.
  static String? emailError(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return 'Inserisci la tua email.';
    // Deliberatamente permissivo: la validazione vera la fa GoTrue, che
    // rifiuta gli indirizzi impossibili. Un pattern stretto qui respincherebbe
    // indirizzi rari ma legittimi (TLD nuovi, domini con punteggio).
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v)) {
      return 'Questo indirizzo email non sembra valido.';
    }
    return null;
  }

  /// Messaggio d'errore per la password, o null se valida.
  ///
  /// [isRegistration] allega il requisito della cifra, che per l'accesso non
  /// si puo' pretendere: se l'utente ha un account vecchio con una password
  /// debole, non deve restare fuori dal suo account.
  static String? passwordError(String? value, {required bool isRegistration}) {
    final v = value ?? '';
    if (v.isEmpty) return 'Inserisci la password.';
    if (v.length < minPasswordLength) {
      return 'Almeno $minPasswordLength caratteri.';
    }
    if (isRegistration && !_hasDigit.hasMatch(v)) {
      return 'Inserisci almeno una cifra.';
    }
    return null;
  }
}