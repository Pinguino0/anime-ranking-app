# AnimeRank — passaggio di consegne per la versione iPhone

Documento di sintesi per aprire una chat nuova e ragionare **cosa fare per iPhone**.
Contiene: cosa è l'app, cosa abbiamo fatto, a che punto è il rilascio, cosa è già
pronto lato iOS, cosa manca, i punti tecnici delicati e le domande aperte.

Ultimo aggiornamento: 15 ottobre 2026.

---

## 1. In due righe

AnimeRank è un'app **Flutter + Supabase** per tenere traccia degli anime, votarli,
fare classifiche di gruppo, mantenere una watchlist e **guardare gli episodi**
dentro l'app. È nata per Android, gira anche su **Windows**, e adesso vogliamo
portarla su **iPhone**. Il backend è unico e condiviso: iOS non richiede modifiche
al database, solo alla configurazione dell'app e ai punti specifici della
piattaforma descritti più sotto.

---

## 2. Stack e versioni

| Cosa | Valore |
|---|---|
| Linguaggio | Dart (SDK `^3.13.4`) |
| Framework | Flutter (in CI fissato a **3.47.5**) |
| Backend | Supabase (`supabase_flutter ^2.18.0`) |
| Stato | Riverpod (`flutter_riverpod ^3.4.3`) — API `AsyncValue` con `.asData?.value`, non `valueOrNull` |
| Navigazione | `go_router ^18.0.2` |
| Player video | `media_kit` / `media_kit_video` (mpv) |
| Push | Firebase (`firebase_core`, `firebase_messaging`) + `flutter_local_notifications` |
| Progetto Supabase | `sjbstiexythmapxmrfyp` |
| Progetto Firebase | `animerank-4b0e2` |
| Versione app | `0.0.18+18` (`client/pubspec.yaml`) |

Codice dell'app in `client/`, backend in `supabase/`, documenti alla radice.

---

## 3. Stato attuale del rilascio

- **Ultima versione pubblicata: v0.0.18.** Buildata dal commit `324815b`
  ("ricostruisce la home con sezioni reali e dati verificabili").
- Caricata su GitHub: `Pinguino0/animerank-releases` → tag `v0.0.18`,
  file `animerank-0.0.18.apk` (81,1 MB).
- Riga inserita in `public.app_releases` (version_code 18).
- **Notifica "Aggiornamento disponibile" inviata a tutti**: il trigger
  `app_releases_notify_update` ha creato **8 notifiche in-app** (una per profilo) e
  i device con push attivo hanno ricevuto il push FCM (**4 dispositivi**:
  ItsLucaa, Hrn, negraxxio, gavaaa_).
- Catena dei push (invariata, da riusare per iPhone):
  `notifications` INSERT → trigger `notifications_push_webhook` → Edge Function
  `send-push` → FCM HTTP v1. Il testo del push è fisso: «Aggiornamento
  disponibile — La versione X è pronta. Tocca per aggiornare.»

---

## 4. Cosa c'è nell'app oggi (funzionalità)

Cartelle in `client/lib/features/`:

`achievements`, `anime`, `auth`, `comments`, `duels`, `episodes`, `groups`,
`history`, `home`, `notifications`, `novita`, `profile`, `ranking`, `shell`,
`tournaments`, `update`, `watchlist`.

In sintesi:

- **Auth** (registrazione, login, conferma email con deep link).
- **Catalogo anime** — ricerca, scheda anime, generi, stagioni, "da dove iniziare"
  (ordine di visione), relazioni tra opere.
- **Ranking** — classifiche di gruppo (più votati, divisivi), ranking personale,
  snapshot storico.
- **Watchlist** — personale e di gruppo, con stati (Da iniziare / In visione /
  Completato / Droppato / In pausa), preferiti, progresso.
- **Episodi + player** — fonti risolte (AnimeUnity, AnimeSaturn, …), salto intro
  (AniSkip), tracciamento del progresso.
- **Novità** — pagina dedicata (in uscita, nuovi episodi, continua a guardare).
- **Gruppi** — membri, attività, inviti, duelli, tornei.
- **Notifiche** — in-app + push.
- **Profilo** — statistiche, foto profilo, impostazioni.
- **Aggiornamenti** — gate versione + download APK (solo Android).

Qualità: `flutter analyze` pulito, **681 test verdi**.

---

## 5. Ultimo lavoro fatto: la Home ridisegnata

La Home è stata riscritta come `ConsumerWidget` con `CustomScrollView` +
`RefreshIndicator`, con 12 sezioni **tutte su dati reali** (niente liste statiche):

