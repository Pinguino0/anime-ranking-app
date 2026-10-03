// ============================================================================
// jikan-proxy - proxy verso Jikan (MyAnimeList) con cache su Supabase
// ============================================================================
// L'app non chiama mai Jikan direttamente: chiama questa funzione.
//
// Motivi:
//  - Jikan ha rate limit stretti (3 richieste/seconda, 60/minuto). Un client
//    che chiama a piacere esaurisce la quota del progetto e la ricerca si
//    blocca per tutti gli utenti dello stesso progetto.
//  - La tabella `anime` non ha policy di scrittura per `authenticated`, solo
//    `service_role`. Questa funzione gira con la service key, quindi e' l'unico
//    modo legittimo di scrivere il catalogo.
//
// Flusso di una ricerca:
//  1. controlla la cache (`anime`), con freschezza controllata
//  2. se la cache e' sufficiente, risponde senza toccare la rete
//  3. altrimenti chiama Jikan, scrive in cache, risponde
//
// Nessuna credenziale Jikan: l'API pubblica e' aperta. Quindi qui dentro non
// c'e' nessun segreto da proteggere oltre alla service key, che Supabase
// gestisce e non finisce mai nel codice.
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Iniezione di SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY e SUPABASE_ANON_KEY:
// sono nelle impostazioni della funzione, non nel file.
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

// Client creato in modo pigro, non al caricamento del modulo.
//
// Il motivo e' il test: `index.test.ts` importa questo file per provare le
// funzioni pure, e i test girano senza le variabili d'ambiente di Supabase. Un
// controllo che lancia all'avvio farebbe fallire l'intero file di test per
// un problema che riguarda solo la produzione. Qui si fallisce alla prima
// richiesta che ha davvero bisogno del database, che e' il punto in cui il
// problema diventa reale.
let supabaseClient: ReturnType<typeof createClient> | null = null

function supabase() {
  if (supabaseClient) return supabaseClient

  if (!SUPABASE_URL || !SERVICE_KEY) {
    // Fallire qui e' corretto: senza service key non si puo' scrivere la cache,
    // e rispondere 200 con risultati vuoti farebbe sembrare funzionante una
    // funzione che non lo e'. Il messaggio nomina la chiave mancante e non ne
    // stampa il valore.
    throw new Error(
      'SUPABASE_URL o SUPABASE_SERVICE_ROLE_KEY mancanti nelle impostazioni della funzione.',
    )
  }

  supabaseClient = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  })
  return supabaseClient
}

const JIKAN_BASE = 'https://api.jikan.moe/v4'

// ---------------------------------------------------------------------------
// Rate limit e retry
// ---------------------------------------------------------------------------
// Jikan risponde 429 quando se ne esaurisce la quota, e capita spesso in
// raffica. Un singolo tentativo fallito lascerebbe l'utente con una ricerca
// vuota e nessun modo di sapere che era temporaneo.
//
// Retry con attesa esponenziale + un'aggiunta casuale: piu' Edge Function
// che ricevono 429 insieme ripartirebbero tutte insieme e riporterebbero
// Jikan in 429, quindi il ritardo va scomposto.
const MAX_ATTEMPTS = 3
const BASE_BACKOFF_MS = 800

// Nome senza trattini: `Retry-Options` non e' un identificatore TypeScript
// valido e il bundle falliva con "Expected '{', got '-'" su index.ts:75.
interface RetryOptions {
  attempt?: number
}

async function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

// `Retry-After` e' in secondi. Se presente vale piu' del backoff calcolato:
// quando il server dice quanto aspettare, si ascolta il server.
function backoffDelay(attempt: number, retryAfter?: string | null): number {
  if (retryAfter) {
    const seconds = Number.parseInt(retryAfter, 10)
    if (Number.isFinite(seconds) && seconds > 0) {
      // Tetto: se il server chiede 60 secondi non si blocca la funzione per
      // 60 secondi, si preferisce fallire e lasciare riprovare il client.
      return Math.min(seconds * 1000, 10_000)
    }
  }
  return BASE_BACKOFF_MS * 2 ** (attempt - 1) + Math.floor(Math.random() * 400)
}

