# AnimeRank - sessione di redesign UI

Stato al **4 ottobre 2026**. Serve a riprendere il lavoro a freddo.

---

## 1. Cosa si sta facendo

Redesign completo della UI di AnimeRank (Flutter + Supabase), mantenendo
l'architettura esistente. Vincoli del prompt originale:

- **NON** sostituire Flutter con React Native/Expo
- **NON** modificare il backend se non strettamente necessario - la UI si adatta al backend
- **NON** rompere funzionalita' esistenti: se una feature non entra nel layout, si adatta il layouts
- **NON** mostrare errori tecnici grezzi all'utente
- **NON** fare un clone di Netflix/Crunchyroll: ispirazione di qualita', non copia

---

## 2. Design system - gia' esiste, e' maturo

`lib/core/theme/app_theme.dart` - **NON rifarlo**, e' la base di tutto.

| Componente | Contenuto |
|---|---|
| `ArColors` | `bg`, `surface`/`High`, `container`/`Low`/`High`/`Highest`, `primary` (viola `#8B72FF`), `accent` (blu `#4C8DFF`), `success`/`warning`/`danger`, `textHigh`/`Mid`/`Low`, `border`/`borderSoft`, `brand` (gradiente), `rank(pos)` per le medaglie |
| `ArRadii` | `chip` 12, `control` 16, `card` 20, `sheet` 28, `dialog` 26, `poster` 24 |
| `ArSpace` | `xxs` 4, `xs` 8, `sm` 12, `md` 16, `lg` 24, `xl` 32, `xxl` 48 + `ArSpace.page(context)` |
| `ArMotion` | `fast`/`base`/`slow` + curva `enter` |
| `ArShadows` | `card`, `panel`, `glow(color, strength)` |
| `ArExtension` | `ThemeExtension` + `ArThemeContext` (helper su `BuildContext`) |

Widget riutilizzabili in `lib/core/ui/`:

| File | Contenuto |
|---|---|
| `anime_card.dart` | `AnimeCard` (poster verticale, hover desktop con reveal), `ScoreBadge` |
| `anime_thumb.dart` | `AnimeThumb` - copertina quadrata con fallback sull'iniziale |
| `content_row.dart` | `ContentRow` (carosello con snap), `EmptyState`, `ErrorState`, `SkeletonBox`, `PosterGridSkeleton` |
| `section_header.dart` | `SectionHeader`, `MetricLabel`, `ArChip` (con `iconColor`) |
| `hero_banner.dart` | `HeroBanner` |
| `code_text.dart` | `ArCodeText` - codice gruppo/invito |
| `status_pill.dart` | `StatusPill` |
| `transitions.dart` | `ArReveal`, `ArPressable`, `ArStaggered`, `ArCountUp`, `ArGradientButton` |
| `constants/breakpoints.dart` | `compact` 700 / `medium` 900 / `expanded` / `wideGrid` 1400 |

**Regola aurea**: niente colori, raggi, spazi o padding hardcoded.

> Inter e SpaceGrotesk sono *variable font*: servono **sia** `fontWeight`
> **sia** `fontVariations: [FontVariation('wght', ...)]`.

---

## 3. Stato attuale

`flutter analyze` -> **No issues found!**
`flutter test` -> **468/468 verdi**

| Schermata | Stato |
|---|---|
| Home (hero + caroselli + griglia) | fatto |
| Scheda anime | fatto |
| Ricerca | fatto |
| Shell (sidebar desktop + bottom bar mobile) | fatto |
| Classifica | fatto |
| Duelli | fatto |
| Watchlist | fatto |
| Gruppi (3 schermate) | fatto |
| Profilo | fatto |
| Tornei (2 schermate) | fatto |
| Episodi (lista + player + voto) | fatto |

---

## 4. Cosa ha fatto ogni agente

### Watchlist

`watchlist_screen.dart` riscritta, comportamento invariato.

- `_TotalsStrip`: `Row(spaceEvenly)` + 4 `Column` libere -> ogni `_Stat` in
  `Expanded`. **Era l'overflow sotto i 340px.**
