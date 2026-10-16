# Guida — Animerank su iPhone con TrollStore (gratis, senza Apple Developer)

Questa e' la strada **gratuita**: niente Apple Developer Program (99 $/anno),
niente TestFlight, niente scadenze. L'app resta installata per sempre, come una
app normale.

Il prezzo da pagare e' uno solo: **TrollStore funziona solo su certe versioni di
iOS**. Se il telefono e' troppo nuovo, si ripiega sulla Parte 5.

L'IPA lo compila GitHub Actions su un Mac in cloud: per i repo pubblici i minuti
macOS sono **gratuiti e illimitati**. Non serve alcun Mac.

---

## Parte 1 — Controlla la versione di iOS (fondamentale)

Sul telefono: **Impostazioni → Generali → Info → Versione del software**.

| Versione iOS | TrollStore | Cosa fare |
|---|---|---|
| **14.0 – 15.1** | Si | Parte 2, metodo "TrollInstallerX" |
| **15.2 – 16.6.1** (e 16.7 RC) | Si | Parte 2, metodo "TrollRestore" (col PC) |
| **17.0** | Solo su iPhone XS/XR e piu' vecchi (A11/A12) | Prova "TrollRestore" |
| **17.1 o superiore / 18.x / 26.x** | **No** | Vai alla Parte 5 |
| **iPhone 14/15/16 con iOS recente** | Quasi sempre **No** | Vai alla Parte 5 |

> Regola pratica: se il telefono ha iOS 17.1 o superiore, **TrollStore non e'
> possibile** (Apple ha corretto il bug). Su un iPhone 14/15/16 comprato nuovo
> la probabilita' e' alta che sia cosi'.

Il minimo richiesto dall'app: **iOS 15.0** (l'IPA e' compilato per iOS 15+).
Quindi va bene tutto da iOS 15 in su.

---

## Parte 2 — Installa TrollStore

### Metodo A — TrollRestore (iOS 15.2 – 16.6.1, e 17.0) — il piu' comodo

Serve **un PC Windows** (ce l'hai) e un cavo. Nessun Apple ID, nessun sideload.

1. Sul PC installa **iTunes** (dalla pagina Apple, NON dal Microsoft Store) e
   **Apple Devices** — servono i driver per parlare col telefono.
2. Scarica **TrollRestore** da <https://github.com/JJTech0130/TrollRestore>
   (sezione *Releases*, file `.exe`).
3. Collega l'iPhone al PC, **sbloccalo** e rispondi **Fidati / Trust** al
   messaggio "Fidati di questo computer".
4. Avvia `TrollRestore.exe`, scegli l'app **"Tips"** (Consigli) come bersaglio e
   premi Invio. Scollega e riavvia il telefono quando richiesto.
5. Se non lo trovi: sul telefono apri l'app **Suggerimenti/Consigli** → nella
   barra in alto del menu c'e' **"Install TrollStore"** → tocca → **Install**.
6. TrollStore compare in Home. Fine: e' permanente, non scade.

### Metodo B — TrollHelperOTA (iOS 14.0 – 15.1) — senza PC

1. Dal **browser del telefono** (Safari) vai su
   <https://api.jailbreaks.app/troll>.
2. Tocca **Install TrollStore** e conferma. (Safari dira' che l'app non e'
   attendibile: va bene.)
3. Apri TrollStore da Home e tocca **Install TrollHelper** se lo chiede.

### Metodo C — TrollInstallerX (iOS 14.0 – 16.6.1) — alternativa

Va bene un po' su tutte le versioni supportate (14.0–15.1.1 su tutti i
dispositivi; 15.2–16.6.1 su A9 e successivi). Si installa col PC una volta sola
(via Sideloadly, con un Apple ID gratuito) e poi installa TrollStore da li':

1. Scarica **TrollInstallerX** da <https://github.com/alfiecg24/TrollInstallerX>
   (Releases, file `.ipa`).
