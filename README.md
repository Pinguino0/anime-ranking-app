<div align="center">

<img src="client/assets/icon/app_icon.png" width="132" alt="AnimeRank" />

# AnimeRank

**Il catalogo anime che tiene il conto. Con gli amici dentro.**

Scopri, segna cosa stai guardando, vota **episodio per episodio**
e guarda la classifica crescere insieme a quella dei tuoi amici.

[![Flutter](https://img.shields.io/badge/Flutter-3.47-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.13-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![Supabase](https://img.shields.io/badge/backend-Supabase-3ECF8E?logo=supabase&logoColor=white)](https://supabase.com)
[![Piattaforme](https://img.shields.io/badge/Android%20%C2%B7%20Windows%20%C2%B7%20iOS%20(in%20arrivo)-333?logo=android&logoColor=white)](#-piattaforme)
[![Tests](https://img.shields.io/badge/flutter%20test-603%20verdi-2ea44f)](#-qualit%C3%A0)

</div>

---

## ✨ Cos'è

Chi segue gli anime tiene quattro cose in quattro posti diversi: il catalogo su
un sito, il progresso a memoria, il voto in testa e le discussioni in una chat di
gruppo. **AnimeRank le mette in un solo posto**, senza provare a diventare
Netflix e senza fingere di essere uno streaming con licenza.

> Non è un servizio di streaming: se un episodio non ha una fonte, l'app lo dice
> e non finge. È il posto dove si **tiene conto** di quello che si guarda.

---

## 🎯 Cosa fa

| | Funzione | Descrizione |
|---|---|---|
| 📚 | **Catalogo** | Annuario stagionale, ricerca e schede complete (metadati da MyAnimeList via Jikan) |
| 📺 | **Player integrato** | Guardi dentro l'app e riprendi esattamente dal secondo in cui eri rimasto |
| ⭐ | **Voto per episodio** | Non solo «ti è piaciuto il titolo»: ogni episodio ha il suo voto (1–10) |
| 📝 | **Watchlist** | Personale (*Nella mia lista*) e di gruppo, con stati e progresso per titolo |
| 👥 | **Gruppi** | Watchlist condivisa, attività, gli anime che piacciono a tutti |
| 💬 | **Consiglia** | Manda un anime **a tutti** o **a una persona**: arriva come notifica |
| 🧭 | **Da dove iniziare** | Per le serie con più stagioni, l'ordine di visione consigliato |
| 🏆 | **Classifica** | Podio e punteggi dei membri, con statistiche animate |
| ⚔️ | **Duelli** | Confronti uno-contro-uno tra anime |
| 🥇 | **Tornei** | Tabelloni a eliminazione tra i titoli del gruppo |
| 🔔 | **Notifiche** | Push (anche ad app chiusa, max 3 al giorno per dispositivo) e centro attività |
| 🎖️ | **Achievements** | Obiettivi sbloccabili mentre guardi |
| 💬 | **Discussione** | Commenti e risposte per anime, dentro i gruppi, con spoiler |

---

## 📱 Piattaforme

| Piattaforma | Stato |
| :-- | :-- |
| **Android** | ✅ disponibile (APK) |
| **Windows** | ✅ disponibile (desktop) |
| **iOS / iPhone** | 🚧 in preparazione (build TestFlight) |

---

## 🧱 Com'è fatto

```text
Flutter (Dart 3.13 · Flutter 3.47)
  │   Riverpod · go_router · media_kit (mpv) · Hive · fl_chart
  │
  └──► Supabase
         ├── Postgres 17   → schema public, RPC (security definer), RLS
         ├── Auth          → registrazione, sessioni, reset password
         ├── Edge Functions
         │     ├── jikan-proxy      catalogo esterno (MyAnimeList/Jikan)
         │     ├── resolve-source   fonte canonica → URL effimero + header
         │     └── send-push        notifiche push (FCM HTTP v1)
         ├── Storage       → avatar e immagini
         └── pg_net + Vault → webhook che accende le push dal database

Scraper Node  →  alimenta il catalogo e le fonti degli episodi
```

**Le regole che tengono su**

- Il client non legge mai le tabelle sensibili: le **RPC** sono il confine e
  restituiscono già le join giuste.
- La scrittura di `episode_sources` e `providers` è riservata al `service_role`.
- Per riprodurre, il client manda **solo l'id della fonte**: è la Edge Function
  a rileggere l'URL e il provider dal database → niente proxy aperto.
- La risoluzione avviene **al playback e non viene mai salvata** (i token scadono).

---

## 🎬 La pipeline di riproduzione

```text
DB: episode_sources
  ├─ source_url      già riproducibile  ──────────────►  apri subito
  └─ canonical_url   da risolvere
         │
         ▼
   resolve-source  (POST { source_id })
         │  legge fonte + provider (service role)
         ▼
   adapter: mock | generic_api | native
         │  chiama il provider esterno
         ▼
   { resolved_url, headers, expires_at }   ← mai salvato
         │
         ▼
   media_kit (mpv)  →  Media(url, httpHeaders: headers)
```

Fallback automatico: risoluzione 8s, apertura 12s, 3 tentativi, poi si passa
alla fonte successiva. Link scaduto → nuova risoluzione, senza avvisi inutili.

---

## 🗂️ Struttura del progetto

```text
anime-ranking-app/
├── client/                 app Flutter (Android · Windows · iOS)
│   ├── lib/core/           design system, tema, router, widget condivisi
│   ├── lib/features/       catalogo, episodi, watchlist, gruppi, tornei…
│   └── test/               widget e unit test
├── supabase/
│   ├── migrations/         schema, RLS e RPC, una migrazione per feature
│   └── functions/          jikan-proxy · resolve-source · send-push
├── scraper/                script Node che popolano catalogo e fonti
├── codemagic.yaml          build iOS → TestFlight
└── *.md                    documentazione (vedi in fondo)
```

---

## 🚀 Provare e buildare

**Test e analisi**

```powershell
cd client
flutter analyze     # → "No issues found!"
flutter test        # → 603 test verdi
```

**Android (APK)**

```powershell
cd client
flutter build apk --release --target-platform android-arm,android-arm64 `
  --build-name 0.0.8 --build-number 8 `
  --dart-define=SUPABASE_URL=https://<project>.supabase.co `
  --dart-define=SUPABASE_ANON_KEY=<publishable-key>
```

**Windows (desktop)**

```powershell
cd client
flutter build windows --release `
  --dart-define=SUPABASE_URL=https://<project>.supabase.co `
  --dart-define=SUPABASE_ANON_KEY=<publishable-key>
```

> La chiave `SUPABASE_ANON_KEY` è una **chiave pubblicabile**: vive dentro l'app
> e non è un segreto. I dati sono protetti dalle Row Level Security policy, non
> dalla segretezza della chiave.

**iOS / TestFlight** — build su [Codemagic](https://codemagic.io) tramite
`codemagic.yaml` (workflow `ios-testflight`). Dettagli in `GUIDA_IPA_IOS.md`.

---

## 🧪 Qualità

| Cosa | Risultato |
| :-- | :-- |
| `flutter analyze` | ✅ No issues found |
| `flutter test` | ✅ 603 verdi |
| Edge Function `send-push` | ✅ 12 test Deno |
| Edge Function `resolve-source` | ✅ test Deno verdi |

Niente stack trace a schermo: l'utente vede «Riprova», i dettagli restano nei log.

---

## ⚖️ Nota

AnimeRank **non è un servizio di streaming** e non ospita contenuti protetti da
copyright. È uno strumento personale per tenere traccia di quello che si guarda;
le fonti degli episodi rimandano a servizi esterni e, quando una fonte non è
disponibile, l'app lo dice apertamente invece di fingere.

---

## 📄 Documentazione

| File | Cosa contiene |
| :-- | :-- |
| [`MVP.md`](MVP.md) | Perimetro MVP, architettura, milestone |
| [`STATO_SESSIONE.md`](STATO_SESSIONE.md) | Stato su resolver e player |
| [`RESUME.md`](RESUME.md) | Redesign UI, design system, backlog |
| [`PIANO_CONSIGLI_ORDINE.md`](PIANO_CONSIGLI_ORDINE.md) | Consigli, ordine di visione, push |
| [`GUIDA_FIREBASE_PUSH.md`](GUIDA_FIREBASE_PUSH.md) | Configurazione notifiche push |
| [`GUIDA_IPA_IOS.md`](GUIDA_IPA_IOS.md) | Build iOS e TestFlight |
| [`COMANDI_USATI.md`](COMANDI_USATI.md) | Comandi ricorrenti del progetto |

---

<div align="center">
<sub>Fatto con Flutter e caffè ☕ — per guardare gli anime e non perdere il conto.</sub>
</div>