- `ChoiceChip`/`FilterChip` di Material -> `ArChip`.
- `BorderRadius.circular(20)` -> `ArRadii.chip`; `surfaceContainerHighest` -> `ArColors`.
- La barra di progresso prende il **colore dello stato**, non piu' un colore fisso.
- Righe navigabili verso la scheda anime, wrappate in `ArPressable` + `ArReveal` a ondate.
- `_EmptyState` locale eliminata -> `core/ui`.
- Spinner -> `_WatchlistSkeleton` alla stessa altezza della riga vera.
- `ArChip` ha guadagnato `iconColor`: serve perche' il colore del pallino *e'*
  l'informazione ("in visione" e "completato" hanno lo stesso testo).

### Gruppi

Tre schermate riscritte. Bug risolti:

1. **`groups.isEmpty && isLoading` falsificava l'errore** - un errore di rete
   mostrava "Non sei membro di questo gruppo". Ora quattro rami distinti.
2. **Pulsante "Esci dal gruppo" sotto la nav bar**.
3. **Quinta `_LinkCard` attaccata alla quarta** -> `_LinkGrid` mette lo stacco nel ciclo.
4. **`fontFamily: 'monospace'`** -> `ArCodeText`. Il monospaziato di sistema e' un
   file diverso su Android, iOS e Windows.
5. **`Spacer`/`Expanded` dentro `Column` in `GridView` a extent fisso**.
6. **`CircleAvatar` senza `errorBuilder`** -> `ProfileAvatar` con fallback sull'iniziale.
7. Errore e lista vuota fusi in un `_ErrorView` -> separati.
8. `BorderRadius.circular(999)` e spazi hardcoded -> token.
9. Desktop: da 900px in su i membri sono una `DataTable`.

### Profilo

- Errore grezzo stampato -> `_failureMessage()` su `AppFailure.message`.
- Spinner -> `_ProfileSkeleton`; `ListView` -> `SingleChildScrollView` (tastiera).
- Soglia responsive da `!isCompact` a `size.isExpanded`, con vero layout a due colonne.
- `_formatDate` manuale -> `intl` con `initializeDateFormatting('it')`.
- `avatar.dart`: testo che scala con `size`, bordo + `ArShadows.glow`.
  **Firma pubblica `ProfileAvatar` invariata** perche' altri moduli la importano.

### Classifica

Podio, card, barra di punteggio e statistiche animate. Io avevo lasciato a meta'
due helper (`_errorText`, `_RankingSkeleton`); sono collegati in entrambe le tab.

### Tornei

Elenco e tabellone riscritti, `CircularProgressIndicator` e raggi hardcoded tolti.

---



### File nuovi

| File | Ruolo |
|---|---|
| `supabase/migrations/027_episode_ratings.sql` | `episode_ratings` + `episodes_for_anime` + `episode_sources_list` + `episode_rate` |
| `lib/features/episodes/domain/episode.dart` | `Episode`, `EpisodeSource`, `EpisodeSourceType`, `EpisodesFailure`, `episodeHeroTag` |
| `lib/features/episodes/data/episodes_repository.dart` | `EpisodesRepository` + `SupabaseEpisodesRepository` |
| `lib/features/episodes/presentation/episodes_controller.dart` | `episodesProvider`, `episodeSourcesProvider`, `EpisodeRater`, `WatchProgressSaver` |
| `lib/features/episodes/presentation/widgets/episode_player.dart` | player mp4/hls inline, fallback automatico, card per `iframe` |
| `lib/features/episodes/presentation/widgets/episode_tile.dart` | riga di elenco con progresso, stato, voto |
| `lib/features/episodes/presentation/widgets/episode_rating_bar.dart` | voto 1-10 passo 0.5 |
| `lib/features/episodes/presentation/screens/episode_screen.dart` | pagina di visione |
| `test/episodes_test.dart` + `test/helpers/fake_episodes.dart` | 27 test |

### File toccati

