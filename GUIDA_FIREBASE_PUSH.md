# Guida — Attivare le notifiche push (FCM)

Questa è la parte che devi fare **tu** nella console Google. Io preparo tutto il
resto (database, Edge Function, client) e appena mi dai i file lo collego.

- `applicationId` Android del progetto: **`com.animerank.animerank`**
- Progetto: `animerank`
- Piano Firebase: **Spark (gratis)** — Cloud Messaging è incluso.

---

## Passi nella console Firebase

### 1. Crea il progetto
1. Vai su <https://console.firebase.google.com>.
2. **Crea progetto** → nome `animerank`.
3. Google Analytics: **disattivalo** (non ci serve) → **Crea progetto**.

### 2. Aggiungi l'app Android
1. Nella pagina del progetto, clicca l'icona **Android** (Aggiungi app).
2. **Nome pacchetto Android** (deve essere identico, copia-incolla):
   ```
   com.animerank.animerank
   ```
3. Soprannome app: `animerank Android` (facoltativo).
4. SHA-1: **lascialo vuoto** — serve solo per l'accesso Google, non per il push.
5. **Registra app**.

### 3. Scarica `google-services.json`
1. Dopo la registrazione, scarica il file **`google-services.json`**.
2. Mettilo esattamente qui (sostituisci/crea il file):
   ```
   client/android/app/google-services.json
   ```
3. Questo file **non è un segreto grave** (contiene chiavi pubbliche del
   progetto), quindi può stare nel repo. Il file del punto 4 invece **è
   segreto**: non committarlo.

### 4. Service account per l'Edge Function (invio dei push)
1. Sempre nel progetto: icona **ingranaggio** in alto a sinistra → **Impostazioni progetto**.
2. Scheda **Account di servizio**.
3. **Genera nuova chiave privata** → **Genera chiave** → scarica il JSON
   (nome tipo `animerank-firebase-adminsdk-xxxxx.json`).
4. Questo JSON è il segreto che l'Edge Function `send-push` userà per parlare con
   FCM. **Non metterlo nel repo.** Me lo puoi:
   - dare direttamente (lo carico io come secret Supabase), **oppure**
   - caricare tu come `FIREBASE_SERVICE_ACCOUNT` (te lo spiego dopo).

### 5. (Facoltativo) Attiva la API FCM HTTP v1
Di solito è già attiva. Se all'invio riceverai un errore `PERMISSION_DENIED` o
`API not enabled`, vai su
<https://console.cloud.google.com/apis/library/fcm.googleapis.com> (stesso
progetto) e premi **Abilita**.

---

## Stato (aggiornato)

Il **push è completo: server e client**. Non devi fare più niente in Firebase.

### Fatto

- **DB** — `device_tokens` (RLS "solo il proprietario") + le RPC
  `register_device_token` / `remove_device_token` (riassegnano il token quando lo
  stesso telefono cambia account) + il trigger `notifications_push_webhook`, che
  chiama la funzione via `pg_net` con il segreto condiviso letto da **Vault**.
  Migrazioni `20261011170000_device_tokens.sql`, `20261011180000_push_webhook.sql`
  e `20261011190000_device_token_rpc.sql` **applicate**.
- **Edge Function `send-push`** — deployata, `health` risponde **`ok`**
  (`serviceAccount: true`, `webhookSecret: true`, progetto `animerank-4b0e2`).
  12 test Deno verdi.
- **Segreti caricati** — `FIREBASE_SERVICE_ACCOUNT` (dal tuo JSON) e
  `PUSH_WEBHOOK_SECRET`.
- **Collaudo end-to-end** — inserita una notifica di prova con un token finto:
  `net._http_response` ha risposto
  `200 {"sent":0,"failed":1,"removed":1,"project":"animerank-4b0e2"}`. Significa:
  trigger → autenticazione → FCM → pulizia token, tutto verificato. I dati di
  prova sono stati rimossi.
- **Client Flutter** — `firebase_core` + `firebase_messaging`; plugin Gradle
  `com.google.gms.google-services` 4.5.0; permesso Android 13
  (`POST_NOTIFICATIONS`) e canale di default nell'AndroidManifest; canale
  `animerank_default`; registrazione del token al login, rimozione al logout,
  riscrittura al rinnovo; tap sulla notifica → apre la watchlist del gruppo del
  consiglio; notifica mostrata anche con l'app aperta. **6 test Flutter nuovi**.
- **Avviso di aggiornamento via push** — pubblicando una riga in `app_releases`
  (dal SQL Editor, come sempre) il trigger `app_releases_notify_update` crea una
  notifica `app_update` per ogni profilo, e la catena dei push la consegna a chi
  ha le notifiche accese. La vecchia notifica locale (WorkManager +
  `flutter_local_notifications`) è stata rimossa: sul dispositivo resta solo la
  pulizia periodica degli APK. Migrazioni
  `20261011200000_app_update_notification_type.sql` e
  `20261011201000_app_update_push.sql` **applicate**.

### Cosa resta da fare a te

- **Installare una nuova APK** sul telefono. Con il client vecchio il telefono
  non ha il codice del push e non risulta tra i dispositivi: dopo l'installazione
  e il primo accesso, il suo token compare in `device_tokens` e i consigli
  arrivano.



---

## Cosa NON blocca il push

- iOS: si può aggiungere dopo (serve una chiave APNs da Apple). Per ora si fa
  Android, che è la piattaforma della release.
- Il *contenuto* delle notifiche è già scritto lato server: il trigger di
  `anime_recommendations` inserisce in `notifications` il testo
  *"<nome> ti ha consigliato di vedere: <anime>"*. L'Edge Function si limita a
  spedirlo.
