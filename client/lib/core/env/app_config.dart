/// Configurazione dell'applicazione, letta a compile-time.
///
/// Le credenziali arrivano tramite --dart-define e NON sono nel sorgente:
///   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
///
/// Solo la publishable key puo finire qui dentro. La secret key (sb_secret_...)
/// non deve MAI raggiungere il client: chi installa l'app puo leggere il
/// pacchetto .apk/.ipa e con la secret key leggerebbe tutto il database
/// bypassando la RLS.
library;

class AppConfig {
  const AppConfig._();

  /// URL del progetto Supabase, es. https://abcdef.supabase.co
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: '',
  );

  /// Chiave pubblica (sb_publishable_... o la vecchia anon key).
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: '',
  );

  /// Nome dell'Edge Function che fa da proxy verso Jikan/MyAnimeList.
  static const String jikanFunction = 'jikan-proxy';

  /// Quanti giorni un anime puo restare in cache prima di essere ricaricato
  /// dall'API esterna. Piu alto = meno chiamate a Jikan, dati piu' freschi
  /// richiedono piu' chiamate. 7 giorni e' un buon compromesso: i dati di
  /// catalogo di MyAnimeList non cambiano ogni giorno.
  static const int animeCacheDays = 7;

  /// Quanti risultati chiedere per pagina alla ricerca anime.
  static const int searchPageSize = 24;

  /// Quante righe caricare per pagina nelle liste lunghe (ranking, ecc).
  static const int listPageSize = 50;

  /// true se le variabili obbligatorie mancano: in quel caso l'app mostra
  /// una schermata di setup invece di crashare all'avvio con uno stack trace.
  static bool get isConfigured =>
      supabaseUrl.startsWith('http') && supabaseAnonKey.length > 20;

  /// Causa leggibile del mancato setup, per mostrarla all'utente.
  static String get configurationError {
    if (supabaseUrl.isEmpty) {
      return 'SUPABASE_URL non e definito.\n'
          'Avvia con:\n'
          '  flutter run --dart-define=SUPABASE_URL=https://<tuo>.supabase.co '
          '--dart-define=SUPABASE_ANON_KEY=<publishable key>';
    }
    if (supabaseAnonKey.isEmpty) {
      return 'SUPABASE_ANON_KEY non e definito.\n'
          'La chiave si trova in Supabase -> Project Settings -> API Keys.\n'
          'Serve la publishable key (sb_publishable_...), non la secret key.';
    }
    return 'Configurazione Supabase non valida.';
  }
}