- `pubspec.yaml` - aggiunti `video_player`, `url_launcher`, `supabase_flutter`
- `main.dart` - `episodesRepositoryProvider.overrideWithValue(SupabaseEpisodesRepository(client))`
- `app_router.dart` - `AppRoutes.episode(animeId, episodeId)` e
  `AppRoutes.firstEpisode(animeId)`, due rotte figlie di `/anime`
- `anime_detail_screen.dart` - pulsante secondario "Guarda gli episodi",
  visibile solo se `entry.id != null`

### Decisioni

- **`iframe` non e' riproducibile**: incorporare una pagina web in un player
  video significa caricare una WebView dentro l'app, cioe' eseguire codice di
  terze parti nel suo processo. Il backend non assegna comunque `iframe` agli
  utenti (`episode_sources` e' scrivibile solo da `service_role`), quindi la
  card dice "Guarda su <provider>" e apre il link fuori. E' anche la scelta
  onesta: se l'episodio non e' in catalogo con licenza, l'app non finge.
- **Fallback automatico**: se una fonte non parte si prova la successiva senza
  avvisare. Un file morto e' un problema del backend.
- **`pushReplacement` fra episodi**: ogni episodio sullo stack lascerebbe un
  player in pausa e un decoder aperto.
- **Voto su griglia di 19 celle (1.0-10.0)**, non slider: un episodio si vota
  una volta, e un numero a meta' e' un voto che non si ricorda.
- **L'elenco sta a lato** su schermo largo e dentro un foglio su telefono:
  sotto funziona solo se l'elenco e' una riga sola.

### Difetti trovati e chiusi in questa feature

1. **`VideoPlayerController.dispose()` puo' non restituire mai** su un
   controller mai inizializzato. Bloccava `_open()` e lasciava lo scheletro
   pulsare per sempre senza mai mostrare l'errore, anche dopo il fallback.
   Risolto con un tetto di 3 secondi su `dispose`: un decoder che non si chiude
   non deve congelare la pagina.
2. **`initialize()` puo' non completare** (file irraggiungibile, codec che non
   risponde): la sorgente successiva non veniva mai provata. Risolto con
   `EpisodePlayer.openTimeout` = 12 secondi.
3. **Lo scheletro di caricamento sbordava** su schermi bassi: ora e' dentro uno
   `SingleChildScrollView`.
4. **`bool _isReady => ...` senza `get`** faceva impazzire l'analizzatore
   (`missing_method_parameters` + 5 errori a cascata). Scritto `bool get _isReady`.

### Stato del database remoto (verificato 4 ottobre 2026)

Progetto `animerank`, ref `sjbstiexythmapxmrfyp`, eu-west-1, Postgres 17.

| Cosa | Stato |
|---|---|
| 001-025 applicate | si' (19 tabelle presenti: anime, ratings, comments, watchlists, groups, duels, tournaments, ranking_snapshots, group_invites, achievements, friendships, notifications, activities, profiles, user_achievements, tournament_matches, tournament_votes) |
| Cronologia `supabase_migrations` | **era vuota** - le migrazioni erano state applicate incollando l'SQL nell'editor, non con la CLI. Riparata con `supabase migration repair --status applied 001..025`, che scrive solo nella tabella di stato |
| 026 e 027 | **non applicate** |

**Il blocco episodi non esisteva affatto sul database.** Non era solo la 027 a
mancare: anche `episodes`, `episode_sources` e `watch_progress` erano assenti.

### Bug trovato nella 026 e corretto

`current_time` e' una **funzione built-in di PostgreSQL**. Usata come nome di
colonna fa `syntax error at or near "current_time"` e la 026 non applicava.

Rinominata in `current_seconds`, che e' anche piu' chiaro perche' dice l'unita'.
Allineati: `027_episode_ratings.sql` (`wp.current_seconds` in select e in
`group by`) e `episodes_repository.dart` (`select`, `upsert` e lettura).

### Da fare

Applicare 026 e 027. Ora e' possibile con la CLI, perche' la cronologia e'
allineata: `supabase db push` proporrebbe solo queste due e nient'altro.