async function fetchJikan(
  path: string,
  params: Record<string, string>,
  opts: RetryOptions = {},
): Promise<unknown> {
  const attempt = opts.attempt ?? 1
  const url = new URL(`${JIKAN_BASE}${path}`)

  for (const [key, value] of Object.entries(params)) {
    if (value !== '' && value != null) {
      url.searchParams.set(key, value)
    }
  }

  const response = await fetch(url, {
    headers: {
      Accept: 'application/json',
      'User-Agent': 'AnimeRank/1.0 (supabase-edge-function)',
    },
  })

  if (response.status === 429) {
    if (attempt >= MAX_ATTEMPTS) {
      throw new HttpError(
        429,
        'Jikan e\' sovraccarico. Riprova fra poco.',
        await safeErrorBody(response),
      )
    }
    await sleep(backoffDelay(attempt, response.headers.get('retry-after')))
    return fetchJikan(path, params, { attempt: attempt + 1 })
  }

  // 5xx e 404 su una ricerca sono errori di Jikan, non dell'app. Il 404 in
  // particolare e' normale (un anime che non esiste), quindi non va
  // trasformato in errore fatale per il client.
  if (!response.ok) {
    throw new HttpError(
      response.status >= 500 ? 502 : response.status,
      `Jikan ha risposto ${response.status}.`,
      await safeErrorBody(response),
    )
  }

  return await response.json()
}

// Il corpo di un errore puo' non essere JSON (un 502 da un proxy). Non deve
// far fallire la gestione dell'errore stesso.
async function safeErrorBody(response: Response): Promise<unknown> {
  try {
    const text = await response.text()
    if (!text) return null
    try {
      return JSON.parse(text)
    } catch {
      return text.slice(0, 500)
    }
  } catch {
    return null
  }
}

class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly details?: unknown,
  ) {
    super(message)
    this.name = 'HttpError'
  }
}

// ---------------------------------------------------------------------------
// Mappatura da Jikan a public.anime
// ---------------------------------------------------------------------------
// Jikan restituisce molta piu' roba di quanta il modello AnimeRank conservi.
// Il mapping e' esplicito e non usa uno spread: se Jikan aggiunge un campo,
// non finisce nel database per caso, e i campi obbligatori sono visibili qui
// invece che fallire piu' avanti con un errore di NOT NULL.
//
// `external_data` riceve il record grezzo cosi' un campo perso in questa
// mappatura non e' perso per sempre.

type JikanGenre = { name: string }
type JikanProducers = { name: string }
type JikanEntry = Record<string, unknown>

function asString(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value : null
}

function asNumber(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value
    .map((item) => asString(item))
    .filter((item): item is string => item !== null)
}

// I generi hanno `.name`, le produzioni no (sono stringhe). Due funzioni
// diverse invece di una con dei ternari illeggibili.
function asNamedArray(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value
    .map((item) => {
      if (typeof item === 'string') return item.trim() || null
      if (item && typeof item === 'object') {
        return asString((item as JikanGenre).name)
      }
      return null
    })
    .filter((item): item is string => item !== null)
}

// Lo status di Jikan (`Finished Airing`) e il nostro enum differiscono per
// spaziature e casi. Una traduzione esplicita con fallback a NULL e' meglio
// di una normalizzazione che potrebbe mappare silenziosamente qualcosa di
// sbagliato: se Jikan inventa un valore nuovo, `null` dice "non lo so" e il
// filtro lo ignora, mentre una normalizzazione potrebbe mettere un valore
// casuale in colonna.
function mapStatus(value: unknown): 'finished_airing' | 'currently_airing' | 'not_yet_aired' | null {
  const raw = asString(value)
  if (!raw) return null
  switch (raw.toLowerCase().replace(/[\s_]+/g, ' ').trim()) {
    case 'finished airing':
    case 'finished':
      return 'finished_airing'
    case 'currently airing':
    case 'airing':
      return 'currently_airing'
    case 'not yet aired':
    case 'upcoming':
      return 'not_yet_aired'
    default:
      return null
  }
}

function mapMediaType(value: unknown): string | null {
  const raw = asString(value)
  if (!raw) return null
  switch (raw.toLowerCase()) {
    case 'tv':
      return 'TV'
    case 'movie':
      return 'Movie'
    case 'ova':
      return 'OVA'
    case 'ona':
      return 'ONA'
    case 'special':
      return 'Special'
    case 'music':
      return 'Music'
    default:
      // Se Jikan aggiunge un tipo, non lo si forza in un enum che lo
      // rifiuterebbe: si lascia NULL finche' l'enum non viene aggiornato.
      return null
  }
}

function mapSeason(value: unknown): string | null {
  const raw = asString(value)?.toLowerCase() ?? null
  return raw === 'winter' || raw === 'spring' || raw === 'summer' || raw === 'fall'
    ? raw
    : null
}

