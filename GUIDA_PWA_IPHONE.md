# AnimeRank su iPhone **gratis** — la via PWA

Questa è la strada per avere AnimeRank su iPhone **senza Apple Developer Program**
(quindi **senza i 99 $/anno**). L'app Flutter viene compilata anche per il **Web** e
installata sull'iPhone come **PWA** ("app web installabile"): dalla schermata Home
si apre a tutto schermo, con la sua icona, come una app normale.

> In una riga: **stesso codice, stessa app, stessa grafica — ma servita da un sito**.
> Niente App Store, niente TestFlight, niente Mac, niente abbonamento.

---

## 1. Perché funziona e cosa cambia

Flutter compila lo stesso progetto anche per il browser. Il browser di iPhone
(Safari) sa installare un sito come app: si chiama PWA. Da iOS 16.4 una PWA
installata riceve anche le **notifiche push**, quando le configureremo.

Quello che cambia rispetto all'app Android:

| Funzione | Android (APK) | PWA su iPhone |
|---|---|---|
| Login, profilo, gruppi | ✅ | ✅ |
| Catalogo, ricerca, scheda anime | ✅ | ✅ |
| Classifiche, duelli, tornei | ✅ | ✅ |
| Watchlist, commenti, notifiche in-app | ✅ | ✅ |
| Grafica e tema | ✅ | ✅ |
| Player video | ✅ | ⚠️ **parziale** (vedi §7) |
| Sorgenti che richiedono l'estrazione sul telefono | ✅ | ❌ |
| Notifiche push | ✅ | ⚠️ da configurare (vedi §8) |
| Aggiornamento | APK scaricato | ✅ automatico (vedi §6) |
| Costo | gratis | **gratis** |

---

## 2. Com'è fatta la cartella `web/`

Quando Flutter compila per il Web usa i file dentro `client/web/`. Quelli che
abbiamo scritto o adattato noi:

| File | A cosa serve |
|---|---|
| `client/web/index.html` | La "pagina" dell'app: meta tag iOS, splash, avviso "nuova versione", registrazione del service worker. |
| `client/web/manifest.json` | Descrive l'app al telefono: nome, colori, icone. Serve per l'installazione. |
| `client/web/flutter_bootstrap.js` | Avvia Flutter **senza** registrare il service worker di Flutter (che è deprecato e farebbe a pugni col nostro). |
| `client/web/sw.js` | Il **service worker**: mette in cache l'app (funziona offline) e avvisa quando c'è una versione nuova. |
| `client/web/icons/` | Icone, compresa `apple-touch-icon.png` per la Home di iOS. |

---

## 3. Provarla sul computer (2 minuti)

Dalla cartella `client/`:

```powershell
flutter build web --release --no-tree-shake-icons --no-wasm-dry-run `
  --dart-define=SUPABASE_URL=https://sjbstiexythmapxmrfyp.supabase.co `
  --dart-define=SUPABASE_ANON_KEY=sb_publishable_JqBGHeAUT068w6-Ex1L8OQ_f6OpCSMc `
  --dart-define=ANIMERANK_RELAY=https://animerank-relay.titanoeren171.workers.dev
```

Poi servi la cartella `build/web` (il service worker funziona solo su
`localhost` o `https`):

```powershell
cd build\web
python -m http.server 8080
```

Apri <http://localhost:8080> nel browser. Dovresti vedere l'app. Nella console
del browser (F12) compaiono un paio di righe `[sw]` del service worker: è
normale.

C'è anche uno script che fa tutto in un colpo: `deploy_pwa.ps1` nella radice del
progetto.

> **Nota:** `--dart-define=ANIMERANK_RELAY=...` serve solo all'app Android per
> aggirare il blocco di alcuni operatori mobili. Sul web il browser ci pensa da
> solo, quindi quel valore non ha effetto lì: si può omettere.

---

## 4. Pubblicarla **gratis** (GitHub Pages)

È già tutto pronto: c'è un workflow GitHub Actions che compila e pubblica da
solo a ogni push. Ti resta **un solo passaggio da fare a mano**:

1. Sul repo GitHub: **Settings → Pages**.
2. In **Build and deployment → Source** scegli **GitHub Actions**.
3. Fatto. Da ora, a ogni push che tocca `client/`, GitHub compila la PWA e la
   mette online; il workflow si può anche lanciare a mano da **Actions → Web PWA
   (GitHub Pages) → Run workflow**.

L'indirizzo sarà:

```
https://pinguino0.github.io/anime-ranking-app/
```

(il workflow ricava da solo il nome giusto dalla repo, quindi non va scritto a
mano da nessuna parte).

Il workflow è `.github/workflows/deploy-web-pwa.yml`.

**Requisito:** GitHub Pages gratuito funziona sui repository **pubblici**. Questo
repo lo è già. Se un giorno lo rendi privato, Pages richiede GitHub Pro: in quel
caso usa Netlify (§5).

### Alternativa: Netlify (indirizzo tuo, senza sottocartella)

Se preferisci un indirizzo tipo `animerank.netlify.app` (o un dominio tuo),
c'è `netlify.toml` già configurato. Serve creare un account Netlify, collegare
il repo e impostare 3 variabili d'ambiente (sono elencate dentro `netlify.toml`).
Il comando di build installa Flutter da solo, perché Netlify non ce l'ha.

---

## 5. Installarla sull'iPhone

1. Apri l'indirizzo della PWA in **Safari** (non Chrome: su iPhone l'installazione
   la fa solo Safari).
2. Tocca il pulsante **Condividi** (il quadrato con la freccia in su).
3. Scorri e tocca **"Aggiungi a Home"**.
4. Conferma. Sulla schermata Home compare l'icona **AnimeRank**.

