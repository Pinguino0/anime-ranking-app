// ============================================================================
// anime-intro - dove sta la sigla di un episodio (AniSkip)
// ============================================================================
//
// Il buco che questa funzione riempie
// -----------------------------------
// Il player ha un pulsante "Salta intro", ma il catalogo non sa dove sia la
// sigla. In precedenza c'era un valore unico per serie (`anime.intro_start_seconds`
// / `intro_end_seconds`), riempito con 0 e 90 su tutte le TV: un intervallo
// inventato, che il piu' delle volte cade dentro l'episodio e non dentro la
// sigla. La sigla, invece, cambia da episodio a episodio — la prima puntata
// spesso non ce l'ha, e una serie puo' cambiarla a meta' stagione.
//
// Il dato vero sta in AniSkip (https://aniskip.com), un database pubblico di
// intervalli "salta sigla / salta sigla finale" contribuito dagli utenti. AniSkip
// si identifica con l'id MyAnimeList, che il nostro catalogo non ha quasi mai:
// le voci arrivano da AniList e Kitsu.
//
// Perche' una Edge Function e non una lettura dal client
// -----------------------------------------------------
// Tre ragioni:
//
//   1. La chiave MyAnimeList va ricavata interrogando AniList, e la tabella
//      `anime` non e' scrivibile da `authenticated` (solo `service_role`).
//      Questa funzione gira con la service key ed e' l'unico posto legittimo
//      per conservare `mal_id`.
//   2. AniSkip e AniList sono servizi condivisi fra tutti gli utenti dello
//      stesso progetto: un client che li chiama a piacere consuma la quota per
//      tutti. Qui c'e' una cache (`episode_intro`) che assorbe le ripetizioni.
//   3. Il telefono non deve portarsi dietro la logica di risoluzione
//      dell'id: la fa una volta il server, e la conserva.
//
// Flusso di una richiesta:
//   1. corpo `{ anime_id, episode }`
//   2. cache `episode_intro` per (anime, episodio): se c'e', risponde subito
//   3. altrimenti risolve `mal_id` (colonna `anime.mal_id`, poi `external_data`,
//      poi AniList), lo conserva, e chiede i tempi ad AniSkip
//   4. scrive la finestra in cache e risponde
//
// Nessuna credenziale esterna: AniList e AniSkip si interrogano senza chiave.
// L'unico segreto e' la service key, che Supabase inietta e non finisce mai nel
// codice.
// ============================================================================

import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

// `any` per lo stesso motivo di `jikan-proxy`: il progetto non genera i tipi
// del database, e senza un tipo esplicito PostgREST non e' interrogabile.
type SupabaseAny = SupabaseClient<any>

let supabaseClient: SupabaseAny | null = null

// Costruito alla prima richiesta e non all'import: cosi' i test possono
// importare le funzioni pure senza che manchino le variabili d'ambiente (che
// esistono solo dentro Supabase).
function db(): SupabaseAny {
  if (supabaseClient) return supabaseClient
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    throw new Error('SUPABASE_URL o SUPABASE_SERVICE_ROLE_KEY mancanti.')
  }
  supabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  }) as SupabaseAny
  return supabaseClient
}

const ANILIST_ENDPOINT = 'https://graphql.anilist.co'
const ANISKIP_ENDPOINT = 'https://api.aniskip.com/v2/skip-times'

// Budget per una singola richiesta a monte. Senza, un upstream lento tiene la
// funzione appesa fino al gateway e l'utente resta senza pulsante senza capire
// perche'. Otto secondi sono abbondanti per entrambi i servizi.
const FETCH_TIMEOUT_MS = 8_000

// Durata di un episodio quando non si sa. AniSkip usa `episodeLength` per
// distinguere la sigla di una puntata normale da quella di uno speciale piu'
// lungo o piu' corto; 24 minuti sono la misura normale di una serie TV.
const DEFAULT_EPISODE_LENGTH = 1_440

// ---------------------------------------------------------------------------
// Utili
// ---------------------------------------------------------------------------

interface FetchResult {
  status: number
  body: string
}

class HttpError extends Error {
  constructor(readonly status: number, message: string) {
    super(message)
  }
}

async function fetchText(url: string, init?: RequestInit): Promise<FetchResult> {
  let response: Response
  try {
    response = await fetch(url, { ...init, signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) })
  } catch (error) {
    if (error instanceof Error && error.name === 'TimeoutError') {
      throw new HttpError(504, 'Il servizio non ha risposto in tempo.')
    }
    throw new HttpError(502, 'Il servizio non e\' raggiungibile.')
  }
  return { status: response.status, body: await response.text() }
}

function toObject(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' ? (value as Record<string, unknown>) : {}
}

function toPositiveInt(value: unknown): number | null {
  const raw = typeof value === 'number' ? value : typeof value === 'string' ? Number.parseInt(value, 10) : NaN
  return Number.isFinite(raw) && raw > 0 ? Math.trunc(raw) : null
}