1. Header compatto + ricerca
2. Hero (selezione deterministica, voto community solo se esistono voti)
3. Continua a guardare
4. Guardati di recente (distinta da "Continua")
5. Ultime novità
6. Più popolari
7. Più votati dalla community
8. Riprendi dalla Watchlist
9. Consigliati per te (mostrata solo con segnale reale)
10. Stagione corrente
11. Attività degli amici (group-scoped, rispetta RLS)
12. Anime casuale

File principali:

- `client/lib/features/home/screens/home_screen.dart`
- `client/lib/features/home/home_controller.dart`
- `client/lib/features/home/widgets/home_{sections,hero,header}.dart`
- `client/lib/features/home/data/home_activities_repository.dart`

**Lacune dichiarate (non finte), utili da sapere:**
- in "Guardati di recente" non c'è il **voto personale**: la RPC `watch_history`
  non lo espone;
- in "Continua a guardare" non c'è la **barra di avanzamento**: il DB non memorizza
  la durata dell'episodio.
- Nessuna migrazione è stata necessaria per la Home.

---

## 6. Come si pubblica su Android (e perché su iOS è diverso)

Su Android il rilascio è automatizzato da uno script sul Desktop:

```powershell
C:\Users\erent\Desktop\publish.ps1 -VersionName 0.0.18 -VersionCode 18 -Notes "testo del dialogo"
```

Fa: build APK universale (arm32+arm64) con le `--dart-define` → carica la release
su `Pinguino0/animerank-releases` con `gh` → stampa l'`INSERT` per `app_releases`.
Quell'INSERT **non è silenzioso**: manda la notifica di aggiornamento a tutti.
(Comandi storici in `COMANDI_USATI.md`.)

**Su iPhone tutto questo non vale**, ed è il punto centrale della prossima chat:

1. **L'app non si aggiorna da sola** — Apple vieta l'auto-aggiornamento. Il gate
   `app_releases` è spento di proposito su iOS; gli aggiornamenti li consegna
   **TestFlight**.
