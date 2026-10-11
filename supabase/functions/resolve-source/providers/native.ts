// ============================================================================
// native.ts - risoluzione AnimeUnity / AnimeWorld dentro la Edge Function
// ============================================================================
//
// Perche' esiste questo adapter
// -----------------------------
// Il resolver `generic_api` delega a un servizio esterno (uno scraper Express)
// raggiunto via `GENERIC_PROVIDER_ENDPOINT`. Quel servizio esponeva i due
// provider reali del catalogo — AnimeUnity e AnimeWorld — ma girando dietro a
// un tunnel effimero il suo indirizzo cambia a ogni riavvio, e quando cambia
// ogni risoluzione comincia a fallire con un DNS error. Le fonti del catalogo
// sono per il 99,9% AnimeUnity: la risoluzione non puo' dipendere da un tunnel.
//
// Qui la logica di estrazione (portata da `scraper/animeunity.js` e
// `scraper/animeworld.js`) vive dentro la funzione. Non ci sono servizi
// esterni, non ci sono segreti da aggiornare, e non c'e' niente che possa
// "scadere" al riavvio di una macchina.
//
// Copertura: un canonico AnimeUnity si risolve dal solo id nel path piu' il
// numero episodio dai metadati; un canonico AnimeWorld si risolve dalla pagina
// dell'episodio, con AnimeUnity come fallback per titolo.
// ============================================================================

import type { AnimeEpisodeMeta, ResolveRequest, ResolveResult, VideoResolver } from '../types.ts'

const ANIMEUNITY_BASE = 'https://www.animeunity.so'
const ANIMEWORLD_BASE = 'https://www.animeworld.ac'

const USER_AGENT =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

const SESSION_TTL_MS = 3 * 60 * 60 * 1000

/** Errore con uno stato HTTP, capito da `errorResponse` in index.ts. */
export class ProviderError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly code = 'provider_error',
  ) {
    super(message)
    this.name = 'ProviderError'
  }
}

function asSourceType(value: string | null | undefined): 'mp4' | 'hls' | 'iframe' {
  return value === 'mp4' || value === 'hls' || value === 'iframe' ? value : 'hls'
}

// ---------------------------------------------------------------------------
// Sessione AnimeUnity (CSRF Laravel)
// ---------------------------------------------------------------------------
//
// AnimeUnity e' un'app Laravel: le API rispondono 419 senza il token
// `XSRF-TOKEN` (URL-decodificato) e i cookie della home. La sessione si ricompra
// quando il server smette di accettarla.

interface AuSession {
  cookie: string
  token: string
  expiresAt: number
}

let auSession: AuSession = { cookie: '', token: '', expiresAt: 0 }
let auSearchSession = { cookieAll: '', xsrfToken: '', expiresAt: 0 }

function auHeaders(session: AuSession): Record<string, string> {
  return {
    'user-agent': USER_AGENT,
    accept: 'application/json',
    'x-requested-with': 'XMLHttpRequest',
    'x-xsrf-token': session.token,
    ...(session.cookie ? { cookie: session.cookie } : {}),
  }
}

async function auGetSession(): Promise<AuSession> {
  if (Date.now() < auSession.expiresAt && auSession.cookie) return auSession

  const response = await fetch(`${ANIMEUNITY_BASE}/`, {
    headers: { 'user-agent': USER_AGENT, accept: 'text/html' },
    redirect: 'follow',
    signal: AbortSignal.timeout(15000),
  })
  if (!response.ok) {
    throw new ProviderError(502, `AnimeUnity ha risposto HTTP ${response.status}.`)
  }

  const rawCookies = response.headers.getSetCookie?.() ?? []
  const setCookie = response.headers.get('set-cookie') ?? ''
  const xsrfMatch =
    rawCookies.map((c) => /XSRF-TOKEN=([^;]+)/.exec(c)).find(Boolean) ||
    /XSRF-TOKEN=([^;]+)/.exec(setCookie)

  const cookie = setCookie.split(';')[0] || ''
  const token = xsrfMatch ? decodeURIComponent(xsrfMatch[1]) : auSession.token

  if (!token) {
    throw new ProviderError(502, 'AnimeUnity non ha rilasciato il token CSRF.')
  }

  auSession = { cookie, token, expiresAt: Date.now() + SESSION_TTL_MS }
  return auSession
}

