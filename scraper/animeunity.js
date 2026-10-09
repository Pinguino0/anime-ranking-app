const BASE_URL = 'https://www.animeunity.so'

const fs = require('fs')
const path = require('path')

const USER_AGENT =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

class ProviderError extends Error {
  constructor(status, message) {
    super(message)
    this.status = status
  }
}

// ---------------------------------------------------------------------------
// Sessione (CSRF) e indice della sitemap
// ---------------------------------------------------------------------------
//
// AnimeUnity e' un'app Laravel con CSRF: le API rispondono 419 senza il
// token `XSRF-TOKEN` (che per Laravel va URL-decodato prima di metterlo
// nell'header). Il token si ottiene dalla home e vale per la sessione:
// lo si ricompra quando il server smette di accettarlo.
//
// La sitemap (7.241 anime) e' l'indice con cui ritrovare l'id interno di
// un titolo: gli slug di AnimeUnity derivano dal titolo inglese, che non e'
// mai il romaji, quindi il match passa dai `synonyms` del catalogo.

let sessionCache = { expiresAt: 0 }
let sitemapCache = { slugs: null, expiresAt: 0 }
// Sessione dedicata al POST /livesearch: come le API richiede il token ma,
// essendo una POST, Laravel valida CSRF e pretende TUTTI i cookie della home
// (XSRF-TOKEN + animeunity_session): il getSession() di servizio prende solo il
// primo set-cookie e non basta. La sessione si ricompra quando scade.
let searchCache = { cookieAll: '', xsrfToken: '', expiresAt: 0 }

const SITEMAP_TTL_MS = 12 * 60 * 60 * 1000
const SESSION_TTL_MS = 3 * 60 * 60 * 1000