function toFiniteNumber(value: unknown): number | null {
  const raw = typeof value === 'number' ? value : typeof value === 'string' ? Number.parseFloat(value) : NaN
  return Number.isFinite(raw) ? raw : null
}

// ---------------------------------------------------------------------------
// Lettura della risposta di AniSkip
// ---------------------------------------------------------------------------

export interface IntroWindow {
  start: number
  end: number
}

// `https://api.aniskip.com/v2/skip-times/{mal}/{ep}?types[]=op&episodeLength=...`
//
// `episodeLength` non e' opzionale: senza, AniSkip risponde 400. Va anche
// positiva: uno zero viene rifiutato allo stesso modo.
export function aniskipUrl(malId: number, episode: number, episodeLength: number): string {
  const url = new URL(`${ANISKIP_ENDPOINT}/${malId}/${episode}`)
  url.searchParams.append('types[]', 'op')
  url.searchParams.set('episodeLength', String(episodeLength))
  return url.toString()
}

// Estrae l'intervallo della sigla dalla risposta di AniSkip.
//
// Restituisce `null` per "non c'e'": sia quando AniSkip dice di non avere dati
// (`found: false`, 404), sia quando la risposta ha la forma sbagliata. In
// entrambi i casi il player non mostra il pulsante, che e' la risposta giusta.
export function parseSkipTimes(payload: unknown): IntroWindow | null {
  const entry = toObject(payload)
  if (entry.found !== true) return null

  const results = Array.isArray(entry.results) ? entry.results : []
  for (const raw of results) {
    const result = toObject(raw)
    // Solo la sigla di testa (`op`). "Salta sigla finale" (`ed`) e' un altro
    // pulsante che non esiste ancora: mescolarli taglierebbe il pezzo sbagliato.
    if (result.skipType !== 'op') continue

    const interval = toObject(result.interval)
    const start = toFiniteNumber(interval.startTime)
    const end = toFiniteNumber(interval.endTime)
    if (start === null || end === null || end <= start) continue

    return { start: Math.round(start), end: Math.round(end) }
  }
  return null
}

// La durata dell'episodio, in secondi, per AniSkip.
//
// Il catalogo la tiene in `anime.external_data.episodes_length`, in minuti, per
// le voci agganciate ad AnimeUnity. Per tutte le altre non c'e', e si usa la
// misura normale. Una durata fuori scala (mezzo secondo) e' un dato sporco, non
// una puntata: si preferisce il default.
export function episodeLengthSeconds(externalData: unknown): number {
  const raw = toFiniteNumber(toObject(externalData).episodes_length)
  if (raw === null) return DEFAULT_EPISODE_LENGTH
  const seconds = Math.round(raw * 60)
  return seconds >= 60 ? seconds : DEFAULT_EPISODE_LENGTH
}

// ---------------------------------------------------------------------------
// Risoluzione dell'id MyAnimeList
// ---------------------------------------------------------------------------

async function anilistMalId(anilistId: number): Promise<number | null> {
  const result = await fetchText(ANILIST_ENDPOINT, {
    method: 'POST',
    headers: { 'content-type': 'application/json', accept: 'application/json' },
    body: JSON.stringify({
      query: 'query($id: Int) { Media(id: $id) { idMal } }',
      variables: { id: anilistId },
    }),
  })
  if (result.status !== 200) return null

  const decoded = toObject(JSON.parse(result.body) as unknown)
  // AniList risponde 200 anche alle query sbagliate, con `errors`: senza questo
  // controllo un id non trovato sembrerebbe una voce senza MAL.
  if (Array.isArray(decoded.errors) && decoded.errors.length > 0) return null
  return toPositiveInt(toObject(decoded.data).Media ? toObject(toObject(decoded.data).Media).idMal : null)
}

// L'id MyAnimeList di una voce, da dove capita di averlo.
//
// Ordine: la colonna (gia' risolta in passato), il record grezzo di AniList o
// AnimeUnity, e infine AniList. Si conserva sulla riga per non doverlo
// ricalcolare. `null` vuol dire "non lo sappiamo": il player non mostra il
// pulsante, che e' meglio di un id sbagliato.
async function resolveMalId(anime: Record<string, unknown>): Promise<number | null> {
  const stored = toPositiveInt(anime.mal_id)
  if (stored !== null) return stored

  const external = toObject(anime.external_data)
  const fromData = toPositiveInt(external.mal_id) ?? toPositiveInt(external.idMal)

  let malId = fromData
  if (malId === null && anime.external_source === 'anilist') {
    const anilistId = toPositiveInt(anime.external_id)
    if (anilistId !== null) malId = await anilistMalId(anilistId)
  }

  if (malId !== null) await storeMalId(anime.id, malId)
  return malId
}

