# Web PWA — cosa è stato fatto (riepilogo tecnico)

Riepilogo delle modifiche per portare AnimeRank su iPhone come **PWA** (app web
installabile), senza Apple Developer Program. La guida per l'utente è in
`GUIDA_PWA_IPHONE.md`; qui c'è il "cosa" tecnico, per chi mette mano al codice.

---

## 1. Perché è compilabile su web (e cosa lo bloccava)

Il progetto non aveva il web abilitato. Attivato con:

```powershell
cd client
flutter create --platforms web .
```

La compilazione è fallita subito due volte, per due motivi distinti:

### a) `cronet_http` → `jni` → `dart:ffi` (non esiste sul web)

Catena:

```
main.dart → episodes_repository → animesaturn/animeunity_extractor
          → chromium_http.dart → cronet_http → jni → dart:ffi  ❌
```

**Fix:** import condizionale. Su web si carica uno stub.

- Nuovo file: `client/lib/features/episodes/data/chromium_http_stub.dart`
  (stessa interfaccia, `supported => false`).
- In `animeunity_extractor.dart` e `animesaturn_extractor.dart`:

  ```dart
  import 'chromium_http.dart' if (dart.library.html) 'chromium_http_stub.dart';
  ```

  La condizione è `dart.library.html` (e **non** `dart.library.io`): sul web
  Flutter fornisce comunque uno stub di `dart:io`, quindi `dart.library.io`
  sarebbe risultato vero anche nel browser.

### b) `--wasm-dry-run` rumoroso

Non era un errore bloccante, ma la build di default tentava anche la
compilazione Wasm "a vuoto" e stampava un mucchio di warning. Si compila con
`--no-wasm-dry-run` (resta JS/dart2js, che è quello che serve).

---

## 2. Il service worker: il punto delicato

Flutter **deprecato** il proprio service worker: il file generato
(`flutter_service_worker.js`) non fa che **disiscriversi** e ricaricare le
pagine. Registrarlo insieme al nostro `sw.js` avrebbe causato un conflitto,
perché due service worker allo stesso scope sono **lo stesso** worker: l'ultimo
registrato vince, e quello di Flutter avrebbe finito per cancellare anche il
nostro (`self.registration.unregister()`).

**Fix:** si avvia Flutter con un bootstrap personalizzato che **non** registra il
service worker di Flutter.

- Nuovo file: `client/web/flutter_bootstrap.js`

  ```js
  {{flutter_js}}
  {{flutter_build_config}}

  _flutter.loader.load();   // niente serviceWorkerSettings
  ```

Il service worker lo registra `client/web/index.html` (registra `sw.js`).

### Strategia di cache di `client/web/sw.js`

| Cosa | Strategia | Perché |
|---|---|---|
| Apertura pagina (`mode === 'navigate'`) | network-first → cache → `index.html` in cache | l'aggiornamento si vede subito, e offline funziona |
| `main.dart.js`, `flutter_bootstrap.js`, `flutter.js`, `.json`, `.bin` | network-first | **devono** aggiornarsi a ogni versione |
| font, icone, `canvaskit/`, immagini | cache-first | non cambiano mai: partire istantaneo |

`VERSION` (segnaposto `__BUILD_NUMBER__`) cambia a ogni deploy e rinomina le
cache, così le vecchie spariscono in `activate`. Anche se il segnaposto non
fosse sostituito, il network-first garantisce comunque l'aggiornamento.

### Avviso "nuova versione"

`index.html` ascolta `registration.updatefound`; quando c'è un worker nuovo
pronto e la pagina è già controllata, mostra la barra **Aggiorna**. Il pulsante
manda `SKIP_WAITING`; `controllerchange` ricarica una volta sola.

---

## 3. Guardie web nel codice Dart

Senza queste, l'app sul browser avrebbe generato errori all'avvio (non
bloccanti, ma sporchi) o sarebbe andata in eccezione su `Platform`.

- `client/lib/features/update/data/update_background_task.dart`:
  `if (kIsWeb || !Platform.isAndroid)` — `kIsWeb` **prima**, perché sul web
  `Platform` non esiste e leggerlo solleverebbe.
- `client/lib/main.dart`, `_bootstrapPush()`:
  `if (kIsWeb) return const UnsupportedPushMessaging();` — Firebase sul web non è
  configurato (servirebbe un'app web + chiave VAPID), quindi non lo si tenta
  nemmeno. Aggiunto `import 'package:flutter/foundation.dart';` per `kIsWeb`.
- `client/lib/features/update/presentation/app_update_controller.dart`: già
  web-safe (`!kIsWeb && defaultTargetPlatform == TargetPlatform.android`).

Verifica: la home parte, Hive apre la cache, nessuna eccezione; l'unico messaggio
in console era Firebase, ora evitato del tutto.

---

## 4. Deploy gratuito

- **Primario — GitHub Pages** (`.github/workflows/deploy-web-pwa.yml`):
  compila con `subosito/flutter-action@v2` (versione 3.47.5, come Android/iOS),
  passa `--base-href "/<nome-repo>/"`, sostituisce `__BUILD_NUMBER__` nel
  service worker e pubblica. Serve solo attivare *Settings → Pages → Source:
  GitHub Actions*. Gratis perché il repo è pubblico.
- **Alternativa — Netlify** (`netlify.toml`): comando che installa Flutter da
  sé (Netlify non ce l'ha), rimpiazza la versione, header di cache corretti.

Il routing dell'app è **a hash** (`/#/...`, non c'è `usePathUrlStrategy`), quindi
non serve nessun fallback SPA lato server: è il motivo per cui non ci sono
`redirects`.

---

## 5. Pulizie

- Rimosso `client/test/widget_test.dart`: era lo stub generato da `flutter create`
  che cercava `MyApp` (inesistente) e avrebbe **rotto `flutter test`**.
- Ripristinato `client/.metadata`: `flutter create --platforms web .` aveva
  **cancellato** le voci `android`, `ios`, `windows`, lasciando solo `web`.
  Rimesse tutte (con `web` in più).
- Ripristinato `client/pubspec.lock`: era stato riscritto con aggiornamenti di
  versione non voluti. `flutter pub get` con il lock originale è stabile (non lo
  riscrive), quindi si tiene l'originale.

---

## 6. Cosa resta aperto

1. **Video**: `media_kit` ha un player web (`html <video>`), quindi la
   riproduzione parte; ma le fonti che richiedono l'estrazione sul dispositivo
   (AnimeUnity, dietro Cloudflare) non si risolvono nel browser, e alcune
   potrebbero fallire per CORS/Referer. Le fonti risolte dal server funzionano.
2. **Push di sistema sul web**: spenti di proposito. Per accenderli servono
   un'app Web su Firebase + chiave VAPID (§8 di `GUIDA_PWA_IPHONE.md`).
3. **Prima build in CI**: da provare (non è stata eseguita qui). Il workflow usa
   la stessa versione di Flutter e le stesse `--dart-define` della build locale
   che è andata a buon fine.