// `aired.from` e' una stringa ISO ("2023-07-08T00:00:00+00:00" oppure
// data sola). Postgres accetta `date`, ma una stringa con orario deve essere
// troncata: il cast di "2023-07-08T00:00:00+00:00" a date funziona in
// Postgres, ma non e' garantito, e il fallback esplicito e' piu' chiaro.
function toDate(value: unknown): string | null {
  const raw = asString(value)
  if (!raw) return null
  const datePart = raw.slice(0, 10)
  return /^\d{4}-\d{2}-\d{2}$/.test(datePart) ? datePart : null
}

function toTimestamp(value: unknown): string | null {
  const date = toDate(value)
  return date ? `${date}T00:00:00Z` : null
}

// Lo score MAL arriva 0-10 con 2 decimali. La colonna e' numeric(3,1): un
// valore come 8.75 arrotonderebbe a 8.8. Si arrotonda qui per coerenza con
// il tipo, non lasciando la decisione al cast di Postgres che potrebbe
// rifiutare un valore fuori scala.
function toScore(value: unknown): number | null {
  const raw = asNumber(value)
  if (raw == null || raw <= 0) return null
  return Math.round(raw * 10) / 10
}

interface MappedAnime {
  external_id: string
  external_source: string
  title: string
  japanese_title: string | null
  synonyms: string[]
  synopsis: string | null
  image_url: string | null
  trailer_url: string | null
  episodes: number | null
  status: string | null
  year: number | null
  duration: string | null
  studio: string | null
  genres: string[]
  demographics: string[]
  media_type: string | null
  season: string | null
  aired_from: string | null
  aired_to: string | null
  score: number | null
  scored_by: number | null
  popularity: number | null
  external_data: JikanEntry
  external_fetched_at: string
  external_stale_at: string
}

// 7 giorni, non 30: i dati di catalogo di MyAnimeList non cambiano ogni giorno
// e il risparmio di quota conta piu' di un titolo aggiornato entro 24 ore.
// Deve restare allineato ad `AppConfig.animeCacheDays` lato client, altrimenti
// il client crede freschi dati che questa funzione considera vecchi, o
// viceversa, e uno dei due rilancia Jikan a ogni ricerca.
const CACHE_DAYS = 7

function mapEntry(entry: JikanEntry): MappedAnime | null {
  const externalId = asString(entry.mal_id)
  const title = asString(entry.title)

  // Senza id esterno non c'e' niente da scrivere: la UNIQUE su
  // (external_source, external_id) renderebbe impossibile distinguere due
  // righe. Senza titolo, il check della tabella (`title_not_blank`) farebbe
  // fallire l'upsert e servirebbe gestire l'errore qui.
  if (!externalId || !title) return null

  const aired = (entry.aired ?? {}) as JikanEntry
  // `to` null e il caso normale per un anime in corso, non un errore.
  const to = aired.to ? toDate(aired.to) : null

  return {
    external_id: externalId,
    external_source: 'mal',
    title,
    japanese_title: asString(entry.title_japanese),
    // `synonyms` da Jikan e' gia' un array di stringhe pulite.
    synonyms: asStringArray(entry.synonyms),
    synopsis: asString(entry.synopsis),
    // images.jpg e' un array con un solo elemento; la variante `large` non
    // esiste su tutte le voci, quindi si prende la prima disponibile in
    // ordine di preferenza decrescente di qualita'.
    image_url: pickImage(entry.images),
    trailer_url: pickTrailer(entry.trailers),
    episodes: asNumber(entry.episodes),
    status: mapStatus(entry.status),
    year: asNumber(entry.year),
    duration: asString(entry.duration),
    // `studios` e' un array di oggetti con `name`; il primo e' quello
    // principale. `producers` non e' lo studio e non va usato come fallback:
    // produttore e studio sono cose diverse e mescolarle darebbe dati sbagliati.
    studio: asNamedArray(entry.studios)[0] ?? null,
    genres: asNamedArray(entry.genres),
    demographics: asNamedArray(entry.demographics),
    media_type: mapMediaType(entry.type),
    season: mapSeason(entry.season),
    aired_from: toDate(aired.from),
    aired_to: to,
    score: toScore(entry.score),
    scored_by: asNumber(entry.scored_by),
    popularity: asNumber(entry.members),
    // Il record grezzo: se un campo non e' nel mapping non e' perso.
    external_data: entry,
    external_fetched_at: new Date().toISOString(),
    // La freshness: la riga va ricaricata fra CACHE_DAYS giorni. Serve a
    // `anime_stale_idx`, gia' presente in 005.
    external_stale_at: new Date(Date.now() + CACHE_DAYS * 86_400_000).toISOString(),
  }
}

