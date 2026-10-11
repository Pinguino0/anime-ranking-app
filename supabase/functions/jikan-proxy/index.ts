// ============================================================================
// jikan-proxy - catalogo anime esterno con cache su Supabase
// ============================================================================
// Il nome della funzione e' rimasto `jikan-proxy` perche' e' lo slug gia'
// deployato e a cui punta `AppConfig.jikanFunction`: rinominarlo richiederebbe
// di cambiare il client, deployare la funzione nuova e cancellare la vecchia
// insieme. Il nome e' ormai storico: i dati arrivano da AniList e Kitsu.
//
// Perche' Jikan non c'e' piu'
// ----------------------
// L'API pubblica di Jikan (proxy non ufficiale di MyAnimeList) e' stata
// chiusa definitivamente il 1 ottobre 2026: maintenance mode da giugno 2026,
// brownout da settembre, dismissione completa da ottobre. Da allora
// `api.jikan.moe` non accetta piu' connessioni. Non e' un outage da aspettare:
// e' una fine annunciata.
//
// I provider al loro posto, in ordine di uso:
//  1. AniList: GraphQL, senza chiave, catalogo enorme, ricerca testuale buona.
//  2. Kitsu: REST JSON:API, senza chiave. Non e' un doppione: entra solo quando
//     AniList non risponde o non trova niente, e copre le voci che li non ci
//     sono.
//
// La catena e' per-ricerca, non per-singolo-anime. Nel momento in cui una voce
// arriva da AniList non si va a cercare la stessa opera su Kitsu per
// riempirne i campi mancanti: le due API non hanno una crosswalk affidabile,
// quindi il risultato sarebbero due righe dello stesso titolo con due id
// diversi, e l'utente le vedrebbe come due anime. Se la ricerca su AniList
// non produce niente, si chiede a Kitsu: e' la lettura onesta di "quello che
// manca".
//
// L'app non chiama mai AniList o Kitsu direttamente: chiama questa funzione.
//
// Motivi:
//  - I rate limit sono condivisi fra tutti gli utenti dello stesso progetto. Un
//    client che chiama a piacere esaurisce la quota del progetto e la ricerca
//    si blocca per tutti.
//  - La tabella `anime` non ha policy di scrittura per `authenticated`, solo
//    `service_role`. Questa funzione gira con la service key, quindi e' l'unico
//    modo legittimo di scrivere il catalogo.
//
// Flusso di una ricerca:
//  1. controlla la cache (`anime`), con freschezza controllata
//  2. se la cache e' sufficiente, risponde senza toccare la rete
//  3. altrimenti chiede ai provider in ordine, scrive in cache, risponde
//
// Nessuna credenziale: AniList e Kitsu si interrogano anche senza chiave. Qui
// dentro non c'e' nessun segreto da proteggere oltre alla service key, che
// Supabase gestisce e non finisce mai nel codice.
// ============================================================================

import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Iniezione di SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY e SUPABASE_ANON_KEY:
// sono nelle impostazioni della funzione, non nel file.
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

// Client senza schema generato.
//
// Il progetto non genera i tipi del database dentro le Edge Function, quindi
// `createClient` restituirebbe un client i cui metodi hanno parametri `never` o
// `undefined`: `deno check` fallirebbe su `.upsert(rows)` e `.rpc(...)` anche
// con le chiamate giuste. Dichiarare il Database come `any` dice al type
// checker "qui lo schema non c'e'", che e' il vero, invece di fingere che le
// righe da scrivere non abbiano una forma.
type UntypedClient = SupabaseClient<any>

// Client creato in modo pigro, non al caricamento del modulo.
//
// Il motivo e' il test: `index.test.ts` importa questo file per provare le
// funzioni pure, e i test girano senza le variabili d'ambiente di Supabase. Un
// controllo che lancia all'avvio farebbe fallire l'intero file di test per
// un problema che riguarda solo la produzione. Qui si fallisce alla prima
// richiesta che ha davvero bisogno del database, che e' il punto in cui il
// problema diventa reale.
let supabaseClient: UntypedClient | null = null

function supabase(): UntypedClient {
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
  }) as UntypedClient
  return supabaseClient
}

// ---------------------------------------------------------------------------
// Timeout, rate limit e retry
// ---------------------------------------------------------------------------
// Budget di tempo per una singola richiesta a un provider. Senza, un upstream
// che non viene ricambiato tiene la funzione appesa fino a far scadere il
// gateway, e l'utente vede la ricerca ferma senza capire se il problema sia
// suo. Otto secondi sono abbondanti per entrambi i provider e restano
// largamente dentro i 150 secondi che il gateway concede, quindi il timeout non
// confligge con i retry sui 429.
const PROVIDER_TIMEOUT_MS = 8_000

// Un provider risponde 429 quando la quota e' esaurita. Un singolo tentativo
// fallito lascerebbe l'utente con una ricerca vuota e nessun modo di sapere
// che era temporaneo.
//
// Retry con attesa esponenziale + un'aggiunta casuale: piu' Edge Function che
// ricevono 429 insieme ripartirebbero tutte insieme e riporterebbero il
// provider in 429, quindi il ritardo va scomposto.
const MAX_ATTEMPTS = 3
const BASE_BACKOFF_MS = 800

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

// Richiesta a un provider esterno, con timeout e retry sui 429.
//
// `label` finisce nei log e nei messaggi d'errore: e' il nome del provider, e
// serve a distinguere "AniList non risponde" da "Kitsu non risponde" quando si
// guarda un log di un collaudo.
// `retryable` disattiva il retry sui 429 per le richieste che non hanno senso
// ritentare (una ricerca vuota non diventa valida aspettando).
async function requestUpstream(
  url: string | URL,
  init: RequestInit,
  label: string,
  attempt = 1,
): Promise<unknown> {
  let response: Response
  try {
    response = await fetch(url, {
      ...init,
      headers: {
        Accept: 'application/json',
        'User-Agent': 'AnimeRank/1.0 (supabase-edge-function)',
        ...(init.headers ?? {}),
      },
      signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS),
    })
  } catch (error) {
    // `AbortSignal.timeout` lancia un errore di interruzione, non una risposta
    // del provider: senza questo controllo l'utente leggerebbe "errore interno
    // del proxy" per un upstream semplicemente irraggiungibile, che e' un
    // problema diverso e un rimprovero diverso.
    if (error instanceof Error && error.name === 'TimeoutError') {
      throw new HttpError(504, `${label} non ha risposto in tempo.`)
    }
    throw error
  }

  if (response.status === 429) {
    if (attempt >= MAX_ATTEMPTS) {
      throw new HttpError(
        429,
        `${label} e' sovraccarico. Riprova fra poco.`,
        await safeErrorBody(response),
      )
    }
    await sleep(backoffDelay(attempt, response.headers.get('retry-after')))
    return requestUpstream(url, init, label, attempt + 1)
  }

  // 5xx e 400 su una ricerca sono errori del provider, non dell'app. Non si
  // trasformano in errore fatale per il client senza prima aver provato
  // l'altro provider: e' quello il punto della catena.
  if (!response.ok) {
    throw new HttpError(
      response.status >= 500 ? 502 : response.status,
      `${label} ha risposto ${response.status}.`,
      await safeErrorBody(response),
    )
  }

  return await response.json()
}

// ---------------------------------------------------------------------------
// Helper di mappatura
// ---------------------------------------------------------------------------
// I provider restituiscono molta piu' roba di quanta il modello AnimeRank
// conservi. Il mapping e' esplicito e non usa uno spread: se un provider
// aggiunge un campo, non finisce nel database per caso, e i campi obbligatori
// sono visibili qui invece che fallire piu' avanti con un errore di NOT NULL.
//
// `external_data` riceve il record grezzo cosi' un campo perso in questa
// mappatura non e' perso per sempre.

type RawEntry = Record<string, unknown>

function asString(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value : null
}