2. Installalo col PC con **Sideloadly** (<https://sideloadly.io>) usando un
   Apple ID gratuito.
3. Apri TrollInstallerX sul telefono → **Install TrollStore**.
4. Da qui in poi TrollStore e' installato.

---

## Parte 3 — Prendi l'IPA

L'IPA e' l'artefatto della build CI. Due modi:

- **Dalla CI**: GitHub → repo `Pinguino0/anime-ranking-app` → **Actions** →
  workflow **"iOS IPA"** → ultima run verde → in fondo, **Artifacts** →
  **Animerank-ipa**. Si scarica un `.zip` che contiene `Animerank.ipa`.
  (Serve il tuo account GitHub: lo scarichi tu e lo passi al telefono.)
- **Ricompilarlo**: **Actions → iOS IPA → Run workflow** (o push di un tag
  `v*`). Tempo: ~10-15 minuti.

L'artefatto resta disponibile **90 giorni**. Se e' scaduto, si ricompila in un
attimo.

### Come trasferire il file sul telefono

Scegli quello che ti e' piu' comodo:
- **Cavo** dal PC (l'iPhone appare in Esplora file come fotocamera: incolla l'IPA
  in una cartella che vedi da **File**).
- **AirDrop** se il file e' su un Mac.
- **Cloud** (iCloud Drive, Google Drive, Dropbox): carica l'IPA dal PC, aprilo
  dall'app cloud sul telefono, **Salva in File**.
- **Link diretto**: da Safari, scarica l'IPA in **File → Download**.

---

## Parte 4 — Installa l'app con TrollStore

1. Sul telefono apri **File**, trova **`Animerank.ipa`** e toccalo.
2. Se non si apre da solo in TrollStore: tieni premuto / tocca **Condividi** →
   scegli **TrollStore**.
3. In alternativa: apri **TrollStore** → icona **+** in alto a destra → scegli
   l'IPA.
4. TrollStore installa: l'icona **Animerank** compare in Home. Aprila.

**Non scade, non serve reinstallare.** Se in futuro aggiorno l'app, scarichi il
nuovo IPA e lo installi sopra: i dati restano.

### Cosa aspettarsi al primo avvio

- **Video**: il player e' mpv (come su Android). Su WiFi va liscio; sui dati
  mobili entra in gioco il trucco DoH, come sull'app Android.
- **Notifiche push**: su questa build **sono spente** (manca il file
  `GoogleService-Info.plist` di Apple, che richiede un account Apple). L'app
  funziona lo stesso; le notifiche interne all'app ci sono. Se in futuro vuoi il
  push, si aggiunge il file e si ricompila (vedi `GUIDA_IPA_IOS.md`, Fase D).
- **Aggiornamenti**: su iOS non c'e' auto-aggiornamento (lo vieta Apple). Si
  reinstalla l'IPA nuovo sopra il vecchio.

---

## Parte 5 — Se l'iOS e' troppo nuovo (niente TrollStore)

Da **iOS 17.1 in su** TrollStore non esiste. Le alternative gratuite:

| Metodo | Costo | PC | Scadenza |
|---|---|---|---|
| **SideStore** | gratis | solo la prima volta | **7 giorni**, poi si rinnova da solo in automatico (se hai un server/PC acceso) |
| **AltStore** | gratis | serve un PC acceso che faccia da AltServer | 7 giorni, si rinnova |
| **Sideloadly** | gratis | PC | 7 giorni (poi ricolleghi il cavo) |
| **Servizi UDID** (terzi) | ~10-25 €/anno | no | 1 anno |
| **Apple Developer + TestFlight** | 99 $/anno | no | 90 giorni per build |

Per la maggior parte delle persone la scelta e': se il telefono e' su **17.1+**,
o si accetta il **rifiuto a 7 giorni** (SideStore/Sideloadly con un Apple ID
gratuito), o si guarda altrove (`GUIDA_IPA_IOS.md` per TestFlight).

> Nota: l'IPA di questa guida va bene sia per TrollStore **sia** per SideStore /
> AltStore / Sideloadly: e' lo stesso file, cambia solo chi lo firma.

---

## Riepilogo in una riga

1. Controlla iOS. Se **≤ 16.6.1** (o 17.0) → TrollStore, gratis e permanente.
2. Installa TrollStore (TrollRestore col PC).
3. Scarica `Animerank.ipa` dalla run **iOS IPA**.
4. Passalo al telefono e aprilo in TrollStore. Fatto.