Da quel momento si apre **a tutto schermo**, senza barra di Safari, come una app.
È il momento giusto per fare login.

> Le notifiche push su iPhone funzionano **solo** se l'app è installata così (non
> da una scheda normale di Safari).

---

## 6. Come funzionano gli aggiornamenti

Su Android l'aggiornamento è un APK da installare. Sul web **non serve fare
niente**: il service worker si accorge che è uscita una versione nuova e, quando
apri l'app, se ne è disponibile una, compare in basso un avviso:

> *"È pronta una nuova versione di AnimeRank."* — pulsante **Aggiorna**

Un tocco e l'app si ricarica con la versione nuova. È la stessa idea del gate
Android, ma senza download.

Chi non tocca l'avviso riceve comunque la versione aggiornata **alla successiva
apertura**: il controllo della pagina e del codice (`main.dart.js`) è
"network-first", quindi quando c'è rete arriva sempre la versione più recente.

---

## 7. Il player video: cosa funziona e cosa no

Buona notizia: `media_kit` **ha un'implementazione per il web** e usa il lettore
video nativo del browser. Quindi il player parte.

Il limite è nella **risoluzione delle fonti**, non nel player:

- Alcune fonti le risolve il **server** (Edge Function `resolve-source`) e
  restituiscono un link diretto: queste possono funzionare nel browser.
- Altre fonti (es. **AnimeUnity**) richiedono l'**estrazione sul dispositivo**,
  perché stanno dietro Cloudflare e il datacenter non ci arriva. Sul telefono lo
  fa il motore di rete di Chromium; nel browser questo passaggio **non esiste**
  (il codice è disattivato lì) e la fonte non si risolve.

In pratica, sulla PWA: **catalogo, classifiche, watchlist, gruppi e social
funzionano sempre; il video dipende dalla fonte.** Dove non si risolve, il player
mostra un errore e non si rompe niente.

Un secondo limite possibile è il **CORS/Referer**: il lettore del browser non può
mandare header personalizzati come fa mpv sul telefono, quindi alcune fonti
potrebbero rifiutare la riproduzione anche se risolte.

---

## 8. Notifiche push sul web (da configurare in futuro)

Oggi sulla PWA le **notifiche interne all'app funzionano** (la campanella con il
centro notifiche). I **push di sistema** (quelli che compaiono a schermo bloccato)
sono **spenti**: il codice esce subito sul web per non generare errori.

Per accenderli servono, una volta sola, nella console Firebase (progetto
`animerank-4b0e2`):

1. **Aggiungere un'app Web** al progetto Firebase → dà un blocco di
   configurazione (`apiKey`, `appId`, `messagingSenderId`, `projectId`).
2. **Chiave VAPID**: Impostazioni progetto → **Cloud Messaging** → *Web Push
   certificates* → *Generate key pair*.
3. Incollare questi valori nelle `--dart-define` della build web e togliere il
   blocco `if (kIsWeb) return ...` in `client/lib/main.dart` (`_bootstrapPush`),
   sostituendolo con l'inizializzazione con le opzioni web.

È un lavoro a parte, fattibile, ma non necessario per usare l'app. Finché non si
fa, resta tutto com'è: nessuna notifica di sistema, ma nessun errore.

---

## 9. File toccati per la versione web

Nuovi:

- `client/web/index.html`, `client/web/manifest.json`, `client/web/sw.js`,
  `client/web/flutter_bootstrap.js`, `client/web/icons/apple-touch-icon.png`
- `.github/workflows/deploy-web-pwa.yml` (deploy automatico su Pages)
- `netlify.toml` (alternativa di hosting)
- `deploy_pwa.ps1` (script "compila e prepara" in locale)
- questa guida

Adattati perché il web non compili/crashasse:

- `client/lib/features/episodes/data/chromium_http_stub.dart` (nuovo): versione
  "vuota" di `ChromiumHttp` per il browser.
- `client/lib/features/episodes/data/animeunity_extractor.dart` e
  `animesaturn_extractor.dart`: import **condizionale** di `chromium_http` (sul
  web carica lo stub, così `cronet_http`/`dart:ffi` non entrano nella build).
- `client/lib/features/update/data/update_background_task.dart`: esce subito se
  `kIsWeb`, prima di toccare `Platform` (che sul browser non esiste).
- `client/lib/main.dart`: sulla web non inizializza Firebase (niente errori in
  console a ogni avvio).

La cartella `client/web/` è stata creata con `flutter create --platforms web .`
(prima il progetto non aveva il web abilitato).

---

## 10. Comandi rapidi

```powershell
# Compilare la PWA con le credenziali giuste (dalla cartella client/)
flutter build web --release --no-tree-shake-icons --no-wasm-dry-run `
  --dart-define=SUPABASE_URL=https://sjbstiexythmapxmrfyp.supabase.co `
  --dart-define=SUPABASE_ANON_KEY=sb_publishable_JqBGHeAUT068w6-Ex1L8OQ_f6OpCSMc

# Provarla in locale
cd build\web ; python -m http.server 8080     # -> http://localhost:8080

# Pubblicare (automatico): basta un push su main/master.
# Solo la prima volta serve impostare Pages -> Source: GitHub Actions.
```

---

## Riepilogo

- **Obiettivo raggiunto:** AnimeRank gira su iPhone **a costo zero**, senza Apple
  Developer e senza Mac.
- **Cosa manca da fare a te:** (1) attivare Pages come sopra; (2) aprire
  l'indirizzo su Safari e "Aggiungi a Home".
- **Limite principale:** il video dipende dalla fonte; il player del browser non
  sa fare tutto quello che fa mpv sul telefono.
- **Facoltativo, più avanti:** abilitare i push web (serve un'app Web su Firebase
  + chiave VAPID).
