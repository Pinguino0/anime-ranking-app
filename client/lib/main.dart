import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/cache/hive_cache_store.dart';
import 'core/cache/session_cache_cleanup.dart';
import 'core/env/app_config.dart';
import 'core/supabase/supabase_provider.dart';
import 'features/achievements/data/achievements_repository.dart';
import 'features/achievements/presentation/achievements_controller.dart';
import 'features/anime/data/anime_repository.dart';
import 'features/anime/presentation/anime_controller.dart';
import 'features/auth/data/auth_repository.dart';
import 'features/auth/presentation/auth_controller.dart';
import 'features/comments/data/comments_repository.dart';
import 'features/comments/presentation/comments_controller.dart';
import 'features/episodes/data/episodes_repository.dart';
import 'features/episodes/presentation/episodes_controller.dart';
import 'features/duels/data/duels_repository.dart';
import 'features/duels/presentation/duels_controller.dart';
import 'features/groups/data/groups_repository.dart';
import 'features/groups/presentation/groups_controller.dart';
import 'features/history/data/history_repository.dart';
import 'features/history/presentation/history_controller.dart';
import 'features/home/data/home_activities_repository.dart';
import 'features/home/home_controller.dart';
import 'features/notifications/data/device_token_repository.dart';
import 'features/notifications/data/firebase_push_messaging.dart';
import 'features/notifications/data/push_messaging.dart';
import 'features/notifications/data/push_notifications.dart';
import 'features/notifications/presentation/push_controller.dart';
import 'features/profile/data/profile_repository.dart';
import 'features/profile/presentation/profile_controller.dart';
import 'features/ranking/data/cached_ranking_repository.dart';
import 'features/ranking/data/ranking_repository.dart';
import 'features/ranking/presentation/ranking_controller.dart';
import 'features/tournaments/data/tournaments_repository.dart';
import 'features/tournaments/presentation/tournaments_controller.dart';
import 'features/update/data/app_release_repository.dart';
import 'features/update/data/install_permission.dart';
import 'features/update/data/update_background_task.dart';
import 'features/update/data/update_cleanup.dart';
import 'features/watchlist/data/watchlist_repository.dart';
import 'features/watchlist/presentation/watchlist_controller.dart';

