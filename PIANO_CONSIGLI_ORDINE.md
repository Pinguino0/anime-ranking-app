# Piano — Watchlist personale, "Consiglia" (+ notifiche push), Ordine di visione

Stato: **in corso** (Fasi 1-3, Fase 5, Fase 6 e l'avviso di aggiornamento via push COMPLETI; resta il centro notifiche in-app). Data: 2026-10-11.

### Avanzamento (2026-10-11)

- ✅ **Fase 1 — Watchlist personale**: migrazione `20261011150000_personal_watchlist.sql` applicata; client aggiornato; `flutter analyze` pulito.
- ✅ **Fase 2 — Watchlist di gruppo "consigliata da tutti"**: `entries()` legge tutti i membri; schermata gruppo mostra sezione **"Consigliati dal gruppo"** (card read-only con "Consigliato da …", messaggi e "Per … - da …") sopra la propria lista; merge per anime; i filtri nascondono i consigli.
- ✅ **Fase 3 — "Consiglia"**: DB (`20261011160000_recommendations_setup.sql` + `20261011162000_recommendations.sql` applicate: tabella `anime_recommendations`, `watchlists.message`, enum `anime_recommended`, trigger + `notify_user`); client: bottone **"Consiglia"** + foglio `RecommendSheet` (a tutti / a persona + messaggio), bottoni **"Nella mia lista"** e **"Nel gruppo"** nella scheda anime.
- ✅ **Fase 4 (metà) — Interruttore "Consigli"**: `notify_recommendations` in `NotificationPreferences` (dominio, repository, controller) + riga nella schermata Notifiche, con modalità "Solo importanti"/"Nessuna"/"Tutte" aggiornate.
- ⬜ **Fase 4 (resto) — Centro notifiche in-app**: manca la feature `features/notifications/` (elenco + badge + "segna come letta") e la campanella.
- ✅ **Fase 5 — Ordine di visione "Da dove iniziare"**: migrazione `20261011195000_watch_order.sql` applicata — RPC `anime_watch_order` che percorre la componente connessa prequel/sequel (grafo non orientato), ordina per `aired_from`/anno/id AniList e marca `is_start` sulla prima voce. Client: modello `WatchOrderItem`, `watchOrderProvider`, sezione **"Da dove iniziare"** sotto la trama (card numerate, badge "Inizia da qui", nascosta con meno di 2 voci). **2 test Flutter nuovi**.
- ✅ **Fase 6 — Push FCM** (COMPLETA: server + client):
  - ✅ DB: tabella `device_tokens` (migrazione `20261011170000_device_tokens.sql`: RLS "solo il proprietario", 4 policy, trigger `updated_at`, `revoke from anon`); RPC `register_device_token` / `remove_device_token` (migrazione `20261011190000_device_token_rpc.sql`) per riassegnare il token quando lo stesso telefono cambia account.
  - ✅ Edge Function `supabase/functions/send-push/` deployata: legge il webhook di `notifications`, invia via **FCM HTTP v1** (JWT RS256 → access token in cache), maschera le notifiche `sensitive`, cancella i token morti. **12 test Deno verdi**, `deno check` pulito.
  - ✅ Webhook lato DB: migrazione `20261011180000_push_webhook.sql` — trigger `notifications_push_webhook` (AFTER INSERT) → `net.http_post` (`pg_net`) → `send-push`. Il segreto condiviso sta in **Vault** (`push_webhook_secret`) e in `PUSH_WEBHOOK_SECRET`; parte solo se `profiles.notify_push` è acceso.
  - ✅ Credenziali Firebase caricate: `FIREBASE_SERVICE_ACCOUNT` (Edge secret), `client/android/app/google-services.json`, progetto `animerank-4b0e2`.
  - ✅ **Collaudo end-to-end** (token finto): `net._http_response` → `200 {"sent":0,"failed":1,"removed":1,"project":"animerank-4b0e2"}`; trigger, autenticazione, FCM e pulizia token tutti confermati.
  - ✅ **Client**: `firebase_core` + `firebase_messaging`; plugin Gradle `com.google.gms.google-services` 4.5.0; permesso Android 13 (`POST_NOTIFICATIONS`) + canale di default nell'AndroidManifest; feature `features/notifications/` (`PushMessaging` astratto + `FirebasePushMessaging` + `PushController`); RPC `register_device_token`/`remove_device_token` (riassegnazione token al cambio account); canale `animerank_default`; tap → apre la watchlist del gruppo; notifica in-app in primo piano. **6 test Flutter nuovi**.
- ✅ **Avviso di aggiornamento via push** (sostituisce la notifica locale): migrazioni `20261011200000_app_update_notification_type.sql` (enum `app_update`) e `20261011201000_app_update_push.sql` (trigger `app_releases_notify_update`): pubblicare un rilascio crea una notifica per **ogni** profilo, che la catena push consegna a chi ha "Notifiche push" acceso. Client: rimossi `update_notifications.dart` e il controllo versione in background; restano la pulizia periodica degli APK (`bootstrapUpdateMaintenance`) e il gate a schermo intero all'avvio. Collaudo in transazione annullata: 6 profili → 6 notifiche `app_update`, nessun residuo. **1 test Flutter nuovo**.

Test: **565 verdi** (Flutter) + **12 verdi** (Deno `send-push`), `flutter analyze` pulito.


---

## 0. Cosa c'è già

- **Fix schermo nero fullscreen player** → fatto (`client/lib/features/episodes/presentation/widgets/episode_player.dart`): un solo `mkv.Video` montato per volta. Compila pulito, da verificare su device.

---

## 1. Watchlist personale (tabella separata) + barra in basso

**Richiesta**: la voce in basso ("La mia lista") è la watchlist **personale** dell'utente, slegata dai gruppi.

**Decisione**: tabella **separata** (non `watchlists.group_id NULL`).

### DB
Nuova tabella `public.personal_watchlist`:
- `id uuid pk`
- `user_id uuid not null references profiles(id) on delete cascade`
- `anime_id uuid not null references anime(id) on delete cascade`
- `status public.watchlist_status not null default 'planned'`
- `current_episode integer not null default 0`
- `is_favorite boolean not null default false`
- `created_at`, `updated_at`
- unique `(user_id, anime_id)`, check `current_episode >= 0`
- trigger `set_updated_at` + trigger `check_watchlist_episode` (riuso esistente)
- **RLS**: `select/insert/update/delete` solo `user_id = auth.uid()`.

### Impatto
`personal_stats(...)` e la schermata "La mia lista" oggi leggono `watchlists` sui gruppi. Vanno spostati su `personal_watchlist` (senza `group_id`). La vista personale **non** mostrerà più la provenienza per gruppo.

### Client
- `watchlist_repository.dart`: `entriesAll()` → legge `personal_watchlist`; niente `groupId`.
- `WatchlistEntry`: `groupId` diventa nullable o si crea un modello dedicato `PersonalWatchlistEntry`.
- `my_list_screen.dart`: via il filtro per gruppo e la scritta gruppo.
- `shell_screen.dart`: la voce in basso punta a "La mia lista" personale (già così → solo sorgente dati cambia).

---

## 2. Watchlist di gruppo = "Consigliata da tutti"

**Richiesta**: la watchlist di un gruppo è l'unione delle voci di tutti i membri, con indicato **chi** l'ha consigliata.

- La tabella `watchlists` **resta** la lista di gruppo: una riga = un membro che mette un anime nel gruppo.
- La RLS `select` già consente ai membri di leggere tutte le righe del gruppo (`is_group_member(group_id)`).
- Oggi la schermata gruppo filtra `user_id = me`: va **tolto il filtro** per mostrare tutte le voci.
- Ogni voce mostra: poster + titolo + **"consigliato da <nome/i>"** + eventuale messaggio.

---

## 3. "Consiglia anime" (bottone) + popup

**Richiesta**:
- In scheda anime, vicino a "Vota in un gruppo", un bottone **Consiglia**.
- Popup: **a tutti** oppure **a una persona** (per nome) + **messaggio opzionale**.
- In ogni caso l'anime entra nella **watchlist di gruppo** (compare in "Consigliata da tutti").
- Il destinatario riceve una **notifica**: *"<nome> ti ha consigliato di vedere: <anime>"* (+ messaggio).
- Sotto la voce: **"consigliato per: <persona> — da <persona>"**.

### Bottoni in scheda (deciso da me)
1. **"Salva nella mia lista"** → watchlist personale (popup scelta stato).
2. **"Salva nel gruppo"** → aggiunge alla watchlist di gruppo **senza** notifica.
3. **"Consiglia"** → popup: destinatario (*a tutti* / *una persona*) + messaggio → aggiunge alla watchlist di gruppo **e** manda la notifica.

(Il popup di "Consiglia" è riusato: da "Salva nel gruppo" si può passare al consiglia con un tocco, come chiesto.)

### DB
Nuova tabella `public.anime_recommendations`:
- `id uuid pk`
- `group_id uuid not null references groups(id) on delete cascade`
- `from_user_id uuid not null references profiles(id) on delete cascade`
- `to_user_id uuid references profiles(id) on delete cascade` — **NULL = "a tutti"**
- `anime_id uuid not null references anime(id) on delete cascade`
- `message text` (max ~500 caratteri)
- `created_at timestamptz`
- **RLS**: membri del gruppo leggono; insert solo con `from_user_id = auth.uid()` e `to_user_id` membro del gruppo (o NULL).

Colonna nuova su `watchlists`: `message text` (il messaggio mostrato nella riga di gruppo).

### Trigger
`after insert on anime_recommendations` →
- assicura una riga in `watchlists` (gruppo, autore, anime) con il messaggio (così compare in "Consigliata da tutti");
- per ogni destinatario (tutti i membri se `to_user_id IS NULL`, altrimenti quello solo) chiama `notify_user(..., 'anime_recommended', ...)` con testo *"<autore> ti ha consigliato di vedere: <titolo>"* e `data` con `anime_id`, `group_id`, `from_user_id`.
- **Antispam** (proposta): nessuna notifica se lo stesso autore ha già consigliato lo stesso anime allo stesso destinatario nelle ultime 24h.

### Enum
Aggiungere valore **`anime_recommended`** a `public.notification_type`.
Aggiungere in `notify_user` il ramo: `when _type = 'anime_recommended' then notify_recommendations`.

---

## 4. Notifiche push (FCM) + centro notifiche in-app

**Richiesta**: notifica **push sul telefono**, anche a telefono chiuso.

**Cosa manca oggi**: l'app **non legge** la tabella `notifications` e non ha nessun centro notifiche.

### Pezzi
1. **DB**: tabella `device_tokens` (`user_id`, `token` unico, `platform`, `updated_at`), RLS sulle proprie righe. Colonna `profiles.notify_recommendations boolean not null default true`.
2. **Trigger → push**: Database Webhook su `notifications` insert → **Edge Function `send-push`** che usa FCM HTTP v1 (service account) e invia ai token dell'utente, poi rimuove i token morti.
3. **Client push**: `firebase_core` + `firebase_messaging` → permesso, token salvato in `device_tokens`, gestione messaggio (tap → apre l'anime).
4. **Client centro notifiche**: schermata "Notifiche" (campanella in alto) che legge `notifications`, badge non lette (realtime), tap → apre anime/gruppo; "segna come letta".
5. **Impostazioni**: nuovo interruttore **"Consigli"** nella schermata Notifiche; `notify_user` rispetta `notify_recommendations`.

### ⚠️ Cosa mi serve da te
- Progetto **Firebase** collegato all'app Android (`applicationId`).
- File **`google-services.json`** in `client/android/app/`.
- **Service account** FCM per l'Edge Function (segreto Supabase).
- `client/android/build.gradle` + `app/build.gradle`: plugin `com.google.gms.google-services`.
Senza questi il codice client/DB si può preparare, ma il **push resta spento**.

---

## 4-bis. Ordine di visione ("Da dove iniziare")

**Richiesta**: sotto la descrizione, per gli anime con più stagioni, qualcosa che dica **da quale stagione/opera iniziare**, con **immagine + nome** come nella home.

### Situazione attuale
- Esiste già la tabella `anime_relations` (prequel/sequel/…) e la sezione **"Correlati"** (`_Relations` in `anime_detail_screen.dart`, sopra la trama): mostra solo i vicini diretti, non la catena completa.

### DB
Nuova RPC `public.anime_watch_order(_anime_id uuid)`:
- Percorre le relazioni `PREQUEL` / `SEQUEL` / `PARENT` per costruire l'**intera catena** (componente connessa).
- Ordina per `aired_from` (fallback `year`, poi id AniList).
- Ritorna la stessa forma di `anime_related` + `position` + `is_start` (la prima = "Inizia da qui").
- Lettura per `authenticated`.

> Nota: è la catena principale. Film/OVA/special e storie collaterali possono essere esclusi dall'ordine e mostrati a parte. Da decidere (vedi domande).

### Client
- `anime.dart`: nuovo modello `WatchOrderItem`.
- `anime_repository.dart`: `watchOrder(animeId)`.
- `anime_controller.dart`: `watchOrderProvider(animeId)`.
- `anime_detail_screen.dart`: nuova sezione **sotto `_Synopsis`**, con card orizzontali (riuso stile `AnimeCard`/`_RelationCard`: poster + titolo) numerate, e badge **"Inizia da qui"** sulla prima. Se la catena ha una sola opera → sezione nascosta.

---

## 5. File toccati (riepilogo)

**Supabase** (`supabase/migrations/`)
- `…_personal_watchlist.sql` — tabella + RLS + trigger.
- `…_recommendations.sql` — `anime_recommendations`, `watchlists.message`, enum `anime_recommended`, trigger notifica, aggiornamento `notify_user`, `notify_recommendations`.
- `…_device_tokens.sql` — tabella + RLS.
- `…_watch_order.sql` — RPC `anime_watch_order`.
- `…_app_update_notification_type.sql` + `…_app_update_push.sql` — notifica `app_update` dal rilascio al push.
- Edge Function `supabase/functions/send-push/`.

**Client** (`client/lib/`)
- `features/watchlist/data/watchlist_repository.dart` + `domain/watchlist.dart` + `presentation/watchlist_controller.dart`
- `features/watchlist/presentation/screens/my_list_screen.dart` (+ `watchlist_screen.dart` gruppo)
- `features/anime/presentation/screens/anime_detail_screen.dart` (bottoni + sezione ordine di visione)
- `features/anime/{domain/anime.dart,data/anime_repository.dart,presentation/anime_controller.dart}` (ordine di visione)
- `features/update/data/update_background_task.dart` (solo pulizia APK; l'avviso di aggiornamento arriva dal push, `update_notifications.dart` rimosso)
- `features/profile/…` (colonna + interruttore "Consigli")
- nuova `features/notifications/…` (centro notifiche + push)
- `pubspec.yaml` (`firebase_core`, `firebase_messaging`)

---

## 6. Fasi proposte

1. **DB watchlist personale** (tabella + RLS + migrazione dati delle righe personali) e client "La mia lista".
2. **Watchlist gruppo "consigliata da tutti"** (togliere filtro utente, mostrare "chi").
3. **Consiglia anime** (tabella + trigger + popup + bottoni scheda).
4. **Centro notifiche in-app** (elenco + badge + interruttore "Consigli").
5. **Ordine di visione** (RPC + sezione sotto la trama).
6. **Push FCM** (Firebase + Edge Function + client) — quando hai le credenziali.

---

## 7. Decisioni prese (2026-10-11)

1. **Nessuna migrazione dati**: `personal_watchlist` parte **vuota**.
2. **Ordine di visione**: dentro la catena ci vanno **anche film/OVA/special**, ordinati per **data di uscita** (`aired_from`).
3. **"Consiglia a tutti"**: **una sola** voce nel feed attività del gruppo (`activities`, tipo `watchlist_added`/nuovo tipo) — **nessuna notifica personale** a raffica. La notifica personale arriva solo per **"Consiglia a persona"**.
4. **Firebase**: lo crei tu nella tua console Google; io ti passo i passaggi esatti e poi integro il push.

---

## 8. Guida Firebase (per te, quando vuoi attivare il push)

1. Crea un progetto su https://console.firebase.google.com (es. `animerank`).
2. Aggiungi app **Android** con package `applicationId` del progetto (`client/android/app/build.gradle`).
3. Scarica **`google-services.json`** e mettilo in `client/android/app/`.
4. In Firebase → **Impostazioni progetto → Account di servizio → Genera nuova chiave privata**: mi dai il JSON (va nel segreto Supabase per l'Edge Function `send-push`).
5. In Firebase → **Cloud Messaging**: è già attivo col progetto; l'Edge Function userà FCM HTTP v1 con la service account.
Poi faccio io: plugin Gradle, `device_tokens`, Edge Function, client `firebase_messaging`.