async function auApiJson(
  url: string,
  headers: Record<string, string>,
  referer?: string,
): Promise<any> {
  const response = await fetch(url, {
    headers: { ...headers, ...(referer ? { referer } : {}) },
    redirect: 'follow',
    signal: AbortSignal.timeout(15000),
  })

  if (response.status === 419) {
    auSession = { cookie: '', token: '', expiresAt: 0 }
    const fresh = await auGetSession()
    return auApiJson(url, auHeaders(fresh), referer)
  }

  if (!response.ok) {
    throw new ProviderError(502, `AnimeUnity ha risposto HTTP ${response.status}.`)
  }

  try {
    return await response.json()
  } catch {
    throw new ProviderError(502, 'AnimeUnity ha risposto con dati non JSON.')
  }
}

// ---------------------------------------------------------------------------
// Estrazione AnimeUnity
// ---------------------------------------------------------------------------

/** Il master m3u8: sceglie la rendition richiesta o la migliore disponibile. */
async function auPickRendition(playlistUrl: string, requestedQuality: string): Promise<string> {
  const response = await fetch(playlistUrl, {
    headers: { 'user-agent': USER_AGENT, referer: `${ANIMEUNITY_BASE}/` },
    redirect: 'follow',
    signal: AbortSignal.timeout(15000),
  })
  if (!response.ok) {
    throw new ProviderError(502, `Playlist AnimeUnity HTTP ${response.status}.`)
  }

  const text = await response.text()
  const variants: Array<{ url: string; bandwidth: number; height: number }> = []
  let current: { bandwidth: number; height: number } | null = null

  for (const line of text.split(/\r?\n/)) {
    const inf = /#EXT-X-STREAM-INF:([^\n]*)/.exec(line)
    if (inf) {
      current = {
        bandwidth: Number(/BANDWIDTH=(\d+)/.exec(inf[1])?.[1]) || 0,
        height: Number(/RESOLUTION=(\d+)x(\d+)/.exec(inf[1])?.[2]) || 0,
      }
      continue
    }
    if (current && /^https?:\/\//.test(line)) {
      variants.push({ url: line, ...current })
      current = null
    }
  }

  const wanted =
    requestedQuality === '720p' ? 720 :
      requestedQuality === '480p' ? 480 :
        requestedQuality === '360p' ? 360 : 1080

  if (variants.length === 0) {
    throw new ProviderError(502, 'Playlist AnimeUnity senza rendition utilizzabile.')
  }

  const byHeight = variants
    .filter((v) => v.height > 0 && v.height <= wanted)
    .sort((a, b) => b.height - a.height)
  const best = variants.slice().sort((a, b) => b.bandwidth - a.bandwidth)[0]

  return (byHeight[0] ?? variants.find((v) => v.height === wanted) ?? best).url
}