/// Punto d'ingresso.
///
/// Inizializza Supabase una volta sola e poi passa il client gia' costruito
/// dentro il [ProviderScope], invece di far leggere `Supabase.instance` ai
/// provider. Il motivo e' la testabilita': i test non devono simulare il
/// bootstrap globale, basta sovrascrivere [supabaseProvider] e
/// [authRepositoryProvider] con dei finti.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // `media_kit` e' mpv in un'altra incognita: va inizializzato una volta sola,
  // prima di `runApp`, e non dentro il player.
  //
  // Ma il video e' una funzione, non l'app. `MediaKit.ensureInitialized()`
  // rilancia l'errore se le librerie native di mpv non si caricano, e sui
  // telefoni piu' vecchi — o con un ABI che il pacchetto non include — succede.
  // Senza questa rete l'eccezione usciva da `main` prima di `runApp` e l'app si
  // apriva e si chiudeva subito. Ora si parte lo stesso: il resto funziona e
  // sara' la schermata video a dire che quel dispositivo non puo' riprodurre,
  // invece di lasciare l'utente davanti a un'app che non si apre.
  try {
    MediaKit.ensureInitialized();
  } catch (error, stack) {
    debugPrint('media_kit non disponibile su questo dispositivo: $error');
    debugPrintStack(stackTrace: stack);
  }

  if (!AppConfig.isConfigured) {
    // Senza credenziali non si costruisce nessun client: l'app mostra le
    // istruzioni invece di aprire schermate che esploderebbero al primo tocco.
    runApp(const SetupApp());
    return;
  }

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    // publishableKey, non anonKey: quest'ultimo e deprecato in supabase_flutter
    // 2.18. La chiave da usare resta in ogni caso quella pubblica.
    publishableKey: AppConfig.supabaseAnonKey,
  );

  final client = Supabase.instance.client;

  // La cache si apre una volta sola e prima di `runApp`: se il disco non
  // collabora, [HiveCacheStore.open] restituisce una cache vuota e l'app parte
  // lo stesso, solo con una richiesta di rete in piu'.
  final cache = await HiveCacheStore.open();

  // Il push si prepara una volta, qui: inizializza Firebase, crea il canale
  // Android e (piu' tardi, quando c'e' un utente) registra il token. Se
  // Firebase non c'e' — desktop, oppure una build senza `google-services.json`
  // — si prosegue con un servizio muto invece di impedire l'avvio.
  final pushMessaging = await _bootstrapPush();

  final cachedRanking = CachedRankingRepository(
    SupabaseRankingRepository(client),
    cache,
    // Letto a ogni accesso, non qui: al logout l'utente cambia e le chiavi
    // devono smettere di essere quelle del vecchio account.
    userId: () => client.auth.currentUser?.id,
  );

  // La copia su disco dell'utente che esce va buttata via, e va fatto qui perche'
  // e' l'unico posto dove la cache e il canale auth si incontrano.
  SessionCacheCleanup(
    cachedRanking,
    SupabaseAuthRepository(client).watch(),
  ).start();

  final container = ProviderContainer(
    overrides: [
      supabaseProvider.overrideWithValue(client),
      authRepositoryProvider.overrideWithValue(
        SupabaseAuthRepository(client),
      ),
      // Il repository gruppi riceve lo stesso client: nessuna nuova
      // connessione, nessuna seconda istanza di Supabase da tenere viva.
      groupsRepositoryProvider.overrideWithValue(
        SupabaseGroupsRepository(client),
      ),
      profileRepositoryProvider.overrideWithValue(
        SupabaseProfileRepository(client),
      ),
      achievementsRepositoryProvider.overrideWithValue(
        SupabaseAchievementsRepository(client),
      ),
      commentsRepositoryProvider.overrideWithValue(
        SupabaseCommentsRepository(client),
      ),
      // Il catalogo non va in cache: cambia di continuo, e mostrare una
      // copia vecchia su una ricerca ripeterebbe l'effetto scomodo che la
      // cache della classifica evita solo perche' li' i dati cambiano poco.
      animeRepositoryProvider.overrideWithValue(
        SupabaseAnimeRepository(client),
      ),
      // Solo la classifica va in cache: e' l'unica schermata che si
      // riapre spesso e che un utente stanco di aspettare accetta di vedere
      // anche copiata, con un avviso che lo dice.
      rankingRepositoryProvider.overrideWithValue(cachedRanking),
      watchlistRepositoryProvider.overrideWithValue(
        SupabaseWatchlistRepository(client),
      ),
      duelsRepositoryProvider.overrideWithValue(
        SupabaseDuelsRepository(client),
      ),
      tournamentsRepositoryProvider.overrideWithValue(
        SupabaseTournamentsRepository(client),
      ),
      // Episodi, fonti e progresso: stesso client degli altri moduli. Va
      // dichiarato qui perche' il provider di default esiste solo per i test
      // — in produzione un repository non inizializzato deve fallire subito
      // invece di fingere che gli episodi non esistano.
      episodesRepositoryProvider.overrideWithValue(
        SupabaseEpisodesRepository(client),
      ),
      // Storico di visione: "Continua da guardare" e Cronologia. Stesso client
      // degli altri moduli, e stesso motivo per cui va dichiarato qui — in
      // produzione un repository non inizializzato deve fallire subito invece di
      // far credere che non ci sia niente da riprendere.
      historyRepositoryProvider.overrideWithValue(
        SupabaseHistoryRepository(client),
      ),
      // Feed delle attivita' dei gruppi, per la sezione "Attivita' degli
      // amici": legge `activities`, che i trigger del database riempiono gia'
      // con voti, watchlist e avanzamenti. Stesso client e stessa regola degli
      // altri moduli.
      homeActivitiesRepositoryProvider.overrideWithValue(
        SupabaseHomeActivitiesRepository(client),
      ),
      // Le versioni pubblicate, lette una volta all'avvio. Va dichiarato qui
      // con la stessa regola degli altri moduli: il provider di default
      // esiste solo per i test, e in produzione un repository non
      // inizializzato deve accorgersi subito di non poter controllare gli
      // aggiornamenti invece di girare in silenzio.
      appReleaseRepositoryProvider.overrideWithValue(
        SupabaseAppReleaseRepository(client),
      ),
      // Il controllo del permesso di installazione passa per il MainActivity:
      // in produzione c'e' un canale nativo, nei test un finto.
      installPermissionProvider.overrideWithValue(
        MethodChannelInstallPermission(),
      ),
      // Il token FCM del dispositivo va scritto in `device_tokens`; il servizio
      // push e' quello preparato da [_bootstrapPush] poco sopra.
      deviceTokenRepositoryProvider.overrideWithValue(
        SupabaseDeviceTokenRepository(client),
      ),
      pushMessagingProvider.overrideWithValue(pushMessaging),
    ],
  );

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const AnimeRankApp(),
    ),
  );

  // Non si aspetta, e parte solo dopo il primo frame. L'avviso "c'e' da
  // aggiornare" non e' piu' una notifica locale programmata qui: lo manda il
  // server con un push (trigger su `app_releases`). Questa chiamata resta solo
  // per la pulizia periodica degli APK lasciati dagli aggiornamenti, che e' di
  // servizio e non deve bloccare l'avvio.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(bootstrapUpdateMaintenance());

    // Gli APK degli aggiornamenti passati li butta gia' il task periodico, ma
    // fino a una volta a settimana: chi apre l'app spesso non aspetta il giro
    // del WorkManager. Qui si ripulisce a ogni avvio, che e' quando gli APK
    // lasciati dall'ultimo aggiornamento non servono piu' a nessuno.
    unawaited(deleteLeftoverUpdateApks());

    // Avvia il servizio push: registra il token dell'utente collegato e resta
    // in ascolto dei messaggi. Dopo il primo frame perche' un tap su una
    // notifica deve poter navigare su un albero gia' montato.
    container.read(pushControllerProvider);
  });
}

