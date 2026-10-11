# AnimeRank — MVP

Stato al **6 ottobre 2026**. Documento di sintesi: cosa fa l'app, cosa è MVP
e cosa no, come è costruita, e dove siamo.

---

## 1. Il problema

Un utente che segue gli anime tiene quattro cose in quattro posti diversi:
il catalogo su un sito, il progresso a memoria o in un note, il voto in
testa, e la discussione con gli amici su un gruppo chat. Nessuno di questi
strumenti sa quale episodio sei arrivato, e ogni app che prova a fare tutto
insieme finisce per clonare Netflix senza aggiungere niente.

**AnimeRank è un catalogo sociale con riproduzione integrata**: scopri,
segna cosa stai guardando, vota episodio per episodio, confrontati con chi
conosci. Non vuol sostituire uno streaming service: vuol essere il posto
dove si tiene conto di quello che si guarda.

---

## 2. Utente

Persona che guarda anime con regolarità, su più titoli contemporaneamente,
in italiano o inglese, che vuole:
- riprendere un episodio da dove l'ha lasciato,
- dare un voto a ogni episodio (non solo al titolo),
- vedere come va il proprio ritmo rispetto a un gruppo di amici.

Target primario: desktop (Windows) e Android.

---

## 3. Perimetro MVP

### In MVP (già costruito)

| Area | Cosa fa |
|---|---|
| **Catalogo** | Annuario stagionale, ricerca, scheda anime con metadati (fonte Jikan via Edge Function `jikan-proxy`) |
| **Auth** | Registrazione, login, sessione persistente, reset via Supabase Auth |
| **Watchlist** | Stati (da vedere / in visione / completato), progresso per titolo, totali |
| **Episodi** | Elenco episodi con progresso e stato, **player integrato**, voto per episodio (1–10, passo 0.5) |
| **Riproduzione** | Fonti multiple con **fallback automatico**, risoluzione lazy delle fonti canoniche, header HTTP, ripresa dalla posizione salvata |
| **Profilo** | Username, avatar, bio, impostazioni notifiche, cancellazione account |
| **Aggiornamenti** | Gate APK: controllo versione, download e nota rilascio |

### Fuori MVP (già costruito, ma non è il cuore)

Gruppi con inviti, classifica, duelli, tornei con tabellone, amicizie,
notifiche, achievements, attività. Sono la **seconda ondata**: tengono
l'utente tornano, ma un nuovo utente può capire il valore dell'app solo
con catalogo + watchlist + episodi.

### Non fare (vincoli)

- Non è uno streaming con licenza: se un episodio non ha fonte, l'app lo
  dice e non finge.
- Niente WebView per fonti `iframe` (codice di terzi nel processo): si
  apre fuori dall'app.
- Nessun URL di riproduzione salvato sul database (token che scadono).
- Non mostrare errori tecnici grezzi: l'utente vede "Riprova", i dettagli
  restano nei log.

---

## 4. Architettura

```
Flutter (Dart 3.13 / Flutter 3.47)
  └── Supabase
        ├── Postgres 17  → schema public, RPC (security definer), RLS
        ├── Auth         → sessioni, profili
        ├── Edge Functions
        │     ├── jikan-proxy      → catalogo esterno (Jikan/MyAnimeList)
        │     └── resolve-source   → fonte canonica → URL effimero + header
        └── Storage     → avatar, immagini
```

**Regole che tengono su**
- Il client non legge mai le tabelle sensibili direttamente: le RPC
  (`episode_sources_list`, `episodes_for_anime`, `anime_search`, …) sono il
  confine e restituiscono già le join giuste.
- La scrittura di `episode_sources`/`providers` è solo `service_role`.
- Il client manda **solo `source_id`**: è la Edge Function a rileggere
  `canonical_url` e provider dal DB → non può diventare un proxy aperto.
- Risoluzione **al playback**, mai persistita.

### Pipeline di riproduzione (modello Aniyomi)