function pickImage(images: unknown): string | null {
  if (!Array.isArray(images) || images.length === 0) return null
  const first = images[0] as JikanEntry | undefined
  if (!first) return null
  // Ordine di preferenza: la piu' grande disponibile. Non si sceglie sempre
  // `large` perche' non e' presente su tutte le voci (i film hanno immagini
  // diverse dalle serie).
  for (const key of ['large', 'default', 'medium', 'image_url', 'small', 'tiny']) {
    const candidate = asString(first[key])
    if (candidate) return candidate
  }
  return null
}

function pickTrailer(trailers: unknown): string | null {
  if (!Array.isArray(trailers) || trailers.length === 0) return null
  const first = trailers[0] as JikanEntry | undefined
  if (!first) return null
  // `embed_url` e` l'embed di YouTube, che funziona dentro l'app.
  // `url` e' il link alla pagina YouTube e aprirebbe un browser esterno.
  return asString(first.embed_url) ?? asString(first.url)
}

// ---------------------------------------------------------------------------
// Scrittura in cache
// ---------------------------------------------------------------------------
// Upsert su (external_source, external_id): se la riga esiste gia' si
// aggiorna, altrimenti si inserisce. Il `onConflict` deve corrispondere
// esattamente alla UNIQUE della tabella, altrimenti PostgREST non trova il
// conflitto e crea righe duplicate a ogni ricerca.
//
// `external_stale_at` viene ricalcolato a ogni scrittura: e' la freshness di
// questa versione dei dati, non di quando l'opera e' apparsa su MAL.

async function upsertCache(rows: MappedAnime[]): Promise<void> {
  if (rows.length === 0) return

  const { error } = await supabase()
    .from('anime')
    .upsert(rows, { onConflict: 'external_source,external_id' })

  if (error) {
    // Non fallire la richiesta: si risponde comunque con i dati appena
    // scaricati da Jikan. Una cache che non si scrive peggiora la prossima
    // ricerca, ma far fallire questa significa lasciare l'utente senza
    // risultati per un problema che riguarda solo la persistenza.
    console.error('jikan-proxy: scrittura cache fallita', error.message)
  }
}

// ---------------------------------------------------------------------------
// Cache: lettura e freschezza
// ---------------------------------------------------------------------------

// Una riga e' fresca se `external_stale_at` e' nel futuro. Se manca (riga
// vecchia senza la colonna) e' considerata non fresca: meglio una chiamata
// in piu' che un dato di mesi fa presentato come recente.
function isFresh(staleAt: unknown): boolean {
  const raw = asString(staleAt)
  if (!raw) return false
  const deadline = Date.parse(raw)
  return Number.isFinite(deadline) && deadline > Date.now()
}



// Legge `id` e freschezza delle righe in catalogo, indicizzati per
// `external_id`.
//
// Serve per due cose, ed e' la stessa lettura: sapere se i dati sono freschi e
// recuperare l'id interno. Senza l'id la UI non puo' votare l'anime, perche'
// `ratings` punta a `anime.id` e non a `external_id`.
//
// Restituisce `null` se il database non e' raggiungibile: la cache e'
// un'ottimizzazione, e fallire qui deve portare a Jikan, non a un errore.
interface CachedRow {
  id: string | null
  fresh: boolean
}

async function readCache(externalIds: string[]): Promise<Map<string, CachedRow> | null> {
  if (externalIds.length === 0) return new Map()

  const { data, error } = await supabase()
    .from('anime')
    .select('external_id, id, external_stale_at')
    .in('external_id', externalIds)

  if (error) {
    console.warn('jikan-proxy: lettura cache fallita', error.message)
    return null
  }

  const out = new Map<string, CachedRow>()
  for (const row of (data ?? []) as JikanEntry[]) {
    const external = asString(row.external_id)
    if (external !== null) {
      out.set(external, {
        id: asString(row.id),
        fresh: isFresh(row.external_stale_at),
      })
    }
  }
  return out
}