/// Prepara il servizio push, o restituisce quello muto se non e' possibile.
///
/// Firebase non e' d'obbligo per usare l'app: su desktop non c'e' proprio, e su
/// Android una build senza `google-services.json` non lo configura. In tutti
/// quei casi l'app deve aprirsi lo stesso, solo senza push.
Future<PushMessaging> _bootstrapPush() async {
  // Sul web Firebase va configurato a parte (un'app web in console + una
  // chiave VAPID per il Web Push): senza, `initializeApp` fallisce e riempie
  // la console di errori a ogni avvio. Per la PWA il push e' semplicemente
  // spento, che e' lo stato normale finche' non si configura il web push:
  // le notifiche interne all'app funzionano lo stesso.
  if (kIsWeb) return const UnsupportedPushMessaging();

  try {
    await Firebase.initializeApp();
  } catch (error, stack) {
    debugPrint('Firebase non disponibile: $error');
    debugPrintStack(stackTrace: stack);
    return const UnsupportedPushMessaging();
  }

  final messaging = FirebasePushMessaging();
  if (!messaging.isSupported) return const UnsupportedPushMessaging();

  try {
    await messaging.initialize();
    // Il canale va creato prima del primo push: da Android 8 una notifica
    // senza canale non compare affatto.
    await PushNotifications.instance.initialize();
  } catch (error, stack) {
    debugPrint('Push non inizializzabili: $error');
    debugPrintStack(stackTrace: stack);
    return const UnsupportedPushMessaging();
  }

  return messaging;
}
