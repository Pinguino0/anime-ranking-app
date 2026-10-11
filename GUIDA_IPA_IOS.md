# Guida — Animerank su iPhone (IPA + TestFlight)

Come si mette Animerank su iPhone. Servono due servizi, entrambi gratis per il
tuo volume:

- **Codemagic** — compila su un Mac in cloud (500 minuti macOS al mese gratis).
- **Apple** — firma l'app e la distribuisce via TestFlight (richiede l'Apple
  Developer Program, 99 $/anno).

Da Windows non si puo' fare altrimenti: Xcode esiste solo su macOS.

---

## Prima di tutto: cosa NON fa l'iPhone

Sono due cose che valgono la pena di sapere subito, perche' spiegano perche' non
e' un copia-incolla dell'Android:

1. **L'app non si aggiorna da sola.** Apple vieta l'auto-aggiornamento. Gli
   aggiornamenti arrivano da TestFlight, non dal meccanismo `app_releases`.
   Su iPhone il gate "c'e' da aggiornare" e' spento di proposito.
2. **Il push va configurato a parte** (Fase 4). Senza, l'app funziona
   benissimo, ma non riceve notifiche.

---

## Fase A — nel repo (fatto da me)

- Icona iOS generata da `assets/icon/app_icon.png`
  (`dart run flutter_launcher_icons`): stessa icona di Android, con il canale
  alpha rimosso come pretende Apple.
- `codemagic.yaml` alla radice del repo: workflow `ios-testflight`.
- Questa guida.

**In sospeso (ve lo dico io quando farle):** push iOS (Fase 4) e messa a
punto delle fonti se una fosse `http` (ora sono tutte https).

---

## Fase B — Apple Developer / App Store Connect (da fare a te)

Serve una cosa sola: l'account Apple Developer Program attivo. Poi tre cose
dentro i portali Apple.

### B1. Registra il Bundle ID
1. Vai su <https://developer.apple.com/account/resources/identifiers/list>.
- **Certificates, Identifiers & Profiles → Identifiers → +**.
- Scegli **App IDs** → **App** → Continue.
- **Bundle ID**: `com.animerank.animerank` (deve essere identico a questo).
- Description: `Animerank`.
- Capabilities: per ora **niente**. Solo in Fase 4 spunterai
  **Push Notifications**.
- **Register**.

> L'ID e' "explicit", non un wildcard: serve per il push e per il deep link.

## Fase B (continua)

2. **Crea l'app in App Store Connect**
   - Vai su <https://appstoreconnect.apple.com> → **My Apps** → **+** → **New App**.
   - Platform: **iOS** · Name: **Animerank** · Primary Language: **Italian**
   - Bundle ID: scegli **com.animerank.animerank**
   - SKU: `animerank` (un codice tuo, qualsiasi)
   - User Access: Full Access → **Create**.
   - Serve solo come contenitore: non pubblichi sull'App Store, usi TestFlight.

3. **Crea la chiave API per Codemagic** (e' quella che firma le build)
   - App Store Connect → **Users and Access** → **Integrations** (o "Keys") →
     **App Store Connect API** → **Team Keys** → **+**.
   - Name: **animerank-asc** · Access/Role: **App Manager** (o Admin).
   - **Generate**, poi **Download API Key**: e' un file `.p8`, si scarica **una
     volta sola**.
   - Annota **Issuer ID** (sopra la tabella) e **Key ID** (della chiave).

---

## Fase B-bis — Chiave APNs (solo per il push, Fase 4)

Serve dopo, per far arrivare le notifiche su iPhone. Puoi gia' crearla ora:

- <https://developer.apple.com/account/resources/authkeys/list> → **+**
  - Name: **animerank-apns** · spunta **Apple Push Notifications service (APNs)**
  - **Continue** → **Register** → **Download** (file `.p8`, una volta sola).
  - Annota il **Key ID** e il **Team ID** (in alto a destra, "Membership").

---

## Fase C — Codemagic (tu, con la mia configurazione)

Il `codemagic.yaml` e' gia' pronto. Tu devi solo collegare l'account:

1. Vai su <https://codemagic.io> → accedi con **GitHub**.
2. **Add application** → scegli il repo **`Pinguino0/anime-ranking-app`** →
   Flutter. (Codemagic legge da solo il `codemagic.yaml`.)
3. **Team settings → Integrations → Developer Portal → Connect**:
   - Name: **animerank-asc** (deve combaciare col file, non cambiarlo)
   - **Issuer ID** e **Key ID** annotati prima
   - carica il file `.p8` scaricato da App Store Connect → **Save**
4. Torna sull'app → **Start new build** → workflow **iOS TestFlight**.
5. La prima build: Codemagic crea da solo certificato e profilo di
   distribuzione, compila e carica su TestFlight. Tempo: ~15-20 minuti.

Se qualcosa non torna, il log dice esattamente cosa: incollamelo e lo sistemo.

---

## Fase D — Push su iPhone (io, dopo la prima build)

Serve ad avere le notifiche come su Android. Ordine:

1. **Tu**, nella console Firebase del progetto `animerank-4b0e2`:
   - **Add app** → **iOS** → bundle id **com.animerank.animerank** → scarica
     **`GoogleService-Info.plist`** e passamelo.
   - **Project settings → Cloud Messaging → Apple app configuration** → carica
     la chiave **APNs** (`animerank-apns.p8`) + **Key ID** + **Team ID**.
2. **Io** nel repo:
   - metto `GoogleService-Info.plist` in `client/ios/Runner/` e lo collego al
     progetto Xcode;
   - aggiungo `Runner.entitlements` (`aps-environment`) e in `Info.plist`
     `UIBackgroundModes: remote-notification`;
   - abilito la capability **Push Notifications** sull'App ID (o la lascio
     gestire a Codemagic).
3. Rilanci la build: da li' in poi i consigli e gli altri push arrivano anche
   su iPhone.

> Dettaglio Android/iOS: il push "aggiornamento app" verra' inviato **solo ai
> telefoni Android** (su iPhone non serve, aggiorni da TestFlight). Lo sistemo
> io in `send-push`.

---

## Fase E — Test su iPhone (tu)

Installa **TestFlight** e prova tutto quello che c'e' su Android:

- [ ] Registrazione / login (e conferma email col deep link)
- [ ] Classifica, ricerca, scheda anime
- [ ] Episodi + **player video** (prova una fonte HLS e una mp4)
- [ ] Watchlist personale e di gruppo
- [ ] **Consiglia** (a tutti / a persona)
- [ ] **Da dove iniziare** (ordine di visione)
- [ ] Profilo / impostazioni
- [ ] Permesso notifiche e arrivo dei push (dopo la Fase D)

Il punto piu' delicato e' il **player** (`media_kit`/mpv): e' l'unica parte che
potrebbe richiedere ritocchi. Se un video non parte, dimmi sorgente e messaggio
d'errore.

### Chi puo' installare la build

- **Tester interni** (fino a 100): utenti aggiunti in App Store Connect → launch
  immediato, nessuna revisione. Comodo per te.
- **Tester esterni** (fino a 10.000): link pubblico, nessun account richiesto,
  ma la **prima** build passa da una revisione Apple (1-2 giorni).

Ogni build TestFlight **scade dopo 90 giorni**: si carica quella nuova e si
reinstalla dall'app TestFlight.