// Ricerca sul catalogo locale.
//
// Restituisce `null` per dire "chiedi a Jikan". La distinzione importante: se
// la cache ha 3 risultati freschi ma la pagina ne chiede 24, `null` e la
// risposta giusta, perche' restare con 3 risultati farebbe credere all'utente
// che non ne esistano altri. La cache puo' rispondere solo quando riempie la
// pagina o quando e' sicura che i dati siano completi, e l'unico caso in cui
// lo sa' e' la ricerca esatta: un titolo trovato e' un titolo trovato.
async function searchCache(
  query: string,
  limit: number,
): Promise<unknown | null> {
  const { data, error } = await supabase().rpc('anime_search', {
    _query: query,
    _sort: 'relevance',
    _limit: limit,
    _offset: 0,
  })

  if (error) {
    // Non e' un errore da propagare: la cache e' un'ottimizzazione. Se la RPC
    // non e' ancora applicata o fallisce, si va a Jikan come se non esistesse.
    console.warn('jikan-proxy: cache non disponibile', error.message)
    return null
  }

  const rows = (data ?? []) as JikanEntry[]
  if (rows.length === 0) return null

  // La freshness si controlla su `external_stale_at`, ma `anime_search` non
  // espone quella colonna: senza di lei ogni riga sembrerebbe non fresca e la
  // cache non servirebbe mai. Si chiede la freshness insieme, per gli id
  // esterni che tornano dalla ricerca.
  const cache = await readCache(
    rows.map((row) => asString(row.external_id)).filter((id): id is string => id !== null),
  )
  if (cache === null) return null

  // Righe stale: si sa' che esistono ma i dati sono vecchi. Meglio chiedere a
  // Jikan e riscrivere, che mostrare un anime con la copertina dell'anno prima
  // come se fosse attuale.
  const allFresh = rows.every((row) => cache.get(asString(row.external_id) ?? '')?.fresh === true)
  if (!allFresh) return null

  // La cache risponde solo se riempie la pagina. Con 3 righe su 24 richieste
  // dichiarare "fatto" lascerebbe l'utente a scorrere una lista vuota, e con
  // "c'e' un'altra pagina" l'infinite scroll ripeterebbe la stessa ricerca
  // all'infinito: nessuna delle due risposte e' vera, quindi si passa a Jikan.
  if (rows.length < limit) return null

  return {
    results: rows.map((row) => ({
      external_id: row.external_id,
      title: row.title,
      japanese_title: row.japanese_title,
      synopsis: row.synopsis,
      image_url: row.image_url,
      episodes: row.episodes,
      status: row.status,
      year: row.year,
      genres: row.genres,
      media_type: row.media_type,
      season: row.season,
      aired_from: row.aired_from,
      aired_to: row.aired_to,
      score: row.score,
      scored_by: row.scored_by,
      popularity: row.popularity,
      duration: row.duration,
      studio: row.studio,
      // L'id arriva dalla lettura di freshness, non dalla RPC: `anime_search`
      // non espone `external_stale_at`, quindi se la freshness fosse letta da
      // li' la cache non servirebbe mai. Qui l'id e' quello che la UI usa per
      // votare, quindi viene riletto insieme.
      id: cache.get(asString(row.external_id) ?? '')?.id ?? null,
      similarity: row.similarity,
      // Qui la provenienza e' il catalogo: la UI puo' dire "risultato gia' in
      // cache" e, soprattutto, sa che l'id esiste davvero in `anime` e puo'
      // usarlo per votare senza un secondo passaggio.
      in_catalog: true,
    })),
    pagination: {
      page: 1,
      limit,
      // La pagina e' piena per costruzione (vedi il controllo sopra), quindi
      // dichiarare che ci sono altre righe e' ragionevole: se in realta sono
      // finite, la richiesta successiva restituisce una pagina vuota e il client
      // si ferma da solo. Dichiarare `false` quando non si sa' fermerebbe lo
      // scroll su risultati che esistono ma non sono stati caricati.
      has_next: true,
      total: null,
    },
    source: 'cache',
  }
}

// ---------------------------------------------------------------------------
// Azioni
// ---------------------------------------------------------------------------