function asNumber(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

// Un oggetto, o `{}` se non c'era.
//
// Serve perche' `value.field` su un campo assente e' un crash, e i dati dei
// provider sono pieni di campi opzionali che mancano. La forma compatta
// `(value ?? {}) && value.field` sembra fare la stessa cosa ma non la fa:
// quando `value` e' assente il primo operando diventa `{}`, che e' truthy, e
// il secondo va comunque valutato su `undefined` -> TypeError.
function obj(value: unknown): RawEntry {
  return value && typeof value === 'object' ? (value as RawEntry) : {}
}

// Gli id esterni arrivano come numeri da AniList e come stringhe da Kitsu.
//
// `asString` su un numero dà `null`, e una voce senza id viene scartata: il
// risultato sarebbe stato un catalogo vuoto con la ricerca che sembrava
// funzionare. La trappola e' invisibile perche' un id e' sempre presente nei
// dati, solo del tipo sbagliato.
function toIdString(value: unknown): string | null {
  if (typeof value === 'string' && value.trim() !== '') return value.trim()
  if (typeof value === 'number' && Number.isFinite(value)) return String(Math.trunc(value))
  return null
}

// Kitsu manda i numeri come stringhe JSON (`"84.42"`, `"2002"`), AniList come
// numeri. Serve una lettura che accetta le due forme senza diventare permissiva
// su cio' che non e' un numero: `Number('  ')` e' 0 e metterebbe uno zero
// dove non c'e' niente.
function toNumber(value: unknown): number | null {
  if (typeof value === 'number') return Number.isFinite(value) ? value : null
  if (typeof value === 'string' && value.trim() !== '') {
    const parsed = Number(value)
    return Number.isFinite(parsed) ? parsed : null
  }
  return null
}

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value
    .map((item) => asString(item))
    .filter((item): item is string => item !== null)
}

// I generi sono stringhe (AniList e Kitsu), gli studi sono oggetti con `name`.
// Due funzioni diverse invece di una con dei ternari illeggibili.
function asNamedArray(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value
    .map((item) => {
      if (typeof item === 'string') return item.trim() || null
      if (item && typeof item === 'object') {
        return asString((item as { name?: unknown }).name)
      }
      return null
    })
    .filter((item): item is string => item !== null)
}

// Lo status cambia forma fra i provider (`Finished Airing`, `FINISHED`,
// `finished`) e nessuno dei tre coincide con il nostro enum. Una traduzione
// esplicita con fallback a NULL e' meglio di una normalizzazione che potrebbe
// mappare silenziosamente qualcosa di sbagliato: se un provider inventa un
// valore nuovo, `null` dice "non lo so" e il filtro lo ignora, mentre una
// normalizzazione potrebbe mettere un valore casuale in colonna.
function mapStatus(value: unknown): 'finished_airing' | 'currently_airing' | 'not_yet_aired' | null {
  const raw = asString(value)
  if (!raw) return null
  switch (raw.toLowerCase().replace(/[\s_]+/g, ' ').trim()) {
    // AniList
    case 'finished':
      return 'finished_airing'
    case 'releasing':
      return 'currently_airing'
    case 'not yet released':
      return 'not_yet_aired'
    // Jikan, rimasto perche' i dati gia' in catalogo vengono da li
    case 'finished airing':
      return 'finished_airing'
    case 'currently airing':
      return 'currently_airing'
    case 'not yet aired':
      return 'not_yet_aired'
    // Kitsu chiama "current" quello che gli altri chiamano "in corso".
    case 'current':
      return 'currently_airing'
    // "Hiatus", "Cancelled", "Paused": non c'è un valore dell'enum che dica
    // "sospeso", quindi si lascia NULL invece di inventarne uno. La UI mostra
    // lo stato solo se lo conosce.
    default:
      return null
  }
}