```
DB episode_sources
  ├─ source_url         → già riproducibile: player lo apre subito
  └─ canonical_url      → needsResolution
        │
        ▼
  resolve-source (POST { source_id })
        │  legge fonte + provider (service role)
        │  sceglie adapter da providers.resolve_endpoint
        ▼
  adapter: mock | generic_api
        │  chiama il provider esterno (secrets in env)
        ▼
  { resolved_url, headers, source_type, expires_at }   ← non salvato
        │
        ▼
  media_kit (mpv) → Media(url, httpHeaders: headers)
```

Fallback: risoluzione 8s, apertura 12s, 3 tentativi, poi fonte successiva.
Link scaduto (`isFresh`, margine 60s) → risoluzione forzata di nuovo.

---

## 5. Dati chiave

| Tabella | Ruolo |
|---|---|
| `anime` | Catalogo specchio (da Jikan), `external_id` = MAL |
| `episodes` | Episodi per anime, `episode_num` |
| `episode_sources` | Fonti: `source_url` (diretta) **oppure** `canonical_url` + `provider_id` |
| `providers` | Chi sa risolvere: slug, `resolve_endpoint` (nome adapter), `priority`, `is_active` |
| `watch_progress` | Posizione per utente+episodio (`current_seconds`) |
| `episode_ratings` | Voto per utente+episodio |
| `watchlists` / `profiles` / `groups` / … | Social, fuori dal cuore MVP |

---

## 6. Stato attuale

| Cosa | Stato |
|---|---|
| UI (tutte le schermate, redesign) | ✅ fatto |
| `flutter analyze` | ✅ No issues found |
| `flutter test` | ✅ 506/506 |
| Migrazioni 001–028 sul remoto | ✅ applicate |
| Edge Function `jikan-proxy` | ✅ deployata |
| Edge Function `resolve-source` | ✅ deployata, `/health` → `ok`, 28 test Deno verdi |
| Provider `mock` (fonti finte di prova) | ✅ funzionante |
| Provider `generic_api` (fonte reale) | ⛔ catena OK fino al provider esterno |

### Unico blocco aperto: lo scraper

`generic_api` invia la richiesta a un URL pubblico che **non esiste ancora**:
nel progetto non c'è nessuno script di scraping, e in macchina non c'è
nessun tunnel (ngrok/cloudflared assenti). Finché non c'è:

1. **URL pubblico dello scraper** (VPS, tunnel dal PC, o API di terzi) →
   `GENERIC_PROVIDER_BASE_URL` + `PATH_TEMPLATE` / `METHOD`
   (e rimuovere `GENERIC_PROVIDER_ENDPOINT`, che ha la precedenza),
2. **URL reale della pagina episodio** in `episode_sources.canonical_url`
   (la homepage `https://animeworld.ac` non basta: la Edge Function deve
   poter ricavare quale episodio risolvere),

…l'episodio non parte. Tutto il resto della catena (DB → EF → adapter →
player) è verificato end-to-end.

---

## 7. Milestone

| # | Milestone | Stato |
|---|---|---|
| M0 | Catalogo + auth + scheda anime | ✅ |
| M1 | Watchlist + progresso | ✅ |
| M2 | Episodi + player + voto | ✅ |
| M3 | Risoluzione fonti (Option A) | ✅ infra, ⛔ fonte reale |
| M4 | **Primo episodio guardato davvero dall'app** | ⛔ = M3 + scraper |
| M5 | Social (gruppi, classifica, duelli, tornei) | ✅ costruito, da validare in uso |
| M6 | Profilo con statistiche personali | ⛔ serve RPC aggregata (§6 RESUME.md) |

---

## 8. Come si prova oggi

```powershell
cd "C:\Users\erent\Desktop\anime ranking app\client"
flutter analyze          # "No issues found!"
flutter test             # 506 verdi

cd ..\supabase
deno test -A --node-modules-dir=none functions/resolve-source/   # 28 verdi
```

Catena reale (serve un token):

```powershell
curl.exe -s "https://<proj>.supabase.co/functions/v1/resolve-source?route=/health"
```

Stato DB delle fonti dell'episodio 1 di Shingeki (16498):

```sql
select s.is_active, p.slug, p.is_active as provider_attivo, s.canonical_url
from episode_sources s
join episodes e on e.id = s.episode_id
join anime a on a.id = e.anime_id
left join providers p on p.id = s.provider_id
where a.external_id = '16498' and e.episode_num = 1;
```