// Ricerca: prima la cache, poi Jikan.
//
// L'ordine e' quello che tiene sotto controllo la quota. La cache e' gia' indicizzata
// per la ricerca testuale (indice GIN trigram in 019), quindi la domanda "c'e' gia'
// qualcosa per 'titan'" costa una query locale e niente rete.
//
// La cache viene interrogata con la stessa funzione del client, cosi i due
// percorsi restituiscono lo stesso ordine e la stessa forma: se la cache ha
// gia' abbastanza risultati freschi, la risposta e' indistinguibile da quella
// che darebbe Jikan, e il client non deve preoccuparsi di quale sia.
//
// `page` viene ignorata quando si risponde dalla cache: la paginazione della
// cache e' quella di `anime_search`, non quella di Jikan, e rimescolarle
// produrrebbe pagine incoerenti fra una chiamata e l'altra. Per questo la
// cache risponde solo alla prima pagina, dove non serve sapere il numero.
async function search(
  query: string,
  limit: number,
  page: number,
  genreFilter: string | null,
): Promise<unknown> {
  const trimmed = query.trim()

  if (trimmed === '') {
    throw new HttpError(400, 'La ricerca vuota non e\' ammessa su questa rotta.')
  }

  // Solo la prima pagina puo' essere servita dalla cache: per le successive
  // l'offset ha senso rispetto a Jikan, e la cache non sa riprodurlo.
  if (page === 1) {
    const cached = await searchCache(trimmed, limit)
    if (cached) return cached
  }

  // I parametri validi sono quelli di Jikan: inviare `sfw` o altro sconosciuto
  // fa rispondere 400 e il risultato e' poco leggibile. Filtro dichiarati qui
  // perche' devono combaciare con quelli che 015 consente al client.
  const validFilters = new Set([
    'airing', 'upcoming', 'tv', 'movie', 'ova', 'special', 'by_popularity',
    'favorite', 'score', 'sfw',
  ])
  const filter = genreFilter && validFilters.has(genreFilter) ? genreFilter : null

  const params: Record<string, string> = {
    q: trimmed,
    limit: String(limit),
    page: String(page),
  }
  if (filter) params.filter = filter

  const payload = (await fetchJikan('/anime', params)) as {
    data?: unknown
    pagination?: unknown
  }

  const rawEntries = Array.isArray(payload?.data) ? payload.data : []
  const mapped = rawEntries
    .map((entry) => mapEntry(entry as JikanEntry))
    .filter((row): row is MappedAnime => row !== null)

  // Se Jikan ha restituito solo voci non mappabili, la risposta vuota sarebbe
  // indistinguibile da "nessun risultato". Un errore dice la verita'.
  if (mapped.length === 0 && rawEntries.length > 0) {
    throw new HttpError(
      502,
      'Jikan ha restituito voci non utilizzabili.',
      { skipped: rawEntries.length },
    )
  }

  await upsertCache(mapped)

  // Rilettura: adesso le righe esistono davvero in `anime` e hanno un `id`.
  // Restituire `id: null` direbbe al client "questo risultato non e' nel
  // catalogo" quando invece e' stato appena messo dentro: la UI nasconderebbe
  // i pulsanti di voto su un anime che si puo' votare, e al primo scroll la
  // cache restituirebbe la stessa opera con `id` diverso.
  const cache = await readCache(mapped.map((row) => row.external_id))

  return {
    results: mapped.map((row) => toResult(row, cache?.get(row.external_id) ?? null)),
    pagination: normalisePagination(payload?.pagination, page, limit),
    source: 'jikan',
  }
}

// Stagione corrente e "popularita" per la home.
// Jikan ha due endpoint utili: `/seasons/now` per la stagione in corso e
// `/top/anime` per i piu' votati di sempre. La home vuole entrambi ("vedi gli
// ultimi e quelli vecchi"), quindi li si chiede insieme.
async function season(kind: 'now' | 'recent' | 'top', limit: number): Promise<unknown> {
  let path = '/seasons/now'
  if (kind === 'recent') path = '/anime'
  if (kind === 'top') path = '/top/anime'

  const params: Record<string, string> = {
    limit: String(limit),
    page: '1',
    // `sfw` esclude i contenuti espliciti dalla home. E' una scelta di
    // prodotto: le classifiche di gruppo sono sociali e condivise.
    sfw: 'true',
  }
  if (kind === 'recent') {
    // Ordinati per uscita recente: altrimenti `/anime` senza `order_by`
    // restituisce l'ordinamento predefinito, che non e' quello richiesto.
    params.order_by = 'start_date'
    params.sort = 'desc'
  }

  const payload = (await fetchJikan(path, params)) as {
    data?: unknown
    pagination?: unknown
  }

  const rawEntries = Array.isArray(payload?.data) ? payload.data : []
  const mapped = rawEntries
    .map((entry) => mapEntry(entry as JikanEntry))
    .filter((row): row is MappedAnime => row !== null)

  await upsertCache(mapped)
  const cache = await readCache(mapped.map((row) => row.external_id))

  return {
    results: mapped.map((row) => toResult(row, cache?.get(row.external_id) ?? null)),
    pagination: normalisePagination(payload?.pagination, 1, limit),
    source: 'jikan',
  }
}