// Stessa idea di `mapStatus`: `TV_SPECIAL` (AniList) e `Special` (Kitsu) sono la
// stessa cosa, e l'enum del database vuole `Special`.
function mapMediaType(value: unknown): string | null {
  const raw = asString(value)
  if (!raw) return null
  switch (raw.toLowerCase().replace(/[\s_]+/g, ' ').trim()) {
    case 'tv':
      return 'TV'
    case 'movie':
      return 'Movie'
    case 'ova':
      return 'OVA'
    case 'ona':
      return 'ONA'
    case 'special':
    case 'tv special':
      return 'Special'
    case 'music':
      return 'Music'
    default:
      // Se un provider aggiunge un tipo, non lo si forza in un enum che lo
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

// Le stagioni sono a cavallo d'anno: dicembre e `winter`, non `fall`. Serve
// anche per i provider che non mandano la stagione (Kitsu la lascia vuota su
// quasi tutto il catalato storico) ma mandano la data di inizio.
function seasonFromMonth(month: number): string | null {
  if (month === 12 || month === 1 || month === 2) return 'winter'
  if (month >= 3 && month <= 5) return 'spring'
  if (month >= 6 && month <= 8) return 'summer'
  if (month >= 9 && month <= 11) return 'fall'
  return null
}

// La stagione corrente per chiedere "cosa esce adesso". Le Edge Function
// girano in UTC, quindi i mesi sono quelli UTC: sbagliare di un'ora non cambia
// la stagione, ma sbagliare il fuso da December 31 a January 1 sì.
function currentSeason(at: Date = new Date()): { season: string; year: number } {
  const month = at.getUTCMonth() + 1
  const year = at.getUTCFullYear()
  // Dicembre e l'inverno *successivo*: la stagione "winter 2027" parte il primo
  // di dicembre 2026, come la chiama MyAnimeList e come la chiama AniList.
  if (month === 12) return { season: 'WINTER', year: year + 1 }
  return { season: (seasonFromMonth(month) ?? 'WINTER').toUpperCase(), year }
}

// La stagione appena passata, per "uscite di recente": la coda della stagione
// corrente e tutta la precedente, che e' dove stanno le opere appena finite.
//
// Attenzione al capodanno: l'inverno 2027 comincia a dicembre 2026, quindi a
// gennaio la stagione precedente e' l'autunno 2026 e non "inverno 2026", che non
// e' mai esistita come stagione.
function previousSeason(at: Date = new Date()): { season: string; year: number } {
  const order = ['WINTER', 'SPRING', 'SUMMER', 'FALL']
  const now = currentSeason(at)
  const index = order.indexOf(now.season)
  if (index <= 0) return { season: 'FALL', year: now.year - 1 }
  return { season: order[index - 1], year: now.year }
}

// `aired.from` e' una stringa ISO ("2023-07-08T00:00:00+00:00" oppure
// data sola). Postgres accetta `date`, ma una stringa con orario deve essere
// troncata: il cast di "2023-07-08T00:00:00+00:00" a date funziona in
// Postgres, ma non e' garantito, e il fallback esplicito e' piu' chiaro.
//
// Il controllo non si ferma alla forma: mese 13 o giorno 45 hanno la forma
// giusta ma non sono una data, e la colonna e' un `date`. Passerebbero il
// controllo e fallirebbero l'upsert, cioe' un'intera pagina di risultati
// persa perche' una riga aveva la data sbagliata.
function toDate(value: unknown): string | null {
  const raw = asString(value)
  if (!raw) return null
  const datePart = raw.slice(0, 10)
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(datePart)
  if (!match) return null
  const month = Number.parseInt(match[2], 10)
  const day = Number.parseInt(match[3], 10)
  if (month < 1 || month > 12 || day < 1 || day > 31) return null
  return datePart
}

// AniList manda le date come `{ year, month, day }` con pezzi mancanti: molte
// voci hanno solo l'anno.
//
// Si pretende anno+mese+giorno tutti e tre. Un `2002-01-01` inventato per
// riempire la colonna `aired_from` sembrerebbe una data vera e finirebbe
// dentro "uscite negli ultimi 90 giorni" con l'anno sbagliato di qualche mese.
// Meglio `NULL`: anno e stagione sono gia' in colonne dedicate, quindi
// l'informazione non si perde.
function fuzzyDateToIso(value: unknown): string | null {
  if (!value || typeof value !== 'object') return null
  const parts = value as { year?: unknown; month?: unknown; day?: unknown }
  const year = toNumber(parts.year)
  const month = toNumber(parts.month)
  const day = toNumber(parts.day)
  if (year == null || month == null || day == null) return null
  if (month < 1 || month > 12 || day < 1 || day > 31) return null
  return `${String(year).padStart(4, '0')}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`
}

// Le descrizioni di AniList vengono richieste con `asHtml: false`, ma non
// sempre sono pulite: restano `<br>` e qualche tag. La colonna e' un testo che
// va a schermo, quindi i tag si tolgono e gli spazi si normalizzano.
//
// Le entita' si decodificano per codice numerico invece che per nome: gli
// accenti si presentano come `&#238;`, `&#xEC;`, `&igrave;` a seconda di chi ha
// generato il testo, e un elenco di nomi coprirebbe solo una parte dei casi.
// `String.fromCodePoint` copre tutti e tre senza una tabella.
function stripHtml(value: unknown): string | null {
  const raw = asString(value)
  if (!raw) return null
  const cleaned = raw
    .replace(/<br\s*\/?>/gi, ' ')
    .replace(/<[^>]*>/g, '')
    .replace(/&(nbsp|#160);/gi, ' ')
    .replace(/&(amp|#38);/gi, '&')
    .replace(/&(quot|#34);/gi, '"')
    .replace(/&(apos|#39);/gi, "'")
    .replace(/&(lt|#60);/gi, '<')
    .replace(/&(gt|#62);/gi, '>')
    // Qualsiasi altra entita' numerica, in decimale o esadecimale.
    .replace(/&#(\d+);/g, (_, code: string) => safeFromCodePoint(Number.parseInt(code, 10)))
    .replace(/&#x([0-9a-f]+);/gi, (_, code: string) => safeFromCodePoint(Number.parseInt(code, 16)))
    .replace(/\s+/g, ' ')
    .trim()
  return cleaned === '' ? null : cleaned
}

// `String.fromCodePoint` lancia sui codici fuori dall'intervallo Unicode: una
// descrizione malformata non deve far fallire la mappatura di tutta la pagina.
function safeFromCodePoint(code: number): string {
  if (!Number.isFinite(code) || code < 0 || code > 0x10ffff) return ''
  try {
    return String.fromCodePoint(code)
  } catch {
    return ''
  }
}

// Lo score arriva 0-10 (Jikan) o 0-100 (AniList, Kitsu). La colonna e'
// numeric(3,1): un valore come 8.75 arrotonderebbe a 8.8. Si arrotonda qui per
// coerenza con il tipo, non lasciando la decisione al cast di Postgres che
// potrebbe rifiutare un valore fuori scala.
function toScore(value: unknown): number | null {
  const raw = toNumber(value)
  if (raw == null || raw <= 0) return null
  return Math.round(raw * 10) / 10
}

// Stessa identita' ma su scala 0-100: AniList (`averageScore`) e Kitsu
// (`averageRating`) ragionano in centesimi.
function toScoreOutOfHundred(value: unknown): number | null {
  const raw = toNumber(value)
  if (raw == null || raw <= 0) return null
  return Math.round(raw) / 10
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
  external_data: RawEntry
  external_fetched_at: string
  external_stale_at: string
}

// 7 giorni, non 30: i dati di catalogo non cambiano ogni giorno e il risparmio
// di quota conta piu' di un titolo aggiornato entro 24 ore.
// Deve restare allineato ad `AppConfig.animeCacheDays` lato client, altrimenti
// il client crede freschi dati che questa funzione considera vecchi, o
// viceversa, e uno dei due rilegge il provider a ogni ricerca.
const CACHE_DAYS = 7

function freshness(): { external_fetched_at: string; external_stale_at: string } {
  return {
    external_fetched_at: new Date().toISOString(),
    // La freshness: la riga va ricaricata fra CACHE_DAYS giorni. Serve a
    // `anime_stale_idx`, gia' presente in 005.
    external_stale_at: new Date(Date.now() + CACHE_DAYS * 86_400_000).toISOString(),
  }
}

// Durata per episodio. AniList la dà in minuti, MyAnimeList in testo libero
// ("24 min per ep"): un numero senza unita' mostrato a schermo non vuol
// dire niente, quindi si uniforma sul testo.
function toDuration(minutes: unknown): string | null {
  const raw = toNumber(minutes)
  if (raw == null || raw <= 0) return null
  return `${raw} min per ep`
}

// Trailer: solo YouTube diventa un embed. AniList dichiara anche `dailymotion`,
// che l'app non sa riprodurre, quindi li si ignora invece di mandare un link
// che l'aprirebbe in un browser esterno.
function youtubeEmbed(trailer: unknown): string | null {
  if (!trailer || typeof trailer !== 'object') return null
  const entry = trailer as { site?: unknown; id?: unknown }
  const site = asString(entry.site)
  const id = asString(entry.id)
  if (!id) return null
  if (site !== null && site.toLowerCase() !== 'youtube') return null
  return `https://www.youtube.com/embed/${id}`
}

// ---------------------------------------------------------------------------
// Provider: AniList
// ---------------------------------------------------------------------------
// GraphQL su un endpoint solo. Non serve chiave per i dati pubblici, quindi
// non c'e' nessuna credenziale da gestire qui dentro.

const ANILIST_ENDPOINT = 'https://graphql.anilist.co'

const ANILIST_MEDIA_FIELDS = `
  id
  idMal
  title { romaji english native }
  synonyms
  description(asHtml: false)
  format
  status
  episodes
  duration
  season
  seasonYear
  averageScore
  popularity
  favourites
  isAdult
  genres
  countryOfOrigin
  startDate { year month day }
  endDate { year month day }
  coverImage { large extraLarge color }
  trailer { site id thumbnail }
  studios(isMain: true) { nodes { name } }
`

// I filtri che il client puo' mandare sono gli stessi di prima, ma i loro
// equivalenti AniList hanno nomi diversi. La mappa e' chiusa perche' i valori
// finiscono dentro la query come letterali (vedi `buildMediaArgs`): se fosse
// una stringa passata dal client verrebbe interpolata nella query.
const ANILIST_FILTERS: Record<string, { format?: string; status?: string; sort?: string }> = {
  tv: { format: 'TV' },
  movie: { format: 'MOVIE' },
  ova: { format: 'OVA' },
  special: { format: 'TV_SPECIAL' },
  airing: { status: 'RELEASING' },
  upcoming: { status: 'NOT_YET_RELEASED' },
  by_popularity: { sort: 'POPULARITY_DESC' },
  favorite: { sort: 'FAVOURITES_DESC' },
  score: { sort: 'SCORE_DESC' },
}

// Costruisce gli argomenti della selezione `media`.
//
// Il motivo per cui gli argomenti si assemblano qui e non si mandano come
// variabili `null`: AniList NON ignora una variabile nulla su `format` o
// `status`, la usa come filtro e il risultato e' zero righe. Una query con
// `{ search: $q, format: $format }` e `$format: null` restituisce
// `{ total: 0, media: [] }` senza alcun errore: la ricerca sembra funzionare e
// non trova niente, che e' il peggiore dei modi di rompersi. Il filtro si
// scrive quindi solo quando c'e'.
//
// Gli argomenti inline sono letterali di enum provenienti da `ANILIST_FILTERS`,
// mai testo del client: e' l'unico motivo per cui qui non si usa una variabile.
//
// `page` e `perPage` non compaiono: vanno su `Page(...)`, non su `media(...)`,
// e sbagliando posizione AniList risponde 400 "Unknown argument".
function buildMediaArgs(options: {
  filter: string | null
  sort?: string
  status?: string
  season?: string
  seasonYear?: number
  startDateGreater?: number
}): string {
  const args = ['type: ANIME', 'isAdult: false']

  const preset = options.filter ? ANILIST_FILTERS[options.filter] : undefined
  const format = preset?.format
  const status = options.status ?? preset?.status
  const sort = options.sort ?? preset?.sort

  if (format) args.push(`format: ${format}`)
  if (status) args.push(`status: ${status}`)
  if (sort) args.push(`sort: [${sort}]`)
  if (options.season) args.push(`season: ${options.season}`)
  if (options.seasonYear != null) args.push(`seasonYear: ${options.seasonYear}`)
  if (options.startDateGreater != null) args.push(`startDate_greater: ${options.startDateGreater}`)

  return args.join(', ')
}

async function anilist(
  query: string,
  variables: Record<string, unknown>,
): Promise<RawEntry> {
  const payload = (await requestUpstream(
    ANILIST_ENDPOINT,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ query, variables }),
    },
    'AniList',
  )) as { data?: unknown; errors?: unknown }

  // AniList risponde 200 anche quando la query e' sbagliata, con `errors` e
  // `data: null`. Se non si guarda, una query rotta si presenta come "nessun
  // risultato" e si va a controllare tutto il resto del codice.
  if (payload?.errors) {
    throw new HttpError(502, 'AniList ha rifiutato la query.', payload.errors)
  }

  return ((payload?.data ?? {}) as RawEntry)
}

interface Pagination {
  page: number
  limit: number
  has_next: boolean
  total: number | null
}

// `pageInfo.total` su AniList e' troncato a 5000: oltre, dice 5000 e non il
// numero vero. Per l'infinite scroll conta `hasNextPage`, che e' esatto, e il
// totale viene passato al client solo come informazione ("trovati N di M").
//
// Il totale viene pero' scartato quando e' incoerente con quello che e' tornato
// indietro: sulla ricerca testuale AniList lo dà inconsistente (4 alla pagina 1,
// 5 alla pagina 2 che non contiene nulla). Un totale inferiore alle righe
// gia' mostrate fa scrivere all'app "4 risultati" mentre a schermo ce ne sono 5,
// che e' peggio di non sapere il totale.
function anilistPagination(info: unknown, limit: number, returned: number): Pagination {
  const pageInfo = obj(info)
  const hasNext = pageInfo.hasNextPage === true
  const page = asNumber(pageInfo.currentPage) ?? 1
  const raw = asNumber(pageInfo.total)
  const alreadyShown = (page - 1) * limit + returned
  const consistent = raw != null && raw >= alreadyShown && raw < 5000
  return {
    page,
    limit,
    has_next: hasNext,
    total: consistent ? raw : null,
  }
}

function mapAnilistMedia(media: RawEntry | null): MappedAnime | null {
  if (!media) return null

  // `id` e' un numero su AniList: va letto con `toIdString`, non con
  // `asString`, che su un numero dà null e farebbe scartare la voce.
  const id = toIdString(media.id)
  const titles = obj(media.title)
  const title = asString(titles.romaji) ?? asString(titles.english) ?? asString(titles.native)
  if (!id || !title) return null

  // AniList tiene i titoli alternativi in `title` e in `synonyms`. Il
  // catalogo cerca anche li' (`search_blob`), quindi metterli nei sinonimi
  // rende ricercabile "Shingeki no Kyojin" quando l'utente cerca
  // "Attack on Titan" e viceversa. Sono i stessi campi che Jikan mandava in
  // `synonyms`, quindi la ricerca locale non cambia comportamento.
  const synonymCandidates = [
    ...asStringArray(media.synonyms),
    asString(titles.english),
    asString(titles.native),
    asString(titles.romaji),
  ]
  const synonyms = [...new Set(
    synonymCandidates.filter((item): item is string => item !== null && item !== title),
  )]

  const studios = obj(obj(media.studios).nodes)
  const startDate = fuzzyDateToIso(media.startDate)
  const cover = obj(media.coverImage)

  return {
    external_id: id,
    external_source: 'anilist',
    title,
    japanese_title: asString(titles.native),
    synonyms,
    synopsis: stripHtml(media.description),
    // `large` e non `extraLarge`: extraLarge e' la locandina quadrata con il
    // bordo colorato, cioe' un'immagine 1:1 dentro una card verticale. `large`
    // e' il poster pulito, che e' quello che si vedeva prima.
    image_url: asString(cover.large ?? cover.extraLarge),
    trailer_url: youtubeEmbed(media.trailer),
    episodes: asNumber(media.episodes),
    status: mapStatus(media.status),
    year: asNumber(media.seasonYear),
    duration: toDuration(media.duration),
    // `studios(isMain: true)` chiede gia' solo quello principale: prendere il
    // primo nome e' corretto e non serve scegliere fra piu' studi.
    studio: asNamedArray(studios)[0] ?? null,
    genres: asStringArray(media.genres),
    // AniList non separa i generi dalle demografiche: il dato non esiste,
    // quindi l'array vuoto e non un valore inventato.
    demographics: [],
    media_type: mapMediaType(media.format),
    season: mapSeason(media.season),
    aired_from: startDate,
    aired_to: fuzzyDateToIso(media.endDate),
    score: toScoreOutOfHundred(media.averageScore),
    // AniList non dice quanti utenti abbiano votato un'opera, dice quanti ce
    // l'hanno in lista. Sono due numeri diversi e `scored_by` viene
    // letto come "votato da N utenti": riempirlo con la lista mentirebbe.
    // Resta NULL e la UI non mostra il dato, che e' la risposta onesta.
    scored_by: null,
    // `popularity` e' il numero di utenti che hanno l'opera in lista: e'
    // esattamente il significato della nostra colonna `popularity`.
    popularity: asNumber(media.popularity),
    // Il record grezzo: se un campo non e' nel mapping non e' perso.
    external_data: media,
    ...freshness(),
  }
}

async function searchAnilist(
  query: string,
  limit: number,
  page: number,
  filter: string | null,
): Promise<ProviderOutcome> {
  const data = await anilist(
    `query Search($search: String, $page: Int, $perPage: Int) {
      Page(page: $page, perPage: $perPage) {
        pageInfo { total currentPage hasNextPage }
        media(search: $search, ${buildMediaArgs({ filter })}) {
          ${ANILIST_MEDIA_FIELDS}
        }
      }
    }`,
    { search: query, page, perPage: limit },
  )

  const pageBlock = ((data.Page ?? {}) as RawEntry)
  const media = Array.isArray(pageBlock.media) ? (pageBlock.media as RawEntry[]) : []

  return {
    source: 'anilist',
    rows: media.map((item) => mapAnilistMedia(item)).filter((row): row is MappedAnime => row !== null),
    rawCount: media.length,
    pagination: anilistPagination(pageBlock.pageInfo, limit, media.length),
  }
}

async function seasonAnilist(kind: SeasonKind, limit: number): Promise<ProviderOutcome> {
  const now = currentSeason()

  if (kind === 'recent') return recentAnilist(limit)

  // `top` su Jikan era "/top/anime", cioe' i piu' votati di sempre: si tiene lo
  // stesso significato invece di scivolare su "i piu' popolari", che darebbe
  // una home diversa da quella che l'utente ha gia' visto.
  const sort = kind === 'top' ? 'SCORE_DESC' : 'POPULARITY_DESC'
  // `season` ha senso solo per la stagione in corso: gli altri due sono
  // ordinamenti su tutto il catalogo, e aggiungere il filtro darebbe solo
  // "le novita' dell'anno scorso".
  const inSeason = kind === 'now'

  const data = await anilist(
    `query Season($page: Int, $perPage: Int) {
      Page(page: $page, perPage: $perPage) {
        pageInfo { total currentPage hasNextPage }
        media(${buildMediaArgs({
          filter: null,
          sort,
          status: inSeason ? 'RELEASING' : undefined,
          season: inSeason ? now.season : undefined,
          seasonYear: inSeason ? now.year : undefined,
        })}) {
          ${ANILIST_MEDIA_FIELDS}
        }
      }
    }`,
    { page: 1, perPage: limit },
  )

  const pageBlock = ((data.Page ?? {}) as RawEntry)
  const media = Array.isArray(pageBlock.media) ? (pageBlock.media as RawEntry[]) : []

  return {
    source: 'anilist',
    rows: media.map((item) => mapAnilistMedia(item)).filter((row): row is MappedAnime => row !== null),
    rawCount: media.length,
    pagination: anilistPagination(pageBlock.pageInfo, limit, media.length),
  }
}

// "Usciti di recente": la coda della stagione corrente unita alla stagione
// precedente, che e' dove stanno le opere appena finite.
//
// Il filtro su AniList non e' affidabile e non si usa: `sort: [START_DATE_DESC]`
// mette in cima le schede appena create con i campi data vuoti (verificato: le
// prime 50 righe sono tutte senza data), e `startDate_greater` restituisce zero
// con qualsiasi valore, literal o variabile, quindi non e' un problema di soglia.
// La finestra si applica qui, dove `aired_from` e' gia' una data valida.
async function recentAnilist(limit: number): Promise<ProviderOutcome> {
  const now = currentSeason()
  const prev = previousSeason()

  const data = await anilist(
    `query Recent($n: Int) {
      a: Page(page: 1, perPage: $n) {
        pageInfo { hasNextPage }
        media(${buildMediaArgs({
          filter: null,
          sort: 'POPULARITY_DESC',
          season: now.season,
          seasonYear: now.year,
        })}) {
          ${ANILIST_MEDIA_FIELDS}
        }
      }
      b: Page(page: 1, perPage: $n) {
        pageInfo { hasNextPage }
        media(${buildMediaArgs({
          filter: null,
          sort: 'POPULARITY_DESC',
          season: prev.season,
          seasonYear: prev.year,
        })}) {
          ${ANILIST_MEDIA_FIELDS}
        }
      }
    }`,
    { n: limit },
  )

  const a = obj(obj(data.a).media)
  const b = obj(obj(data.b).media)
  const media = [
    ...(Array.isArray(a) ? a : []),
    ...(Array.isArray(b) ? b : []),
  ] as RawEntry[]

  const rows = media
    .map((item) => mapAnilistMedia(item))
    .filter((row): row is MappedAnime => row !== null)
    .filter((row) => isRecentAired(row.aired_from))

  // Lo stesso id puo' comparire in entrambi i blocchi se una continuazione e'
  // classificata nella stagione corrente e nella precedente: si tiene il primo.
  const seen = new Set<string>()
  const unique = rows.filter((row) => {
    if (seen.has(row.external_id)) return false
    seen.add(row.external_id)
    return true
  })

  return {
    source: 'anilist',
    rows: unique.slice(0, limit),
    rawCount: media.length,
    pagination: { page: 1, limit, has_next: false, total: unique.length },
  }
}

// ---------------------------------------------------------------------------
// Provider: Kitsu
// ---------------------------------------------------------------------------
// REST JSON:API, senza chiave per le letture. Non e' un doppione di AniList:
// entra solo quando il primo non ha risposto o non ha trovato niente.

const KITSU_BASE = 'https://kitsu.io/api/edge'

// Kitsu accetta al massimo 20 elementi per pagina contro i 50 di AniList.
const KITSU_MAX_PER_PAGE = 20

// I filtri del client che sono anche valori dell'enum `anime_type` della tabella,
// quindi passabili a `anime_search`. `tv`, `movie`, `ova` e `special` hanno lo
// stesso nome nei due posti; gli altri non sono tipi ma ordiamenti o stati
// (`airing`, `upcoming`, `by_popularity`, `favorite`, `score`) e non hanno una
// colonna corrispondente.
const CACHE_MEDIA_TYPES: Record<string, string> = {
  tv: 'TV',
  movie: 'Movie',
  ova: 'OVA',
  special: 'Special',
}

// Finestra di "novita'" usata da `/season?season=recent`: quanto indietro si
// guarda per trovare le opere uscite di recente. Piu' larga dei 90 giorni che
// usa il client a schermo, cosi' il server manda anche le opere a cavallo del
// confine e il lato client continua a poter stringere.
const RECENT_WINDOW_DAYS = 120

// Una data di uscita e' dentro la finestra di "novita'"? Le date sono
// `YYYY-MM-DD`, quindi il confronto fra stringhe e' quello fra date: e' il modo
// per non dover costruire un `Date` e gestire i fusi in un UTC che e' gia' la
// convenzione del resto del file.
//
// Il limite superiore non e' decorativo. Kitsu mette `2029-12-31` come data di
// inizio sulle schede che non hanno una data reale: verificato, arriva in cima a
// `sort=-start_date` con punteggio vuoto. "Usciti di recente" vuol dire gia'
// usciti, quindi una data nel futuro non puo' entrarci. Senza questo controllo
// la fascia recenti era spesso composta da schede mai uscite.
function isRecentAired(airedFrom: string | null): boolean {
  if (!airedFrom) return false
  const day = new Date()
  day.setUTCHours(0, 0, 0, 0)
  const cutoff = new Date(day)
  cutoff.setUTCDate(cutoff.getUTCDate() - RECENT_WINDOW_DAYS)
  return airedFrom >= cutoff.toISOString().slice(0, 10) && airedFrom <= day.toISOString().slice(0, 10)
}

// Etichette che Kitsu usa per i contenuti espliciti. `R` e` ammesso: e'
// "mature", non esplicito, e serve a non svuotare il catalogo.
//
// E' una scelta di prodotto: le classifiche di gruppo sono sociali e condivise,
// quindi dalla home e dalla ricerca restano fuori i contenuti R18. AniList ha
// la stessa esclusione con `isAdult: false`.
const KITSU_ADULT_RATINGS = new Set(['r18'])

function mapKitsuIncluded(included: unknown): Map<string, string> {
  const out = new Map<string, string>()
  if (!Array.isArray(included)) return out
  for (const item of included) {
    const entry = obj(item)
    const id = toIdString(entry.id)
    const name = asString(obj(entry.attributes).name)
    if (id && name) out.set(id, name)
  }
  return out
}

// I generi e gli studi arrivano come id in `relationships` e i nomi in
// `included`: JSON:API tiene i due separati, quindi vanno incrociati.
function relationshipNames(resource: RawEntry, relation: string, names: Map<string, string>): string[] {
  const refs = obj(obj(resource.relationships)[relation]).data
  if (!Array.isArray(refs)) return []
  return (refs as RawEntry[])
    .map((ref) => names.get(toIdString(ref.id) ?? ''))
    .filter((name): name is string => name !== undefined)
}

function mapKitsuEntry(
  resource: RawEntry | null,
  includedNames: Map<string, string>,
): MappedAnime | null {
  if (!resource) return null

  const id = toIdString(resource.id)
  const attributes = obj(resource.attributes)
  const titles = obj(attributes.titles)

  const title = asString(attributes.canonicalTitle) ?? asString(titles.en) ?? asString(titles.en_jp)
  if (!id || !title) return null

  const airedFrom = toDate(attributes.startDate)
  // Kitsu lascia `season` e `seasonYear` vuoti su buona parte del catalogo
  // storico, ma la data di inizio c'e'. La stagione e' derivabile dal mese con
  // la stessa regola del database (`current_season`), quindi si ricava qui
  // invece di lasciare la colonna vuota: senza, il filtro per stagione
  // scarterebbe tutto il catalogo storico.
  const month = airedFrom ? Number.parseInt(airedFrom.slice(5, 7), 10) : NaN
  const season = mapSeason(attributes.season) ?? (Number.isFinite(month) ? seasonFromMonth(month) : null)
  const poster = obj(attributes.posterImage)

  return {
    external_id: id,
    external_source: 'kitsu',
    title,
    japanese_title: asString(titles.ja_jp) ?? asString(titles.ja),
    // Anche qui i titoli alternativi finiscono nei sinonimi, cosi' la ricerca
    // locale li trova: `search_blob` li include gia' di suo.
    synonyms: [...new Set(
      [asString(titles.en), asString(titles.en_jp), asString(titles.ja_jp), asString(titles.ja)]
        .filter((item): item is string => item !== null && item !== title),
    )],
    synopsis: stripHtml(attributes.synopsis),
    image_url: asString(poster.large) ?? asString(poster.original) ?? asString(poster.medium),
    // Kitsu dà l'id del video YouTube, non l'URL dell'embed.
    trailer_url: youtubeEmbed({ site: 'youtube', id: attributes.youtubeVideoId }),
    episodes: toNumber(attributes.episodeCount),
    status: mapStatus(attributes.status),
    year: toNumber(attributes.seasonYear) ?? (airedFrom ? Number.parseInt(airedFrom.slice(0, 4), 10) : null),
    duration: toDuration(attributes.episodeLength),
    // Kitsu non espone gli studi come relazione dell'anime: si lascia NULL
    // invece di usare i produttori, che sono un ente diverso (e' la stessa
    // regola che valeva per Jikan).
    studio: null,
    genres: relationshipNames(resource, 'genres', includedNames),
    demographics: [],
    media_type: mapMediaType(attributes.subtype ?? attributes.showType),
    season,
    aired_from: airedFrom,
    // `endDate` su Kitsu e' quasi sempre null anche per le opere finite: non
    // e' un dato mancante che si puo' ricostruire, quindi resta null.
    aired_to: toDate(attributes.endDate),
    score: toScoreOutOfHundred(attributes.averageRating),
    // Come per AniList, Kitsu non dice quanti utenti abbiano votato.
    scored_by: null,
    popularity: toNumber(attributes.popularityCount),
    external_data: resource,
    ...freshness(),
  }
}

interface KitsuRequest {
  path: string
  params: Record<string, string>
}

async function kitsu({ path, params }: KitsuRequest): Promise<RawEntry> {
  const url = new URL(`${KITSU_BASE}${path}`)
  for (const [key, value] of Object.entries(params)) {
    if (value !== '') url.searchParams.set(key, value)
  }

  const payload = (await requestUpstream(
    url,
    { headers: { Accept: 'application/vnd.api+json' } },
    'Kitsu',
  )) as RawEntry

  // Stessa forma di AniList: 200 con `errors` dentro quando la richiesta e'
  // sbagliata. Senza questo controllo una query rotta sembrerebbe un catalogo
  // vuoto.
  if (Array.isArray(payload?.errors) && payload.errors.length > 0) {
    throw new HttpError(502, 'Kitsu ha rifiutato la richiesta.', payload.errors)
  }

  return payload ?? {}
}

// Kitsu risponde con `meta.count` sul totale della ricerca e i dati nella
// pagina corrente: `has_next` si ricava dai due, non da un campo dedicato.
function kitsuPagination(meta: unknown, returned: number, limit: number, offset: number): Pagination {
  const total = asNumber(obj(meta).count)
  const hasNext = total != null ? offset + returned < total : false
  return {
    page: Math.floor(offset / Math.max(limit, 1)) + 1,
    limit,
    has_next: hasNext,
    total,
  }
}

// Filtro adulti applicato in codice e non con `filter[ageRating]`: la sintassi
// di esclusione di Kitsu non e' documentata in modo affidabile, e una riga
// esplicita qui e' verificabile a colpo d'occhio. Il costo e' una passata in
// piu' su un massimo di 20 righe.
function isAdultKitsu(attributes: RawEntry): boolean {
  if (attributes.nsfw === true) return true
  const rating = asString(attributes.ageRating)
  return rating !== null && KITSU_ADULT_RATINGS.has(rating.toUpperCase())
}

// `returned` conta solo le voci finite in una riga: una voce scartata perche'
// non mappabile non occupa posto a schermo, quindi non puo' far dire "c'e' altro
// da caricare" all'infinite scroll. `rawCount` invece e' quante ne sono arrivate
// ed e' quello che distingue "non c'e' niente" da "c'era roba che non ho saputo
// leggere".
function mapKitsuPage(payload: RawEntry): { rows: MappedAnime[]; rawCount: number; returned: number } {
  const includedNames = mapKitsuIncluded(payload.included)
  const data = Array.isArray(payload.data) ? (payload.data as RawEntry[]) : []

  const rows = data
    .filter((resource) => !isAdultKitsu(obj(resource.attributes)))
    .map((resource) => mapKitsuEntry(resource, includedNames))
    .filter((row): row is MappedAnime => row !== null)

  return { rows, rawCount: data.length, returned: rows.length }
}

// Il tetto di 5 risultati su `filter[text]`: verificato sul campo, non
// documentato. Kitsu risponde a una ricerca testuale con al massimo 5 voci e
// `meta.count` vale 5; `page[offset]=5` restituisce di nuovo le stesse 5 voci
// della prima pagina, `page[offset]=10` restituisce nulla.
//
// Senza questo blocco l'infinite scroll continua a scorrere la stessa pagina e
// l'app riceve sempre le stesse card. La seconda pagina si risponde a mano con
// zero righe: la catena passa oltre e, se AniList era la fonte, non cambia
// nulla; se Kitsu era la fonte, il risultato e' "niente altro da mostrare".
export const KITSU_TEXT_SEARCH_CAP = 5

async function searchKitsu(
  query: string,
  limit: number,
  page: number,
  filter: string | null,
): Promise<ProviderOutcome> {
  const perPage = Math.min(limit, KITSU_TEXT_SEARCH_CAP)
  const offset = (page - 1) * perPage

  if (offset >= KITSU_TEXT_SEARCH_CAP) {
    return {
      source: 'kitsu',
      rows: [],
      rawCount: 0,
      pagination: { page, limit: perPage, has_next: false, total: KITSU_TEXT_SEARCH_CAP },
    }
  }

  // Gli stessi filtri del client, tradotti. Quelli che Kitsu non conosce
  // (upcoming, favorite, score) si perdono: e' gia' cosi' lato client per ONA e
  // Music, e vale il principio opposto di prima: meglio un filtro in meno che
  // un risultato sbagliato.
  //
  // I campi di ordinamento su Kitsu si chiamano come gli attributi JSON in
  // snake_case: `sort=-popularityCount` viene rifiutato con 400 "Invalid sort
  // criteria", come `-averageRating`. `-user_count` e' il numero di utenti che
  // hanno l'opera in lista, cioe' la popolarita'.
  const params: Record<string, string> = {
    'filter[text]': query,
    'page[limit]': String(perPage),
    'page[offset]': String(offset),
    include: 'genres',
    sort: '-user_count',
  }

  switch (filter) {
    case 'tv':
      params['filter[subtype]'] = 'TV'
      break
    case 'movie':
      params['filter[subtype]'] = 'Movie'
      break
    case 'ova':
      params['filter[subtype]'] = 'OVA'
      break
    case 'special':
      params['filter[subtype]'] = 'Special'
      break
    case 'airing':
      params['filter[status]'] = 'current'
      break
  }

  const payload = await kitsu({ path: '/anime', params })
  const { rows, rawCount, returned } = mapKitsuPage(payload)

  return {
    source: 'kitsu',
    rows,
    rawCount,
    pagination: kitsuPagination(payload.meta, returned, perPage, offset),
  }
}

async function seasonKitsu(kind: SeasonKind, limit: number): Promise<ProviderOutcome> {
  // Il tetto e' 20, non il limite richiesto: `page[limit]=60` viene risolto con
  // un 400 "Limit exceeds maximum page size of 20".
  const perPage = Math.min(limit, KITSU_MAX_PER_PAGE)
  const params: Record<string, string> = {
    'page[limit]': String(perPage),
    include: 'genres',
  }

  switch (kind) {
    case 'now':
      params['filter[status]'] = 'current'
      params.sort = '-user_count'
      break
    case 'recent':
      params.sort = '-start_date'
      break
    case 'top':
      params.sort = '-average_rating'
      break
  }

  const payload = await kitsu({ path: '/anime', params })
  const mapped = mapKitsuPage(payload)

  // "recent" tiene solo le opere uscite davvero nella finestra. Su Kitsu non e'
  // un filtro della query, quindi va applicato qui, e si sa' in partenza che
  // lascera quasi tutto fuori: `sort=-start_date` mette in cima le date nel
  // futuro (le prime 20 righe hanno tutte il 2026-12-31 o il 2027, cioe'
  // annunci e segnaposto), che una fascia "uscite di recente" non puo'
  // contenere per definizione.
  //
  // Non si sfoglia piu' in la' per rimediare: la testa dell'ordinamento e' il
  // futuro, e le pagine successive sono ancora piu' lontane. Il primo capitolo
  // con date reali e' a centinaia di offset, dove non si arriva con tre richieste.
  // Meglio una richiesta che risponde "niente" che tre che girano a vuoto:
  // `/recent` su Kitsu resta una rete di sicurezza, non la fonte, perche' AniList
  // risponde alla finestra direttamente con stagione corrente e precedente.
  const rows = kind === 'recent'
    ? mapped.rows.filter((row) => isRecentAired(row.aired_from))
    : mapped.rows

  return {
    source: 'kitsu',
    rows: rows.slice(0, limit),
    rawCount: mapped.rawCount,
    pagination: kitsuPagination(payload.meta, rows.length, perPage, 0),
  }
}

// ---------------------------------------------------------------------------
// Catena di provider
// ---------------------------------------------------------------------------

type SeasonKind = 'now' | 'recent' | 'top'

interface ProviderOutcome {
  source: string
  rows: MappedAnime[]
  // Quante voci sono arrivate prima della mappatura. Serve a distinguere "non
  // c'e' niente" da "c'era roba ma non mappabile": la seconda e' un problema
  // del codice e deve far passare al provider successivo.
  rawCount: number
  pagination: Pagination
}

interface CatalogProvider {
  source: string
  search(query: string, limit: number, page: number, filter: string | null): Promise<ProviderOutcome>
  season(kind: SeasonKind, limit: number): Promise<ProviderOutcome>
}

// L'ordine e' una scelta di prodotto: AniList ha la ricerca testuale migliore e
// la copertura piu' ampia, quindi va interrogato per primo; Kitsu e' la rete di
// sicurezza per quello che AniList non ha o per quando AniList e' giù.
const PROVIDERS: CatalogProvider[] = [
  { source: 'anilist', search: searchAnilist, season: seasonAnilist },
  { source: 'kitsu', search: searchKitsu, season: seasonKitsu },
]

// Un errore in una stringa breve da mettere nel 502 finale: il dettaglio vero
// resta nei log.
function describeError(error: unknown): string {
  if (error instanceof HttpError) return error.message
  if (error instanceof Error) return error.message
  return 'errore sconosciuto'
}

// Tenta i provider in ordine finche' uno risponde con qualcosa.
//
// Tre esiti possibili per ogni provider, da tenere distinti:
//  - righe >= 1: risposta, si restituisce subito
//  - rawCount = 0: puo' essere un vuoto reale, si prova il prossimo per sicurezza
//  - rawCount > 0 ma nessuna riga mappabile: la forma della risposta e' cambiata,
//    si prova il prossimo
// Se tutti falliscono con un errore si risponde 502; se almeno uno ha risposto
// senza trovare niente si risponde 200 con risultati vuoti, che e' la verita'.
async function acrossProviders(
  action: (provider: CatalogProvider) => Promise<ProviderOutcome>,
): Promise<ProviderOutcome> {
  const failures: string[] = []
  let lastSource = PROVIDERS[PROVIDERS.length - 1].source

  for (const provider of PROVIDERS) {
    lastSource = provider.source
    try {
      const outcome = await action(provider)
      if (outcome.rows.length > 0) return outcome
      if (outcome.rawCount > 0) {
        failures.push(
          `${provider.source}: ${outcome.rawCount} voci ricevute, nessuna mappabile`,
        )
        console.warn(`jikan-proxy: ${provider.source} ha cambiato forma, provo il successivo`)
      }
    } catch (error) {
      failures.push(`${provider.source}: ${describeError(error)}`)
      console.warn(`jikan-proxy: ${provider.source} non ha risposto`, error)
    }
  }

  // Falliti tutti: nessuna catena puo' rispondere. Meglio un 502 detto che
  // una lista vuota, che l'utente leggerebbe come "questo anime non esiste".
  if (failures.length === PROVIDERS.length) {
    throw new HttpError(502, 'Nessun catalogo anime ha risposto. Riprova.', { providers: failures })
  }

  return {
    source: lastSource,
    rows: [],
    rawCount: 0,
    pagination: { page: 1, limit: 0, has_next: false, total: 0 },
  }
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
// questa versione dei dati, non di quando l'opera e' apparsa in catalogo.

async function upsertCache(rows: MappedAnime[]): Promise<void> {
  if (rows.length === 0) return

  // Il `try` copre anche la costruzione del client: senza chiavi la cache non
  // e' disponibile, e una cache non disponibile non e' un errore della ricerca.
  // Fuori da qui i risultati ci sono gia': perderli perche' la persistenza
  // fallisce significa lasciare l'utente con una ricerca vuota per un problema
  // che non lo riguarda.
  try {
    const { error } = await supabase()
      .from('anime')
      .upsert(rows, { onConflict: 'external_source,external_id' })

    if (error) {
      console.error('jikan-proxy: scrittura cache fallita', error.message)
    }
  } catch (error) {
    console.error('jikan-proxy: cache non scrivibile', describeError(error))
  }
}

// ---------------------------------------------------------------------------
// Cache: lettura e freschezza
// ---------------------------------------------------------------------------

// Una riga e' fresca se `external_stale_at` e' nel futuro. Se manca (riga
// vecchia senza la colonna) e' considerata non fresca: meglio una chiamata in
// piu' che un dato di mesi fa presentato come recente.
function isFresh(staleAt: unknown): boolean {
  const raw = asString(staleAt)
  if (!raw) return false
  const deadline = Date.parse(raw)
  return Number.isFinite(deadline) && deadline > Date.now()
}

// Legge la freschezza delle righe di catalogo indicizzate per `id` interno.
//
// La chiave e' l'id interno e non `external_id` perche' `external_id` non e'
// univocamente identificante: la tabella ha UNIQUE su
// (external_source, external_id), quindi lo stesso numero puo' esistere come
// id AniList e come id del vecchio seed Jikan. Indicizzando per `external_id`
// la riga restituita potrebbe essere di un'altra fonte, e a video aperto la UI
// mostrerebbe la copertina di un anime diverso. `id` e' un uuid: univoco per
// costruzione.
//
// Restituisce `null` se il database non e' raggiungibile: la cache e'
// un'ottimizzazione, e fallire qui deve portare ai provider, non a un errore.
async function readFreshnessByIds(internalIds: string[]): Promise<Map<string, boolean> | null> {
  if (internalIds.length === 0) return new Map()

  let data: unknown = null
  let error: { message: string } | null = null
  try {
    const result = await supabase()
      .from('anime')
      .select('id, external_stale_at')
      .in('id', internalIds)
    data = result.data
    error = result.error
  } catch (thrown) {
    console.warn('jikan-proxy: cache non raggiungibile', describeError(thrown))
    return null
  }

  if (error) {
    console.warn('jikan-proxy: lettura cache fallita', error.message)
    return null
  }

  const out = new Map<string, boolean>()
  for (const row of (data ?? []) as RawEntry[]) {
    const id = asString(row.id)
    if (id !== null) out.set(id, isFresh(row.external_stale_at))
  }
  return out
}

// Dopo l'upsert, le righe esistono davvero in `anime` e hanno un `id` interno.
// Serve perche' restituire `id: null` direbbe al client "questo risultato non e'
// nel catalogo" quando invece e' stato appena messo dentro: la UI nasconderebbe
// i pulsanti di voto su un anime che si puo' votare.
//
// La ricerca e' per `(external_source, external_id)` e i risultati vengono
// filtrati sul lato client: PostgREST accetta `or` con piu' condizioni, ma
// complicare la query per una coppia di colonne non vale la pena.
async function readCatalogIds(
  source: string,
  externalIds: string[],
): Promise<Map<string, string | null> | null> {
  if (externalIds.length === 0) return new Map()

  let data: unknown = null
  let error: { message: string } | null = null
  try {
    const result = await supabase()
      .from('anime')
      .select('id, external_source, external_id')
      .eq('external_source', source)
      .in('external_id', externalIds)
    data = result.data
    error = result.error
  } catch (thrown) {
    console.warn('jikan-proxy: catalogo non raggiungibile', describeError(thrown))
    return null
  }

  if (error) {
    console.warn('jikan-proxy: lettura catalogo fallita', error.message)
    return null
  }

  const out = new Map<string, string | null>()
  for (const row of (data ?? []) as RawEntry[]) {
    const external = asString(row.external_id)
    if (external !== null) out.set(external, asString(row.id))
  }
  return out
}

// Questo filtro si puo' rispondere dal catalogo locale? Vale solo per i tipi
// che la RPC sa filtrare: per gli altri la cache viene saltata del tutto (vedi
// `searchCache`).
function isCacheableFilter(filter: string | null): boolean {
  return filter === null || filter in CACHE_MEDIA_TYPES
}

// Ricerca sul catalogo locale.
//
// Restituisce `null` per dire "chiedi ai provider". La distinzione importante: se
// la cache ha 3 risultati freschi ma la pagina ne chiede 24, `null` e la
// risposta giusta, perche' restare con 3 risultati farebbe credere all'utente
// che non ne esistano altri. La cache puo' rispondere solo quando riempie la
// pagina o quando e' sicura che i dati siano completi, e l'unico caso in cui
// lo sa' e' la ricerca esatta: un titolo trovato e' un titolo trovato.
//
// `filter` viene girato alla RPC solo se e' anche un valore dell'enum
// `anime_type`. Gli altri filtri (`airing`, `upcoming`, `by_popularity`,
// `favorite`, `score`) non hanno una colonna corrispondente: per quelli si
// salta del tutto la cache invece di far girare la ricerca senza filtro. Una
// ricerca senza filtro non e' la stessa ricerca: `airing` deve restituire solo
// le opere in corso e non anche quelle finite, e `score` deve ordinare per voto.
// Rispondere dalla cache darebbe risultati che il provider non avrebbe mai
// restituito per la stessa domanda.
async function searchCache(
  query: string,
  limit: number,
  filter: string | null,
): Promise<unknown | null> {
  if (!isCacheableFilter(filter)) return null

  const mediaType = CACHE_MEDIA_TYPES[filter ?? ''] ?? null

  // Il `try` avvolge anche la costruzione del client: senza chiavi la cache non
  // esiste, e questo deve valere come "cache non disponibile", non come ricerca
  // fallita. `return null` significa "chiedi ai provider", ed e' la risposta
  // giusta quando il database non c'e'.
  let data: unknown
  let error: { message: string } | null = null
  try {
    const result = await supabase().rpc('anime_search', {
      _query: query,
      _media_type: mediaType,
      _sort: 'relevance',
      _limit: limit,
      _offset: 0,
    })
    data = result.data
    error = result.error
  } catch (thrown) {
    console.warn('jikan-proxy: cache non raggiungibile', describeError(thrown))
    return null
  }

  if (error) {
    // Non e' un errore da propagare: la cache e' un'ottimizzazione. Se la RPC
    // non e' ancora applicata o fallisce, si va ai provider come se non
    // esistesse.
    console.warn('jikan-proxy: cache non disponibile', error.message)
    return null
  }

  const rows = (data ?? []) as RawEntry[]
  if (rows.length === 0) return null

  // La freshness si controlla su `external_stale_at`, che `anime_search` non
  // espone: senza di lei ogni riga sembrerebbe non fresca e la cache non
  // servirebbe mai. Si chiede quindi insieme, per gli id interni che tornano
  // dalla ricerca.
  const ids = rows
    .map((row) => asString(row.id))
    .filter((id): id is string => id !== null)
  const freshness = await readFreshnessByIds(ids)
  if (freshness === null) return null

  // Righe stale: si sa' che esistono ma i dati sono vecchi. Meglio chiedere ai
  // provider e riscrivere, che mostrare un anime con la copertina dell'anno
  // scorso come se fosse attuale.
  const allFresh = ids.every((id) => freshness.get(id) === true)
  if (!allFresh) return null

  // La cache risponde solo se riempie la pagina. Con 3 righe su 24 richieste
  // dichiarare "fatto" lascerebbe l'utente a scorrere una lista vuota, e con
  // "c'e' un'altra pagina" l'infinite scroll ripeterebbe la stessa ricerca
  // all'infinito: nessuna delle due risposte e' vera, quindi si esce.
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
      // L'id arriva direttamente dalla RPC: `anime_search` restituisce gia' il
      // uuid di `anime`, quindi non serve un secondo passaggio per sapere se la
      // riga e' votabile. Il passaggio in piu' serve solo per la freshness.
      id: row.id,
      similarity: row.similarity,
      // Qui la provenienza e' il catalogo: la UI puo' dire "risultato gia' in
      // cache" e sa che l'id esiste davvero in `anime` e puo' usarlo per votare
      // senza un secondo passaggio.
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

// Ricerca: prima la cache, poi i provider.
//
// L'ordine e' quello che tiene sotto controllo la quota. La cache e' gia'
// indicizzata per la ricerca testuale (indice GIN trigram in 019), quindi la
// domanda "c'e' gia' qualcosa per 'titan'" costa una query locale e niente
// rete.
//
// La cache viene interrogata con la stessa funzione del client, cosi' i due
// percorsi restituiscono lo stesso ordine e la stessa forma: se la cache ha
// gia' abbastanza risultati freschi, la risposta e' indistinguibile da quella
// che darebbe un provider, e il client non deve preoccuparsi di quale sia.
//
// `page` viene ignorata quando si risponde dalla cache: la paginazione della
// cache e' quella di `anime_search`, non quella del provider, e rimescolarle
// produrrebbe pagine incoerenti fra una chiamata e l'altra. Per questo la cache
// risponde solo alla prima pagina, dove non serve sapere il numero.
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

  // I parametri validi sono quelli dichiarati in ANILIST_FILTERS: inviare `sfw`
  // o altro sconosciuto non filtrerebbe nulla pur sembrando un filtro. Lo `sfw`
  // non e' piu' un filtro accettato perche' l'esclusione dei contenuti espliciti
  // e' ormai sempre attiva e non negoziabile (vedi `isAdult` e
  // `KITSU_ADULT_RATINGS`).
  const validFilters = new Set(Object.keys(ANILIST_FILTERS))
  const filter = genreFilter && validFilters.has(genreFilter) ? genreFilter : null

  // Solo la prima pagina puo' essere servita dalla cache: per le successive
  // l'offset ha senso rispetto al provider, e la cache non sa riprodurlo.
  //
  // Il filtro va passato anche alla cache: senza, "berserk" con `filter=movie`
  // risponderebbe dalla cache con la prima TV trovata, mentre dal provider
  // arrivalbero solo film. Due risposte diverse per la stessa domanda.
  if (page === 1) {
    const cached = await searchCache(trimmed, limit, filter)
    if (cached) return cached
  }

  const outcome = await acrossProviders((provider) =>
    provider.search(trimmed, limit, page, filter)
  )

  await upsertCache(outcome.rows)

  // Rilettura: adesso le righe esistono davvero in `anime` e hanno un `id`.
  const catalog = outcome.rows.length > 0
    ? await readCatalogIds(outcome.source, outcome.rows.map((row) => row.external_id))
    : new Map<string, string | null>()

  return {
    results: outcome.rows.map((row) => toResult(row, catalog?.get(row.external_id) ?? null)),
    pagination: outcome.pagination,
    source: outcome.source,
  }
}

// Stagione corrente e "popularita" per la home.
// La home vuole tutti e tre i lista ("vedi gli ultimi e quelli vecchi"), quindi
// ogni rotta chiede al provider primario e usa l'altro solo se il primo non
// risponde.
async function season(kind: SeasonKind, limit: number): Promise<unknown> {
  const outcome = await acrossProviders((provider) => provider.season(kind, limit))

  await upsertCache(outcome.rows)

  const catalog = outcome.rows.length > 0
    ? await readCatalogIds(outcome.source, outcome.rows.map((row) => row.external_id))
    : new Map<string, string | null>()

  return {
    results: outcome.rows.map((row) => toResult(row, catalog?.get(row.external_id) ?? null)),
    pagination: outcome.pagination,
    source: outcome.source,
  }
}

// Risposta al client: stessi campi della RPC anime_search, cosi' il client ha
// un solo modello da costruire e non deve distinguere "viene dal catalogo" da
// "viene da un provider esterno".
// `cached` e' l'id interno letto in `anime` dopo l'upsert. Quando c'e', il
// risultato e' gia' in catalogo e la UI puo' votarlo subito.
function toResult(row: MappedAnime, cachedId: string | null): Record<string, unknown> {
  return {
    external_id: row.external_id,
    title: row.title,
    japanese_title: row.japanese_title,
    synopsis: row.synopsis,
    image_url: row.image_url,
    trailer_url: row.trailer_url,
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
    id: cachedId,
    // La similarita' e' un valore interno del catalogo locale: qui non e' stata
    // calcolata, quindi `null` e non uno zero che sembrerebbe "nessuna
    // corrispondenza" quando in realta non e' stata valutata.
    similarity: null,
    // Vero solo se la riga e' stata letta dal catalogo dopo la scrittura.
    in_catalog: cachedId != null,
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

// Le regole CORS valgono su qualunque risposta, anche d'errore: senza
// `Access-Control-Allow-Origin` il browser non fa leggere a JavaScript il corpo
// di un 401, e la app vedrebbe solo "errore di rete" senza il motivo del
// rifiuto. Gli header si possono impostare anche su una `Response` gia'
// costruita, quindi `withCors` basta per tutti i casi.
//
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
function withCors(response: Response): Response {
  for (const [key, value] of Object.entries(CORS_HEADERS)) {
    response.headers.set(key, value)
  }
  return response
}

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
    return withCors(json({ error: 'Solo GET.', code: 'method_not_allowed' }, 405))
  }

  const url = new URL(request.url)
  const route = resolveRoute(url)

  // --- Autenticazione -------------------------------------------------------
  // Senza un utente collegato non c'e' nessuna ragione di esistere: la cache
  // del catalogo e condivisa, ma si popola usando la quota del progetto, e
  // senza autenticazione chiunque potrebbe riempirla a piacere.
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
  // La difesa vera e' `verify_jwt`, che va impostato nelle impostazioni della
  // funzione. Se resta disattivata, questa funzione e' pubblica: da mettere a
  // posto al deploy, non da fingere sia gia' fatto.
  if (!request.headers.get('Authorization')) {
    return withCors(json({ error: 'Autenticazione richiesta.', code: 'unauthorized' }, 401))
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

      case '/health': {
        // Serve a distinguere "funzione spenta" da "nessun catalogo
        // raggiungibile": senza questo, l'unico sintomo e' una ricerca vuota.
        //
        // Non dice solo che la funzione e' viva: dice quali cataloghi stanno
        // davvero rispondendo adesso. Un 200 qui con la lista dei provider
        // sarebbe un'indicazione falsa, perche' finche' nessuno e' stato
        // interrogato non si sa se AniList e Kitsu rispondono.
        const reachable = await Promise.all(
          PROVIDERS.map(async (provider) => {
            const started = Date.now()
            try {
              await provider.season('now', 1)
              return { source: provider.source, ok: true, ms: Date.now() - started }
            } catch (error) {
              return {
                source: provider.source,
                ok: false,
                ms: Date.now() - started,
                error: describeError(error),
              }
            }
          }),
        )

        const anyOk = reachable.some((entry) => entry.ok)
        response = {
          status: anyOk ? 'ok' : 'degraded',
          service: 'jikan-proxy',
          providers: reachable,
          time: new Date().toISOString(),
        }
        break
      }

      default:
        return withCors(
          json(
            {
              error: `Rotta sconosciuta: ${route}`,
              code: 'not_found',
              routes: ['/search?q=...', '/season', '/recent', '/top', '/health'],
            },
            404,
          ),
        )
    }

    // `status` torna gia' pronto da `/health`: li' e' l'unica rotta che puo'
    // dire "vivo ma nessun catalogo risponde", e dirlo con un 503 permette al
    // client di riprovare invece di leggere una ricerca vuota come un vuoto
    // reale del catalogo.
    const degraded = (response as { status?: unknown } | null)?.status === 'degraded'

    return withCors(json(response, degraded ? 503 : 200))
  } catch (error) {
    return withCors(errorResponse(error))
  }
}

// Avvio del server solo se questo file e' il punto d'ingresso. Sotto
// `deno test` l'import non deve aprire porte: e' condizione sufficiente perche'
// i test non puntino mai a index.ts come entrypoint.
if (import.meta.main) {
  Deno.serve(handleRequest)
}

// I limiti dei provider sono 25 risultati per pagina per la richiesta e 20 per
// Kitsu. Oltre, la richiesta viene rifiutata: meglio tagliare qui che ricevere
// un errore.
function clampNumber(raw: string | null, fallback: number, min: number, max: number): number {
  if (raw == null || raw.trim() === '') return fallback
  const parsed = Number.parseInt(raw, 10)
  if (!Number.isFinite(parsed)) return fallback
  return Math.min(Math.max(parsed, min), max)
}

// Esportazioni per i test con Deno: senza, la mappatura e la freschezza
// sarebbero verificabili solo passando da una chiamata HTTP reale.
export {
  acrossProviders,
  anilistPagination,
  buildMediaArgs,
  currentSeason,
  fuzzyDateToIso,
  isFresh,
  isCacheableFilter,
  isRecentAired,
  mapAnilistMedia,
  mapKitsuEntry,
  mapMediaType,
  mapStatus,
  previousSeason,
  resolveRoute,
  searchKitsu,
  seasonFromMonth,
  seasonKitsu,
  stripHtml,
  toDate,
  toDuration,
  toScore,
  toScoreOutOfHundred,
}