```
cd "C:\Users\erent\Desktop\anime ranking app"
supabase db push          # mostra le due da applicare e chiede conferma
```

L'ho lasciato all'utente perche' il `--yes` salta la conferma e l'applicazione
alla CLI e' il passaggio che va visto da qualcuno.

Nota operativa: non servono `psql` ne' Docker per leggere lo stato del database.
Basta `supabase inspect db table-stats` (sola lettura) e `supabase migration list`.
`supabase db dump` invece richiede Docker e qui non e' disponibile.

---

## 6. Blocco backend ancora aperto

**Statistiche personali nel profilo (§19)**

`UserProfile` non ha **nessun campo statistico** - solo `id`, `username`,
`avatar_url`, `bio`, `created_at`. `profiles` non ha colonne di conteggio.
L'unica fonte di cifre e' `personal_stats(p_user, p_group)`, che e' **per-gruppo**
e vive in `watchlistTotalsProvider(groupId)`: non serve per un profilo personale.

L'agente del profilo ha **omesso** le cifre piuttosto che mostrarne di fittizie
a zero. Decisione corretta, ma va detta all'utente.

**Da chiedere, se vuole chiudere il cerchio:** una RPC di statistiche personali
aggregate.

Nota: il punto "episodi e voti per singolo episodio" che era in questa sezione
e' **risolto**, vedi §5.

---

## 7. Come riprendere

```powershell
cd "C:\Users\erent\Desktop\anime ranking app\client"
flutter analyze          # deve dire "No issues found!"
flutter test             # riferimento: 468 verdi
```

Poi:

1. Applicare `supabase/migrations/027_episode_ratings.sql` nel pannello Supabase
2. Rileggere `RESUME.md` §8 per il backlog rimasto
3. Passare in rassegna: assenza di `CircularProgressIndicator` residui,
   assenza di `_EmptyState`/`_ErrorState` locali, assenza di colori hardcoded
4. Rileggere §21-§24 (loading, empty, error, ricerca) sull'app reale, non sui file
5. Consegnare il riepilogo finale: file modificati, componenti creati,
   schermate ridisegnate, problemi trovati, funzionalita' che richiedono backend,
   risultato di `flutter analyze`, test eseguiti

> Nota: `client/RESUME_TORNEI.md` e' un file di appunti duplicato lasciato da un
> agente, con caratteri corrotti. Soppiantato da questo file: si puo' cancellare.

---

## 8. Backlog rimasto

| Cosa | Dove | Priorita' |
|---|---|---|
| `CircularProgressIndicator` in `_LoadMore` | `ranking_screen.dart` | bassa - e' dentro la riga "Altre posizioni", il contesto giustifica lo spinner |
| `_PositionBadge`: `SizedBox(width: 30)` con variazione `^12` | `ranking_screen.dart` | media - puo' andare in overflow con numeri a due cifre |
| `RankingTable` senza protezione allo scroll orizzontale | `ranking_screen.dart` | media |
| `RateSheet`: padding hardcoded, `FilledButton` invece di `ArGradientButton` | `ranking_screen.dart` | bassa |
| `OfflineBanner` e `_StatsStrip`: leggibilita' | `ranking_screen.dart` | bassa - verificare a schermo |

### Difetti chiusi

| Difetto | Stato |
|---|---|
| 7 copie di `_ErrorState` | fatto |
| 5 copie di `_EmptyState` | fatto |
| `AnimeThumb` importato dalla feature sbagliata | fatto, spostato in `core/ui` |
| `Colors.green` hardcoded nei duelli | fatto |
| `fontFamily: 'monospace'` nei gruppi | fatto |
| `CircleAvatar` senza `errorBuilder` | fatto |
| Profilo che stampa l'errore grezzo | fatto |
| Overflow di `_TotalsStrip` sotto 340px | fatto |
| `BorderRadius.circular(999)` / colori hardcoded nei tornei | fatto |
| 3 byte NUL in `ranking_screen.dart` che rompevano la compilazione | fatto |
| Byte NUL e caratteri corrotti in questo `RESUME.md` | fatto, riscritto |