function normalisePagination(raw: unknown, page: number, limit: number): {
  page: number
  limit: number
  has_next: boolean
  total: number | null
} {
  const pagination = (raw ?? {}) as JikanEntry
  const items = (pagination.items ?? {}) as JikanEntry
  const total = asNumber(items.count) ?? asNumber(pagination.total)
  const currentPage = asNumber(pagination.current_page) ?? page
  const lastVisible = asNumber(pagination.last_visible_page)
  const hasNextPage = asNumber(pagination.has_next_page)

  // `has_next` si ricava da tre segnali in ordine di affidabilita', perche'
  // nessuno dei tre e' garantito da Jikan: se la forma della risposta cambia,
  // la paginazione continua a funzionare con quello successivo.
  //
  // L'ultimo fallback e' la via piu conservativa: dichiarare "non ci sono altre
  // pagine" quando non si sa, perche' un infinite scroll fermo si puo'
  // ripartire cambiando filtro, mentre uno che continua a girare su se stesso
  // consuma quota per sempre.
  const hasNext =
    hasNextPage != null
      ? hasNextPage > 0
      : lastVisible != null
        ? currentPage < lastVisible
        : total != null
          ? currentPage * limit < total
          : false

  return {
    page: currentPage,
    limit,
    has_next: hasNext,
    total,
  }
}

// Risposta al client: stessi campi della RPC anime_search, cosi' il client ha
// un solo modello da costruire e non deve distinguere "viene dal catalogo" da
// "viene da Jikan".
// `cached` e' la riga letta in `anime` dopo l'upsert, se c'e'. Quando c'e' con
// l'id, il risultato e' gia' in catalogo e la UI puo' votarlo subito.
function toResult(row: MappedAnime, cached: CachedRow | null): Record<string, unknown> {
  return {
    external_id: row.external_id,
    title: row.title,
    japanese_title: row.japanese_title,
    synopsis: row.synopsis,
    image_url: row.image_url,
    episodes: row.episodes,
    status: row.status,
    year: row.year,
    genres: row.genres,
    media_type: row.media_type,
    season: row.season,
    aired_from: row.aired_from,
    aired_to: row.aired_to,
    score: row.score,
    scored_by: row.scored_by,
    popularity: row.popularity,
    duration: row.duration,
    studio: row.studio,
    // L'id reale quando la riga e' stata appena scritta in `anime`, `null`
    // altrimenti: non si fabbrica un id che non esiste, altrimenti la UI
    // mostrerebbe i pulsanti di voto e la scrittura fallirebbe con una
    // violazione di chiave esterna.
    id: cached?.id ?? null,
    // La similarita' e' un valore interno del catalogo locale: qui non e' stata
    // calcolata, quindi `null` e non uno zero che sembrerebbe "nessuna
    // corrispondenza" quando in realta non e' stata valutata.
    similarity: null,
    // Vero solo se la riga e' stata letta dal catalogo dopo la scrittura.
    in_catalog: cached?.id != null,
  }
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      // Nessuna cache HTTP: i risultati dipendono dalla query e dal momento in
      // cui si chiede. Una cache del browser mostrerebbe a uno studente i
      // risultati di un altro.
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
    },
  })
}

function errorResponse(error: unknown): Response {
  if (error instanceof HttpError) {
    // 429 e 503 hanno Retry-After: senza, il client puo' martellare
    // immediatamente e finire in un loop di richieste.
    if (error.status === 429) {
      return new Response(
        JSON.stringify({
          error: error.message,
          code: 'rate_limited',
          retry_after_seconds: 30,
        }),
        {
          status: 429,
          headers: {
            'Content-Type': 'application/json; charset=utf-8',
            'Retry-After': '30',
          },
        },
      )
    }

    return json({ error: error.message, code: 'upstream_error', details: error.details ?? null }, error.status)
  }

  console.error('jikan-proxy: errore non gestito', error)
  // Il messaggio interno non esce: puo' contenere URL con chiavi o dettagli
  // della struttura. Il client riceve un messaggio generico e il dettaglio
  // resta nei log.
  return json({ error: 'Errore interno del proxy anime.', code: 'internal' }, 500)
}

// CORS. La funzione viene chiamata dall'app Flutter, che su Android e' un
// client nativo e su web fa richieste con Origin. Senza questi header il
// browser blocca la risposta.
const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
}

// L'handler e' esportato invece di essere passato direttamente a Deno.serve:
// i test lo importano per chiamarlo a mano, e un import che fa partire il
// server aprirebbe una porta durante `deno test`. L'avvio resta in fondo,
// eseguito solo quando questo file e' il punto d'ingresso.
// Il gateway chiama sempre la radice della funzione: l'URL che arriva qui e'
// `/functions/v1/jikan-proxy`, non `/functions/v1/jikan-proxy/search`.
//
// Quindi la rotta va espressa come parametro `route`, non come path: e' l'unico
// modo che funziona sia dalla gateway sia da una chiamata diretta con
// `?route=/search`. Il path resta accettato per chi chiama a mano.
const ROUTES = new Set(['/search', '/season', '/recent', '/top', '/health'])

