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

/// Nome dell'Edge Function che fa da proxy verso il catalogo esterno.
  ///
  /// Lo slug e' ancora `jikan-proxy` perche' Jikan e' stato dismesso il 1°
  /// ottobre 2026 e la funzione non e' stata rinominata: dietro lo slug oggi
  /// ci sono AniList e Kitsu. Il nome e' un indirizzo, non una descrizione, e
  /// cambiarlo romperebbe il client gia' installato.
  static const String catalogFunction = 'jikan-proxy';

  /// Nome dell'Edge Function che trasforma l'indirizzo canonico di una fonte
  /// in un URL riproducibile.
  ///
  /// Va messa qui perche' lo slug e' l'unica cosa che collega il client alla
  /// funzione, e una stringa scritta a mano dentro il repository e' il modo
  /// piu' rapido di far scomparire "risoluzione non riuscita" senza che nessuno
  /// capisca perche'.
  static const String sourceResolverFunction = 'resolve-source';

  /// Nome dell'Edge Function che dice dove sta la sigla di un episodio.
  ///
  /// Il dato non sta nel catalogo: la sigla cambia da episodio a episodio e
  /// nessuno la scrive a mano. La funzione la chiede a un database pubblico
  /// (AniSkip) e la mette in cache, cosi' il player ha una finestra vera invece
  /// di un valore inventato.
  static const String animeIntroFunction = 'anime-intro';

  /// Base del Worker Cloudflare che rimanda ad AnimeUnity le richieste quando
  /// l'operatore mobile blocca il sito.
  ///
  /// Vuoto = nessun relay, si va diretti (il caso di chi e' su Wi-Fi). Il
  /// valore arriva da `--dart-define=ANIMERANK_RELAY=...` al momento della
  /// build, quindi non e' nel sorgente: un indirizzo personale nel codice
  /// sarebbe una configurazione, non una costante dell'app.
  static const String animeUnityRelay = String.fromEnvironment(
    'ANIMERANK_RELAY',
    defaultValue: '',
  );
  /// Quanti giorni un anime puo' restare in cache prima di essere ricaricato
  /// dall'API esterna. Piu' alto = meno chiamate fuori, dati piu' freschi
  /// richiedono piu' chiamate. 7 giorni e' un buon compromesso: i dati di
  /// catalogo non cambiano ogni giorno.
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