async function storeMalId(animeId: unknown, malId: number): Promise<void> {
  try {
    await db().from('anime').update({ mal_id: malId }).eq('id', animeId)
  } catch (error) {
    // L'id e' ricavabile di nuovo: non riuscire a conservarlo allunga la
    // prossima richiesta, non la rompe.
    console.warn('anime-intro: mal_id non conservato', String(error))
  }
}

// ---------------------------------------------------------------------------
// Cache
// ---------------------------------------------------------------------------

interface CachedIntro {
  start_seconds: number
  end_seconds: number
  source: string
}

async function readAnime(animeId: string): Promise<Record<string, unknown> | null> {
  try {
    const { data, error } = await db()
      .from('anime')
      .select('id, external_id, external_source, external_data, mal_id')
      .eq('id', animeId)
      .maybeSingle()
    if (error || !data) return null
    return toObject(data)
  } catch (error) {
    console.warn('anime-intro: anime non leggibile', String(error))
    return null
  }
}

async function readCache(animeId: string, episode: number): Promise<CachedIntro | null> {
  try {
    const { data, error } = await db()
      .from('episode_intro')
      .select('start_seconds, end_seconds, source')
      .eq('anime_id', animeId)
      .eq('episode_number', episode)
      .maybeSingle()
    if (error || !data) return null
    return data as CachedIntro
  } catch (error) {
    console.warn('anime-intro: cache non leggibile', String(error))
    return null
  }
}

async function writeCache(animeId: string, episode: number, window: IntroWindow): Promise<void> {
  try {
    const { error } = await db().from('episode_intro').upsert(
      {
        anime_id: animeId,
        episode_number: episode,
        start_seconds: window.start,
        end_seconds: window.end,
        source: 'aniskip',
        fetched_at: new Date().toISOString(),
      },
      { onConflict: 'anime_id,episode_number' },
    )
    if (error) console.warn('anime-intro: cache non scritta', error.message)
  } catch (error) {
    console.warn('anime-intro: cache non scrivibile', String(error))
  }
}

// ---------------------------------------------------------------------------
// Azione
// ---------------------------------------------------------------------------

async function fetchAniskip(malId: number, episode: number, episodeLength: number): Promise<IntroWindow | null> {
  const result = await fetchText(aniskipUrl(malId, episode, episodeLength), {
    headers: { accept: 'application/json' },
  })
  // 404 e' la risposta normale di AniSkip per "per questo episodio non ho
  // niente": non e' un errore.
  if (result.status === 404) return null
  if (result.status !== 200) {
    throw new HttpError(502, `AniSkip ha risposto ${result.status}.`)
  }
  return parseSkipTimes(JSON.parse(result.body) as unknown)
}

async function introFor(animeId: string, episode: number): Promise<Record<string, unknown>> {
  const cached = await readCache(animeId, episode)
  if (cached) {
    return { found: true, start: cached.start_seconds, end: cached.end_seconds, source: cached.source }
  }

  const anime = await readAnime(animeId)
  if (!anime) return { found: false, reason: 'anime_not_found' }

  const malId = await resolveMalId(anime)
  if (malId === null) return { found: false, reason: 'no_mal_id' }

  const length = episodeLengthSeconds(anime.external_data)
  const window = await fetchAniskip(malId, episode, length)
  if (window === null) return { found: false, reason: 'aniskip_no_data' }

  await writeCache(animeId, episode, window)
  return { found: true, start: window.start, end: window.end, source: 'aniskip' }
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
    },
  })
}

function withCors(response: Response): Response {
  for (const [key, value] of Object.entries(CORS_HEADERS)) {
    response.headers.set(key, value)
  }
  return response
}

// Handler esportato per i test. `Deno.serve` sta in fondo e parte solo quando
// il file e' il punto d'ingresso, cosi' `deno test` non apre porte.
export async function handleRequest(request: Request): Promise<Response> {
  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS })
  }
  if (request.method !== 'POST') {
    return withCors(json({ error: 'Solo POST.', code: 'method_not_allowed' }, 405))
  }

  let payload: Record<string, unknown>
  try {
    payload = toObject(await request.json() as unknown)
  } catch {
    return withCors(json({ error: 'Corpo JSON non valido.', code: 'bad_request' }, 400))
  }

  const animeId = typeof payload.anime_id === 'string' && payload.anime_id.trim() !== ''
    ? payload.anime_id.trim()
    : null
  const episode = toPositiveInt(payload.episode)

  if (animeId === null || episode === null) {
    return withCors(json({ error: 'anime_id ed episode sono obbligatori.', code: 'bad_request' }, 400))
  }

  try {
    return withCors(json(await introFor(animeId, episode)))
  } catch (error) {
    // La sigla e' un di piu': un guasto a monte non e' un errore da mostrare.
    // Si risponde "non trovata" e si annota nei log; il player funziona lo
    // stesso, senza il pulsante.
    console.error('anime-intro: errore', error)
    return withCors(json({ found: false, reason: 'upstream_error' }))
  }
}

if (import.meta.main) {
  Deno.serve(handleRequest)
}