function resolveRoute(url: URL): string {
  const fromQuery = url.searchParams.get('route')
  if (fromQuery && ROUTES.has(fromQuery)) return fromQuery

  // Path diretto: l'ultimo segmento utile e' quello dopo il nome della funzione.
  // `/functions/v1/jikan-proxy/search` -> `/search`.
  const segments = url.pathname.split('/').filter(Boolean)
  const last = segments.length > 0 ? `/${segments[segments.length - 1]}` : url.pathname
  if (ROUTES.has(last)) return last

  return url.pathname
}

export async function handleRequest(request: Request): Promise<Response> {
  // Preflight: risponde senza eseguire nulla, altrimenti il browser non parte.
  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS })
  }

  if (request.method !== 'GET') {
    return json({ error: 'Solo GET.', code: 'method_not_allowed' }, 405)
  }

const url = new URL(request.url)
  const route = resolveRoute(url)

  // --- Autenticazione -------------------------------------------------------
  // Senza un utente collegato non c'e' nessuna ragione di esistere: la cache
  // del catalogo e condivisa, ma si popola usando la quota Jikan del progetto,
  // e senza autenticazione chiunque potrebbe riempirla a piacere.
  //
  // La validazione vera e propria la fa la piattaforma Supabase prima di
  // arrivare qui, se la funzione ha `verify_jwt = true`. Il controllo sotto e'
  // deliberatamente debole perche' non puo' fare di meglio: non c'e' un
  // client Supabase a disposizione per validare il token, e verificare il
  // JWT a mano (firma, scadenza, audience) significherebbe duplicare codice
  // crittografico che puo' sbagliare in silenzio. Un controllo sbagliato che
  // lascia passare una richiesta e' meno grave di una verifica fatta a mano
  // che rifiuta utenti legittimi.
  //
  // La difesa vera e' `verify_jwt`, che va impostata nelle impostazioni della
  // funzione. Se resta disattivata, questa funzione e' pubblica: da mettere a
  // posto al deploy, non da fingere sia gia' fatto.
  if (!request.headers.get('Authorization')) {
    return json({ error: 'Autenticazione richiesta.', code: 'unauthorized' }, 401)
  }

  try {
    let response: unknown

    switch (route) {
      case '/search': {
        const query = url.searchParams.get('q') ?? ''
        const limit = clampNumber(url.searchParams.get('limit'), 24, 1, 25)
        const page = clampNumber(url.searchParams.get('page'), 1, 1, 100)
        const filter = url.searchParams.get('filter')
        response = await search(query, limit, page, filter)
        break
      }

      case '/season':
      case '/top':
      case '/recent': {
        const kind = route === '/season' ? 'now' : route === '/top' ? 'top' : 'recent'
        const limit = clampNumber(url.searchParams.get('limit'), 24, 1, 25)
        response = await season(kind, limit)
        break
      }

      case '/health':
        // Serve a distinguere "funzione spenta" da "Jikan non risponde". Senza
        // questo, l'unico sintomo e' una ricerca vuota.
        response = { status: 'ok', service: 'jikan-proxy', time: new Date().toISOString() }
        break

      default:
        return json(
          {
            error: `Rotta sconosciuta: ${route}`,
            code: 'not_found',
            routes: ['/search?q=...', '/season', '/recent', '/top', '/health'],
          },
          404,
        )
    }

    const out = json(response)
    for (const [key, value] of Object.entries(CORS_HEADERS)) {
      out.headers.set(key, value)
    }
    return out
  } catch (error) {
    const out = errorResponse(error)
    for (const [key, value] of Object.entries(CORS_HEADERS)) {
      out.headers.set(key, value)
    }
    return out
  }
}

// Avvio del server solo se questo file e' il punto d'ingresso. Sotto
// `deno test` l'import non deve aprire porte: e' condizione sufficiente perche'
// i test non puntino mai a index.ts come entrypoint.
if (import.meta.main) {
  Deno.serve(handleRequest)
}

// I limiti di Jikan sono 3/sec e 25 risultati per pagina. Oltre, la richiesta
// viene rifiutata: meglio tagliare qui che ricevere un errore.
function clampNumber(raw: string | null, fallback: number, min: number, max: number): number {
  if (raw == null || raw.trim() === '') return fallback
  const parsed = Number.parseInt(raw, 10)
  if (!Number.isFinite(parsed)) return fallback
  return Math.min(Math.max(parsed, min), max)
}

// Esportazioni per i test con Deno: senza, la mappatura e la freschezza
// sarebbero verificabili solo passando da una chiamata HTTP reale.
export { isFresh, mapEntry, mapStatus, mapMediaType, resolveRoute, toDate, toScore }