/** Legge `window.masterPlaylist` dalla pagina embed e ne ricava l'URL playlist. */
function auParseEmbedUrl(html: string): { playlistUrl: string; expiresAt?: string } {
  const start = html.indexOf('window.masterPlaylist')
  const open = start < 0 ? -1 : html.indexOf('{', start)
  if (open < 0) {
    throw new ProviderError(502, 'Player AnimeUnity senza playlist.')
  }

  let depth = 0
  let end = -1
  for (let i = open; i < html.length; i += 1) {
    const ch = html[i]
    if (ch === '{') depth += 1
    else if (ch === '}') {
      depth -= 1
      if (depth === 0) {
        end = i + 1
        break
      }
    }
  }
  if (end < 0) {
    throw new ProviderError(502, 'Player AnimeUnity senza playlist.')
  }

  const raw = html.slice(open, end)
  // Alcuni campi non sono JSON valido: chiavi non quotate e trailing comma.
  const normalized = raw
    .replace(/([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:/g, '$1"$2":')
    .replace(/,\s*}/g, '}')
    .replace(/,\s*]/g, ']')
    .replace(/'/g, '"')

  let config: any
  try {
    config = JSON.parse(normalized)
  } catch {
    throw new ProviderError(502, 'Player AnimeUnity con playlist illeggibile.')
  }

  const base = typeof config.url === 'string' ? config.url : ''
  const params = config.params ?? {}
  if (!base) {
    throw new ProviderError(502, 'Player AnimeUnity senza URL playlist.')
  }

  const url = new URL(base)
  for (const [key, value] of Object.entries(params)) {
    if (value) url.searchParams.set(key, String(value))
  }
  url.searchParams.set('h', '1')
  const expiresAt = typeof params.expires === 'number' ? String(params.expires) : config.expires
  return { playlistUrl: url.toString(), expiresAt: typeof expiresAt === 'string' ? expiresAt : undefined }
}

/** Estrae un episodio di AnimeUnity dato l'id anime e il numero episodio. */
async function auExtractByAnimeId(
  animeId: number,
  episodeNumber: number,
  quality: string,
): Promise<ResolveResult> {
  const session = await auGetSession()

  const infoUrl = new URL(`/info_api/${animeId}/${episodeNumber}`, ANIMEUNITY_BASE)
  infoUrl.searchParams.set('start_range', String(episodeNumber))
  infoUrl.searchParams.set('end_range', String(episodeNumber))

  const info = await auApiJson(infoUrl.toString(), auHeaders(session))
  const episodes = Array.isArray(info.episodes) ? info.episodes : []
  const wanted =
    episodes.find((e: any) => String(e.number) === String(episodeNumber)) ?? episodes[0]

  if (!wanted?.id) {
    throw new ProviderError(404, `Episodio ${episodeNumber} non disponibile su AnimeUnity.`)
  }

  const animePage = `${ANIMEUNITY_BASE}/anime/${wanted.id}-x`
  const embedResponse = await fetch(`${ANIMEUNITY_BASE}/embed-url/${wanted.id}`, {
    headers: { ...auHeaders(session), accept: 'text/plain', referer: animePage },
    redirect: 'follow',
    signal: AbortSignal.timeout(15000),
  })
  if (!embedResponse.ok) {
    throw new ProviderError(502, `Embed AnimeUnity HTTP ${embedResponse.status}.`)
  }
  const embedUrl = (await embedResponse.text()).trim()
  if (!/^https:\/\//.test(embedUrl)) {
    throw new ProviderError(502, 'Embed AnimeUnity senza URL.')
  }

  const pageResponse = await fetch(embedUrl, {
    headers: { 'user-agent': USER_AGENT, accept: 'text/html', referer: `${ANIMEUNITY_BASE}/` },
    redirect: 'follow',
    signal: AbortSignal.timeout(15000),
  })
  if (!pageResponse.ok) {
    throw new ProviderError(502, `Player AnimeUnity HTTP ${pageResponse.status}.`)
  }

  const { playlistUrl, expiresAt } = auParseEmbedUrl(await pageResponse.text())
  const hlsUrl = await auPickRendition(playlistUrl, requestedQualitySafe(quality))

  return {
    resolvedUrl: hlsUrl,
    headers: { Referer: 'https://vixcloud.co/', Origin: 'https://vixcloud.co' },
    sourceType: 'hls',
    expiresAt,
  }
}

function requestedQualitySafe(quality: string | null | undefined): string {
  return typeof quality === 'string' && quality !== '' ? quality : '1080p'
}

function parseAnimeUnityId(canonicalUrl: string): { animeId: number; episode: number | null } | null {
  try {
    const url = new URL(canonicalUrl)
    const idMatch = /\/anime\/(\d+)/.exec(url.pathname)
    if (!idMatch) return null
    const epMatch = /\/anime\/\d+-[^/]+\/([0-9]+)/.exec(url.pathname)
    return { animeId: Number(idMatch[1]), episode: epMatch ? Number(epMatch[1]) : null }
  } catch {
    return null
  }
}

// ---------------------------------------------------------------------------
// Ricerca anime per titolo (fallback AnimeWorld -> AnimeUnity)
// ---------------------------------------------------------------------------

async function auGetSearchSession() {
  if (Date.now() < auSearchSession.expiresAt && auSearchSession.cookieAll) {
    return auSearchSession
  }
  const res = await fetch(`${ANIMEUNITY_BASE}/`, {
    headers: { 'user-agent': USER_AGENT, accept: 'text/html' },
    redirect: 'follow',
    signal: AbortSignal.timeout(15000),
  })
  if (!res.ok) {
    throw new ProviderError(502, `AnimeUnity ha risposto HTTP ${res.status}.`)
  }
  const rawCookies = res.headers.getSetCookie?.() ?? []
  const cookieAll = rawCookies.map((c) => c.split(';')[0]).join('; ')
  const xsrfRaw = rawCookies.map((c) => /XSRF-TOKEN=([^;]+)/.exec(c)?.[1]).find(Boolean)
  if (!cookieAll || !xsrfRaw) {
    throw new ProviderError(502, 'AnimeUnity non ha rilasciato i cookie per la ricerca.')
  }
  auSearchSession = {
    cookieAll,
    xsrfToken: decodeURIComponent(xsrfRaw),
    expiresAt: Date.now() + SESSION_TTL_MS,
  }
  return auSearchSession
}

async function auLiveSearch(query: string): Promise<any[]> {
  const search = await auGetSearchSession()
  const response = await fetch(`${ANIMEUNITY_BASE}/livesearch`, {
    method: 'POST',
    headers: {
      'user-agent': USER_AGENT,
      accept: 'application/json',
      'x-requested-with': 'XMLHttpRequest',
      'x-xsrf-token': search.xsrfToken,
      cookie: search.cookieAll,
      'content-type': 'application/json',
    },
    body: JSON.stringify({ title: query }),
    redirect: 'follow',
    signal: AbortSignal.timeout(15000),
  })
  if (!response.ok) {
    throw new ProviderError(502, `Ricerca AnimeUnity HTTP ${response.status}.`)
  }
  const data = await response.json()
  return Array.isArray(data.records) ? data.records : []
}

function slugify(value: string): string {
  return value
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .replace(/-{2,}/g, '-')
}

function dice(a: string, b: string): number {
  const ta = (a || '').split(' ').filter(Boolean)
  const tb = (b || '').split(' ').filter(Boolean)
  if (!ta.length || !tb.length) return 0
  const setB = new Set(tb)
  let inter = 0
  for (const w of ta) if (setB.has(w)) inter += 1
  return (2 * inter) / (ta.length + tb.length)
}

/** Ritrova l'id AnimeUnity di un anime per mal_id esatto o per titolo. */
async function findAnimeUnityId(meta: AnimeEpisodeMeta): Promise<number> {
  const candidates = [meta.title, meta.japaneseTitle, ...meta.synonyms].filter(
    (v): v is string => typeof v === 'string' && v.trim() !== '',
  )
  if (candidates.length === 0) {
    throw new ProviderError(422, "Servono i titoli dell'anime per il fallback.")
  }

  let bestId: number | null = null
  let bestScore = 0

  for (const candidate of candidates.slice(0, 6)) {
    let records: any[]
    try {
      records = await auLiveSearch(candidate)
    } catch {
      continue
    }

    for (const record of records) {
      if (!record?.id) continue
      if (meta.malId !== null && Number(record.mal_id) === meta.malId) {
        return Number(record.id)
      }
      const titles = [record.title, record.title_it, record.title_eng, record.slug]
        .filter((t: unknown): t is string => typeof t === 'string')
      for (const t of titles) {
        const score = dice(slugify(t), slugify(candidate))
        if (score >= 0.75 && score > bestScore) {
          bestScore = score
          bestId = Number(record.id)
        }
      }
    }
    if (bestId !== null && bestScore >= 0.95) break
  }

  if (bestId === null) {
    throw new ProviderError(404, 'Anime non ritrovato su AnimeUnity.')
  }
  return bestId
}

// ---------------------------------------------------------------------------
// Estrazione AnimeWorld (regex, senza cheerio)
// ---------------------------------------------------------------------------

let awSession = { cookie: '', expiresAt: 0 }

async function awGetSession() {
  if (Date.now() < awSession.expiresAt && awSession.cookie) return awSession
  const response = await fetch(`${ANIMEWORLD_BASE}/`, {
    headers: { 'user-agent': USER_AGENT, accept: 'text/html' },
    redirect: 'follow',
    signal: AbortSignal.timeout(15000),
  })
  if (!response.ok) {
    throw new ProviderError(502, `AnimeWorld ha risposto HTTP ${response.status}.`)
  }
  const rawCookies = response.headers.getSetCookie?.() ?? []
  const cookie = rawCookies.map((c) => c.split(';')[0]).join('; ')
  awSession = { cookie, expiresAt: Date.now() + SESSION_TTL_MS }
  return awSession
}

async function extractAnimeWorld(pageUrl: string, quality: string): Promise<ResolveResult> {
  const session = await awGetSession()
  const pageResponse = await fetch(pageUrl, {
    headers: {
      'user-agent': USER_AGENT,
      accept: 'text/html,application/xhtml+xml',
      'accept-language': 'it-IT,it;q=0.9',
      ...(session.cookie ? { cookie: session.cookie } : {}),
    },
    redirect: 'follow',
    signal: AbortSignal.timeout(20000),
  })
  if (!pageResponse.ok) {
    throw new ProviderError(502, `AnimeWorld ha risposto HTTP ${pageResponse.status}.`)
  }
  const html = await pageResponse.text()

  const playerTag = /<[^>]*id=["']?player["']?[^>]*>/i.exec(html)?.[0] ?? ''
  const dataId =
    /data-id=["']([^"']+)["']/i.exec(playerTag)?.[1] ??
    /data-id=["']([^"']+)["']/i.exec(html)?.[1] ??
    ''
  const csrf =
    /<meta[^>]*name=["']csrf-token["'][^>]*content=["']([^"']+)["']/i.exec(html)?.[1] ??
    ''

  if (!dataId) {
    throw new ProviderError(422, 'Nessun player nella pagina AnimeWorld.')
  }
  if (!csrf) {
    throw new ProviderError(502, 'Token CSRF assente nella pagina AnimeWorld.')
  }

  const origin = new URL(pageUrl).origin
  const infoUrl = new URL('/api/episode/info', origin)
  infoUrl.searchParams.set('id', dataId)
  infoUrl.searchParams.set('alt', '0')

  const infoResponse = await fetch(infoUrl.toString(), {
    headers: {
      'user-agent': USER_AGENT,
      accept: 'application/json',
      'csrf-token': csrf,
      referer: pageUrl,
      'x-requested-with': 'XMLHttpRequest',
    },
    redirect: 'follow',
    signal: AbortSignal.timeout(15000),
  })
  if (!infoResponse.ok) {
    throw new ProviderError(502, `API AnimeWorld ha risposto HTTP ${infoResponse.status}.`)
  }

  let info: any
  try {
    info = await infoResponse.json()
  } catch {
    throw new ProviderError(502, 'Risposta non JSON da AnimeWorld.')
  }

  const grabber = typeof info.grabber === 'string' ? info.grabber.trim() : ''
  if (!/^https?:\/\//.test(grabber)) {
    throw new ProviderError(502, 'AnimeWorld non ha restituito un URL video.')
  }

  return {
    resolvedUrl: grabber,
    headers: { Referer: `${origin}/`, Origin: origin },
    sourceType: asSourceType(quality === 'mp4' ? 'mp4' : 'mp4'),
  }
}

// ---------------------------------------------------------------------------
// Risoluzione lato client
// ---------------------------------------------------------------------------
//
// AnimeUnity sta dietro Cloudflare e risponde 403 a un indirizzo di datacenter:
// la Edge Function non puo' risolverla, qualunque cosa faccia. Il telefono,
// invece, ha un IP residenziale ed e' la stessa rete dell'utente, quindi la
// risoluzione va spostata sul client. Questa funzione dice soltanto *quali*
// fonti vanno risolte dal client; l'estrazione vera vive nel client Dart
// (`client/lib/features/episodes/data/animeunity_extractor.dart`).
//
// Il resto (AnimeWorld in primis) non e' bloccato e resta server-side, perche'
// li' il client non ci guadagna niente e la funzione e' piu' facile da
// aggiornare del parco app installato.

const CLIENT_EXTRACTION_HOSTS = ['animeunity.so', 'animeunity.to', 'animeunity.it']

/** true se questa fonte va risolta dal client e non dalla funzione. */
export function requiresClientExtraction(canonicalUrl: string): boolean {
  try {
    const host = new URL(canonicalUrl).hostname.toLowerCase()
    return CLIENT_EXTRACTION_HOSTS.some(
      (base) => host === base || host.endsWith(`.${base}`),
    )
  } catch {
    return false
  }
}

// ---------------------------------------------------------------------------
// Adapter
// ---------------------------------------------------------------------------

export const nativeResolver: VideoResolver = {
  endpoint: 'native',

  async resolve(request: ResolveRequest): Promise<ResolveResult> {
    const quality = requestedQualitySafe(request.source.quality)
    let host: string
    try {
      host = new URL(request.canonicalUrl).hostname.toLowerCase()
    } catch {
      throw new ProviderError(422, "L'indirizzo canonico della fonte non e' valido.")
    }

    if (host.endsWith('animeunity.so') || host.endsWith('animeunity.to')) {
      const parsed = parseAnimeUnityId(request.canonicalUrl)
      if (!parsed) {
        throw new ProviderError(422, `Canonico AnimeUnity non riconosciuto: ${request.canonicalUrl}.`)
      }
      const episode = request.anime?.episodeNumber ?? parsed.episode
      if (!Number.isInteger(episode) || (episode ?? 0) < 1) {
        throw new ProviderError(422, 'Serve il numero episodio per risolvere una fonte AnimeUnity.')
      }
      return await auExtractByAnimeId(parsed.animeId, episode as number, quality)
    }

    if (host.endsWith('animeworld.ac') || host.endsWith('animeworld.')) {
      try {
        return await extractAnimeWorld(request.canonicalUrl, quality)
      } catch (primaryError) {
        const meta = request.anime
        if (!meta?.episodeNumber || (meta.title === null && meta.synonyms.length === 0)) {
          throw primaryError
        }
        const animeId = await findAnimeUnityId(meta)
        return await auExtractByAnimeId(animeId, meta.episodeNumber, quality)
      }
    }

    throw new ProviderError(422, `Host non gestito: ${host}.`)
  },
}