async function getSession() {
  if (Date.now() < sessionCache.expiresAt && sessionCache.cookie) {
    return sessionCache
  }

  const response = await fetch(`${BASE_URL}/`, {
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
    rawCookies
      .map((c) => /XSRF-TOKEN=([^;]+)/.exec(c))
      .find(Boolean) ||
    /XSRF-TOKEN=([^;]+)/.exec(setCookie)

  const cookie = response.headers.get('set-cookie')?.split(';')[0] || ''

  // Laravel decodifica l'header X-XSRF-TOKEN prima di confrontarlo: il valore
  // del cookie (URL-encoded, con `%3D` al posto di `=`) va decodificato.
  const token = xsrfMatch ? decodeURIComponent(xsrfMatch[1]) : sessionCache.token

  if (!token) {
    throw new ProviderError(502, 'AnimeUnity non ha rilasciato il token CSRF.')
  }

  sessionCache = { cookie, token, expiresAt: Date.now() + SESSION_TTL_MS }
  return sessionCache
}

function apiHeaders(session) {
  return {
    'user-agent': USER_AGENT,
    accept: 'application/json',
    'x-requested-with': 'XMLHttpRequest',
    'x-xsrf-token': session.token,
    ...(session.cookie ? { cookie: session.cookie } : {}),
  }
}

async function apiJson(url, headers, referer) {
  const response = await fetch(url, {
    headers: { ...headers, ...(referer ? { referer } : {}) },
    redirect: 'follow',
    signal: AbortSignal.timeout(15000),
  })

  if (response.status === 419) {
    // Token scaduto dall'altra parte: si rifà la sessione e si riprova una
    // volta sola. Il secondo tentativo usa la sessione fresca.
    sessionCache = { expiresAt: 0, cookie: '', token: '' }
    const fresh = await getSession()
    return apiJson(url, apiHeaders(fresh), referer)
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
// Ricerca di catalogo: POST /livesearch
// ---------------------------------------------------------------------------
//
// La ricerca per titolo serve a trovare l'id anime quando lo slug non lo lascia
// riconoscere (i titoli italiani, come JoJo) e per il sync del catalogo. I
// records rispondono con `anilist_id`/`mal_id`, quindi il match è esatto.
//
// Il token CSRF viaggia cifrato: in header va il valore COME SCRITTO nel
// cookie ma URL-decodificato (Laravel lo decifra a sua volta).

async function getSearchSession() {
  if (Date.now() < searchCache.expiresAt && searchCache.cookieAll) {
    return searchCache
  }
  const res = await fetch(`${BASE_URL}/`, {
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
  searchCache = {
    cookieAll,
    xsrfToken: decodeURIComponent(xsrfRaw),
    expiresAt: Date.now() + SESSION_TTL_MS,
  }
  return searchCache
}

/** Cerca per titolo e restituisce i records AnimeUnity (max 8 per query). */
async function liveSearch(query) {
  const trySearch = async () => {
    const search = await getSearchSession()
    const response = await fetch(`${BASE_URL}/livesearch`, {
      method: 'POST',
      headers: {
        ...apiHeaders(sessionCache),
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

  try {
    return await trySearch()
  } catch (e) {
    // Sessione scaduta o 'x-xsrf-token' non riconosciuto: un solo retry pulendo
    // la cache di ricerca e quella di servizio.
    if (e instanceof ProviderError && [419, 502].includes(e.status)) {
      searchCache = { cookieAll: '', xsrfToken: '', expiresAt: 0 }
      sessionCache = { expiresAt: 0, cookie: '', token: '' }
      return trySearch()
    }
    throw e
  }
}

async function getSitemap() {
  if (sitemapCache.slugs && Date.now() < sitemapCache.expiresAt) {
    return sitemapCache.slugs
  }

  // Snapshot su disco: la sitemap a volte arriva troncata o venga servita da
  // cache parziale; una copia locale rende il matching deterministico e
  // riproducibile senza dipendere dalla stabilita' del server.
  const diskCachePath = path.join(__dirname, '.au-sitemap.json')

  const load = (obj) => {
    const slugs = new Map()
    for (const [k, v] of Object.entries(obj)) slugs.set(k, Number(v))
    if (slugs.size > 0) return slugs
    return null
  }

  const fromDisk = () => {
    try {
      const parsed = JSON.parse(fs.readFileSync(diskCachePath, 'utf8'))
      return load(parsed)
    } catch {
      return null
    }
  }

  let slugs = null
  for (let attempt = 1; attempt <= 3 && !slugs; attempt += 1) {
    const response = await fetch(`${BASE_URL}/sitemap.xml`, {
      headers: { 'user-agent': USER_AGENT },
      redirect: 'follow',
      signal: AbortSignal.timeout(30000),
    })
    if (!response.ok) {
      if (attempt === 3) break
      await new Promise((r) => setTimeout(r, 500 * attempt))
      continue
    }

    const xml = await response.text()
    const parsed = new Map()
    const ANIME_RE = /\/anime\/(\d+)-([a-z0-9-]+)/g
    for (const match of xml.matchAll(ANIME_RE)) {
      parsed.set(match[2], Number(match[1]))
    }
    if (parsed.size > 0) {
      slugs = parsed
      try {
        fs.writeFileSync(diskCachePath, JSON.stringify(Object.fromEntries(parsed)), 'utf8')
      } catch {
        // la cache su disco e' solo un'accelerazione: non blocca il flusso
      }
    }
  }

  if (!slugs) {
    const stale = fromDisk()
    if (stale) {
      console.warn('[animeunity] sitemap non raggiungibile, uso snapshot su disco')
      slugs = stale
    } else {
      throw new ProviderError(502, 'Sitemap AnimeUnity non disponibile.')
    }
  }

  sitemapCache = { slugs, expiresAt: Date.now() + SITEMAP_TTL_MS }
  return slugs
}

// ---------------------------------------------------------------------------
// Trova l'id anime
// ---------------------------------------------------------------------------

function slugify(value) {
  return String(value)
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '') // toglie gli accenti
    .toLowerCase()
    .replace(/’/g, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .replace(/-{2,}/g, '-')
}

function titleCandidates(meta) {
  const out = []
  const push = (v) => {
    if (typeof v !== 'string' || v.trim() === '') return
    const s = slugify(v)
    if (s && !out.includes(s)) out.push(s)
  }

  push(meta.title)
  push(meta.japaneseTitle)
  for (const synonym of meta.synonyms ?? []) push(synonym)
  return out
}

/** Uno slug di AnimeUnity: toglie " the " ai prefissi che non sono inglesi. */
function scoreSlug(candidate, slug) {
  const c = candidate.split('-').filter(Boolean)
  const s = slug.split('-').filter(Boolean)
  if (c.length === 0) return 0

  let hits = 0
  for (const word of c) {
    if (s.includes(word)) hits += 1
  }
  return hits / c.length
}

async function findAnimeId(meta) {
  if (!meta || (meta.title === null && (meta.synonyms?.length ?? 0) === 0)) {
    throw new ProviderError(422, 'Servono i titoli dell\'anime per il fallback.')
  }

  const slugs = await getSitemap()
  const candidates = titleCandidates(meta)

  // Prima i candidati esatti: l'85% degli anime ha lo slug uguale al titolo
  // inglese normalizzato, e il primo match vince.
  for (const candidate of candidates) {
    const hit = slugs.get(candidate)
    if (hit) return hit
  }

  // Poi una scansione fuzzy: copre i casi in cui lo slug aggancia un suffisso
  // ("-ita" per il doppiaggio) o un numero di stagione. Si prende il miglior
  // punteggio solo se significativo (almeno meta' delle parole coincidono).
  let best = null
  let bestScore = 0.5
  for (const [slug, id] of slugs) {
    for (const candidate of candidates) {
      const score = scoreSlug(candidate, slug)
      if (score > bestScore) {
        best = { id, slug, score }
        bestScore = score
      }
    }
  }

  if (!best) {
    throw new ProviderError(404, 'Anime non trovato su AnimeUnity.')
  }
  return best.id
}

// ---------------------------------------------------------------------------
// Estrazione del video
// ---------------------------------------------------------------------------

function parseEmbedUrl(html) {
  const start = html.indexOf('window.masterPlaylist')
  if (start === -1) {
    throw new ProviderError(502, 'Player AnimeUnity senza playlist.')
  }

  const braceStart = html.indexOf('{', start)
  if (braceStart === -1) {
    throw new ProviderError(502, 'Player AnimeUnity senza playlist.')
  }

  // Bilanciamento delle graffe: l'oggetto contiene `params` annidato, quindi
  // un match "fino al primo };" si fermerebbe dentro i params.
  let depth = 0
  let end = braceStart
  for (; end < html.length; end += 1) {
    if (html[end] === '{') depth += 1
    else if (html[end] === '}') {
      depth -= 1
      if (depth === 0) {
        end += 1
        break
      }
    }
  }
  if (depth !== 0) {
    throw new ProviderError(502, 'Player AnimeUnity con playlist non leggibile.')
  }

  // Il blocco usa apici singoli, virgole finali e chiavi senza apici: non e'
  // JSON. I valori sono stringhe/numero/'' semplici, quindi normalizzare
  // apici, virgole finali e chiavi scoperte e' sicuro.
  let slice = html.slice(braceStart, end)
    .replace(/'/g, '"')
    .replace(/,\s*}/g, '}')
    .replace(/([{,]\s*)([a-zA-Z_$][a-zA-Z0-9_$]*)\s*:/g, '$1"$2":')

  let config
  try {
    config = JSON.parse(slice)
  } catch {
    throw new ProviderError(502, 'Player AnimeUnity con playlist non leggibile.')
  }

  const base = typeof config.url === 'string' ? config.url : ''
  const params = (config.params ?? {})
  if (!base) {
    throw new ProviderError(502, 'Player AnimeUnity senza URL playlist.')
  }

  const url = new URL(base)
  for (const [key, value] of Object.entries(params)) {
    if (value) url.searchParams.set(key, String(value))
  }
  url.searchParams.set('h', '1')
  return { playlistUrl: url.toString(), expiresAt: params.expires }
}

/** Dal master m3u8 sceglie la rendition migliore disponibile. */
async function pickRendition(playlistUrl, requestedQuality) {
  const response = await fetch(playlistUrl, {
    headers: { 'user-agent': USER_AGENT, referer: `${BASE_URL}/` },
    redirect: 'follow',
    signal: AbortSignal.timeout(15000),
  })
  if (!response.ok) {
    throw new ProviderError(502, `Playlist AnimeUnity HTTP ${response.status}.`)
  }

  const text = await response.text()
  const variants = []
  let current = null
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
        requestedQuality === '360p' ? 360 :
          1080

  // Preferisce la rendition piu' vicina al taglio richiesto senza sforarlo,
  // e se non c'e' prende la piu' alta disponibile.
  const exact = variants
    .filter((v) => v.height !== 0 && v.height <= wanted)
    .sort((a, b) => b.height - a.height)
  const pick = exact[0] ??
    variants.sort((a, b) => b.bandwidth - a.bandwidth)[0]

  if (!pick) {
    throw new ProviderError(502, 'Playlist AnimeUnity senza variant video.')
  }
  return pick.url
}

/**
 * Estrae l'episodio `episodeNumber` dell'anime `animeId`.
 *
 * La catena e':
 *   info_api      -> { id, scws_id } dell'episodio
 *   embed-url     -> l'embed vixcloud.co
 *   embed page    -> window.masterPlaylist (URL + token)
 *   master m3u8   -> la rendition migliora (*.m3u8)
 */
async function extractByAnimeId({ animeId, episodeNumber, quality }) {
  if (!Number.isInteger(episodeNumber) || episodeNumber < 1) {
    throw new ProviderError(422, 'Numero episodio mancante per il fallback.')
  }

  const session = await getSession()

  const infoUrl = new URL(
    `/info_api/${animeId}/${episodeNumber}`,
    BASE_URL,
  )
  infoUrl.searchParams.set('start_range', String(episodeNumber))
  infoUrl.searchParams.set('end_range', String(episodeNumber))

  const info = await apiJson(infoUrl.toString(), apiHeaders(session))
  const episodes = Array.isArray(info.episodes) ? info.episodes : []
  const wanted =
    episodes.find((e) => String(e.number) === String(episodeNumber)) ??
    episodes[0]

  if (!wanted?.id) {
    throw new ProviderError(404, `Episodio ${episodeNumber} non su AnimeUnity.`)
  }

  const animePage = `${BASE_URL}/anime/${animeId}-x`
  const embedResponse = await fetch(`${BASE_URL}/embed-url/${wanted.id}`, {
    headers: {
      ...apiHeaders(session),
      accept: 'text/plain',
      referer: animePage,
    },
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
    headers: {
      'user-agent': USER_AGENT,
      accept: 'text/html',
      referer: `${BASE_URL}/`,
    },
    redirect: 'follow',
    signal: AbortSignal.timeout(15000),
  })
  if (!pageResponse.ok) {
    throw new ProviderError(502, `Player AnimeUnity HTTP ${pageResponse.status}.`)
  }

  const { playlistUrl, expiresAt } = parseEmbedUrl(await pageResponse.text())
  const hlsUrl = await pickRendition(playlistUrl, quality)

  const expires =
    typeof expiresAt === 'string' && /^\d+$/.test(expiresAt)
      ? new Date(Number(expiresAt) * 1000).toISOString()
      : undefined

  return {
    url: hlsUrl,
    headers: {
      Referer: 'https://vixcloud.co/',
      Origin: 'https://vixcloud.co',
    },
    sourceType: 'hls',
    provider: 'animeunity',
    quality,
    expiresAt: expires,
  }
}

/** Estrae per titolo: il percorso del fallback quando il provider primario e' caduto. */
async function extractByMeta(meta, quality) {
  const animeId = await findAnimeId(meta)
  return extractByAnimeId({ animeId, episodeNumber: meta.episodeNumber, quality })
}

/** Estrae da un canonico AnimeUnity: `/anime/<id>-<slug>`. */
async function extractFromCanonical(canonicalUrl, meta, quality) {
  const animeId = parseAnimeId(canonicalUrl)
  if (!animeId) {
    throw new ProviderError(
      422,
      `Canonico AnimeUnity non riconosciuto: ${canonicalUrl}.`,
    )
  }
  return extractByAnimeId({ animeId, episodeNumber: meta.episodeNumber, quality })
}

function parseAnimeId(canonicalUrl) {
  try {
    const url = new URL(canonicalUrl)
    const match = /\/anime\/(\d+)-/.exec(url.pathname)
    return match ? Number(match[1]) : null
  } catch {
    return null
  }
}

module.exports = {
  BASE_URL,
  apiHeaders,
  apiJson,
  extractByAnimeId,
  extractByMeta,
  extractFromCanonical,
  findAnimeId,
  getSession,
  getSitemap,
  liveSearch,
  parseAnimeId,
  ProviderError,
  slugify,
}