2. **Il push va configurato a parte** (APNs + `GoogleService-Info.plist`).
3. **La distribuzione non è un APK**: serve **TestFlight** (Apple Developer
   Program, 99 $/anno) **oppure** il sideload di un IPA non firmato con
   **AltStore** (gratis, ma richiede un Mac/PC e rifirma ogni 7 giorni con
   l'Apple ID).

---

## 7. Stato iOS: cosa c'è già, cosa manca

### Già pronto nel repo

- **Icona iOS** generata da `assets/icon/app_icon.png`
  (`flutter_launcher_icons`, con `remove_alpha_ios: true`).
- **`codemagic.yaml`** alla radice: workflow `ios-testflight` (Mac M2 in cloud,
  firma automatica, carica su TestFlight). 500 min/mese gratis.
- **`.github/workflows/build-ios.yml`**: IPA **non firmato** per sideload
  AltStore (parte a mano da Actions, scarica l'artefatto).
- **`GUIDA_IPA_IOS.md`**: la guida passo-passo (fasi A–E) — leggerla prima di
  iniziare.
- Nel codice, il push è **già consapevole di iOS**:
  `client/lib/features/notifications/data/firebase_push_messaging.dart` gestisce
  `TargetPlatform.iOS` e la stringa piattaforma `'ios'`.
- `Info.plist` ha già lo **URL scheme** `io.animerank.app` (deep link) e la
  descrizione `NSPhotoLibraryUsageDescription`.

### Manca

- **Apple Developer Program** attivo (a carico dell'utente) → registrare il
  **Bundle ID** `com.animerank.animerank`, creare l'app in App Store Connect,
  creare la **chiave API** per Codemagic e la **chiave APNs** per il push.
- **Codemagic**: collegare l'account e l'integrazione `animerank-asc`.
- **Push iOS**: `GoogleService-Info.plist` in `client/ios/Runner/`,
  `Runner.entitlements` con `aps-environment`, `UIBackgroundModes:
  remote-notification` in `Info.plist`, chiave APNs caricata su Firebase.
- **`client/ios/Runner/` non contiene ancora** né `GoogleService-Info.plist` né
  `Runner.entitlements` (verificato).
- Adattare `send-push` perché l'`app_update` vada **solo ai device Android**
  (già previsto nella guida, Fase D).

---

## 8. Rischi e specificità tecniche iOS (con i file)

Da affrontare nella nuova chat, in ordine di rischio percepito:

1. **Player video (`media_kit`/mpv)** — è la parte che la guida stessa segnala
   come più delicata. File: `client/lib/features/episodes/presentation/widgets/episode_player.dart`.
   Va provato su device reale con una fonte HLS e una mp4.

2. **Bypass del blocco dell'operatore mobile** — su Android il player aggira il
   filtro TLS delle reti mobili (WindTre) usando il motore di rete di Chromium.
   Il codice è `client/lib/features/episodes/data/chromium_http.dart`, con
   `ChromiumHttp.supported => Platform.isAndroid`. **Su iOS il bypass oggi non è
   attivo**: su dati mobili le fonti potrebbero non risolversi. Da decidere se
   serve un'alternativa (es. DoH) o se accettare il limite in v1.

3. **Aggiornamento in-app** — `ota_update` è Android-only. Su iOS il gate è già
   spento: `client/lib/features/update/presentation/app_update_controller.dart`
   usa una guardia `defaultTargetPlatform == TargetPlatform.android`, e
   `client/lib/features/update/data/update_background_task.dart` esce subito se
   non è Android.

4. **Task in background (`workmanager`)** — Android-only nel codice attuale.
   Eventuali sync periodici su iOS richiedono `BGTaskScheduler` / config a parte.

5. **Deep link / auth** — lo scheme `io.animerank.app` è in `Info.plist`; da
   verificare che login e conferma email col deep link funzionino su iOS.

6. **Politica App Store** — punto non tecnico ma decisivo: le **fonti di
   streaming** (AnimeUnity/AnimeSaturn) sono contenuti non ufficiali. Apple è più
   severa di Google su questo. Se si va su TestFlight **solo per tester interni**
   il rischio è basso; per una pubblicazione pubblica o test esterni potrebbe
   essere un problema. Da valutare prima di investire tempo.

7. **Backend** — nessuna migrazione necessaria per iOS: il DB è condiviso. Le
   chiavi restano `--dart-define` pubblicabili (mai segreti nel client).

---

## 9. Domande aperte per la prossima chat

- **Come distribuiamo su iPhone?** TestFlight (serve Apple Developer, 99 $/anno,
  più comodo) **oppure** sideload IPA non firmato con AltStore (gratis, ma
  rifirma ogni 7 giorni)?
- **Quanto conta il push iOS** adesso? Senza APNs l'app funziona, ma niente
  notifiche.
- **Il player su iPhone**: verifichiamo prima `media_kit` su un device reale, dato
  che è il rischio numero uno.
- **Bypass dati mobili su iOS**: lo vogliamo in v1 o accettiamo il limite?
- **Rischio review Apple** con le fonti non ufficiali: TestFlight interno è
  sufficiente come obiettivo, o puntiamo a test esterni/pubblico?
- **La voce "app_update" su iOS** non deve arrivare: confermiamo che ha senso
  mandarla sempre e solo ai device Android?
- **Versioning**: su iOS il numero di build lo gestisce Codemagic/TestFlight; da
  decidere se tenere `pubspec.yaml` come unica fonte.

---

## 10. Dove guardare (file e comandi)

Documenti utili:

- `GUIDA_IPA_IOS.md` — guida iOS completa (fasi A–E).
- `GUIDA_FIREBASE_PUSH.md` — configurazione push.
- `COMANDI_USATI.md` — build/release/migrazioni.
- `codemagic.yaml` — workflow TestFlight.
- `.github/workflows/build-ios.yml` — IPA non firmato (AltStore).

Comandi rapidi:

```powershell
# Test + analisi (dalla cartella client/)
flutter analyze
flutter test

# Build APK Android (universale) con le dart-define
flutter build apk --release --target-platform android-arm,android-arm64 `
  --dart-define=SUPABASE_URL=https://sjbstiexythmapxmrfyp.supabase.co `
  --dart-define=SUPABASE_ANON_KEY=sb_publishable_JqBGHeAUT068w6-Ex1L8OQ_f6OpCSMc `
  --dart-define=ANIMERANK_RELAY=https://animerank-relay.titanoeren171.workers.dev
```

Nota: `--build-number`/`--build-name` servono solo se `pubspec.yaml` non è stato
aggiornato.

---

### Riepilogo in una riga

Android è in produzione (v0.0.18, notifica ad appena inviata a tutti); iOS ha già
icona, config CI e guida, ma prima di partire servono le **chiavi Apple** e una
decisione su **distribuzione (TestFlight vs AltStore)**, con il **player** e il
**bypass dati mobili** come principali incognite tecniche.
