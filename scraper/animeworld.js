// ============================================================================
// animeworld.js - ricerca e catalogo episodi del provider AnimeWorld
// ============================================================================
//
// AnimeWorld e' il gemello di AnimeUnity (stessa piattaforma Laravel) ma e' il
// provider di "backup": copre i titoli che AnimeUnity non ha, tipicamente film,
// special, OVA e stagioni recenti. A differenza di AnimeUnity il video non e'
// HLS dietro vixcloud ma un DDL diretto: la risoluzione la fa l'extractor
// (`server.js`, adapter `extractAnimeWorld`), qui invece si costruisce il
// CATALOGO — quali episodi esistono e il loro indirizzo canonico.
//
// Perche' serve un modulo a parte e non si riusa animeunity.js
// ------------------------------------------------------------
// Le due superfici sono diverse: AnimeUnity si interroga per API JSON
// (`/livesearch`) e si indicizza per sitemap; AnimeWorld espone solo pagine
// HTML pubbliche (gli endpoint POST rispondono dietro protezione). Quindi qui
// si leggono due pagine:
//
//   GET /search?keyword=<q>   -> le schede dei risultati (`/play/<slug>.<id>`)
//   GET /play/<slug>.<id>     -> la lista episodi (`data-episode-num` + href)
//
// Il suffisso `<id>` e' l'id interno dell'anime e NON va costruito a mano:
// cambia fra le versioni (sub/ita) e viene preso solo dalle pagine.
//
// Nota di robustezza: gli slug diventano `-ita` per la versione doppiata. La
// scelta fra sub e doppiaggio italiano si fa sul candidato, non sul titolo.
// ============================================================================

const BASE_URL = 'https://www.animeworld.ac'

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
// Sessione
// ---------------------------------------------------------------------------
//
// Le GET pubbliche funzionano anche senza cookie, ma la home ne rilascia uno di
// sessione e passarlo evita che il sito tratti ogni richiesta come una sessione
// nuova (e prima o poi parta un rate limit). Il cookie si ricompra quando
// scade; il TTL resta prudente.
let sessionCache = { cookie: '', expiresAt: 0 }
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
    throw new ProviderError(502, `AnimeWorld ha risposto HTTP ${response.status}.`)
  }

  const rawCookies = response.headers.getSetCookie?.() ?? []
  const cookie = rawCookies.map((c) => c.split(';')[0]).join('; ')

  sessionCache = { cookie, expiresAt: Date.now() + SESSION_TTL_MS }
  return sessionCache
}

async function fetchHtml(url, referer) {
  const session = await getSession()
  const response = await fetch(url, {
    headers: {
      'user-agent': USER_AGENT,
      accept: 'text/html,application/xhtml+xml',
      ...(referer ? { referer } : {}),
      ...(session.cookie ? { cookie: session.cookie } : {}),
    },
    redirect: 'follow',
    signal: AbortSignal.timeout(20000),
  })
  if (!response.ok) {
    throw new ProviderError(502, `AnimeWorld ha risposto HTTP ${response.status}.`)
  }
  return { html: await response.text(), finalUrl: response.url }
}

// ---------------------------------------------------------------------------
// Ricerca
// ---------------------------------------------------------------------------

/**
 * Candidati AnimeWorld per una parola chiave.
 *
 * Le schede dei risultati sono `<div class="item">` con due link identici:
//   <a href="/play/<slug>.<id>" class="poster">...<img alt="Titolo">
//   <a href="/play/<slug>.<id>" data-jtitle="..." class="name">Titolo</a>
//
// Si legge l'anchor `.name` perche' porta insieme href, titolo mostrato e
// `data-jtitle` (il titolo originale/inglese): sono i due titoli con cui si fa
// il confronto, piu' le parole dello slug.
*/
async function search(keyword) {
  const url = `${BASE_URL}/search?keyword=${encodeURIComponent(keyword)}`
  const { html } = await fetchHtml(url)

  // I risultati veri stanno TUTTI dentro `<div class="film-list">`. Fuori c'e'
  // il resto della pagina (classifiche, ultimi episodi, generi) con schede
  // identiche: se non si ritaglia il contenitore, una ricerca senza risultati
  // restituirebbe le schede della sidebar come se fossero match. Quando la
  // ricerca e' vuota il `film-list` e' presente ma senza figli.
  const region = filmListRegion(html)

  const out = []
  const seen = new Set()

  // Ancoraggio sulla classe `name`: e' l'unica che porta titolo e href insieme.
  const re =
    /<a\s+href="(\/play\/[^"]+)"([^>]*?)class="name"[^>]*>([^<]*)<\/a>/gi
  for (const match of region.matchAll(re)) {
    const href = match[1]
    const attrs = match[2] ?? ''
    const name = decodeEntities(match[3] ?? '').trim()
    const jtitleMatch = /data-jtitle="([^"]*)"/i.exec(attrs)
    const jtitle = jtitleMatch ? decodeEntities(jtitleMatch[1]).trim() : ''

    const path = href.split('?')[0]
    if (seen.has(path)) continue
    seen.add(path)

    out.push({
      path,
      slug: path.replace('/play/', '').split('.').slice(0, -1).join('.'),
      name,
      jtitle,
      dub: isDub(name, jtitle, path),
    })
  }

  return out
}

/** Ritaglia il contenitore dei risultati veri (`film-list`). */
function filmListRegion(html) {
  const start = html.indexOf('class="film-list"')
  if (start < 0) return ''
  const end = html.indexOf('class="widget', start)
  return end < 0 ? html.slice(start) : html.slice(start, end)
}

/**
 * E' la versione doppiata? Il marcatore affidabile e' "(ITA)" nel titolo
 * mostrato o nel `data-jtitle`; lo slug `-ita` copre i casi senza parentesi.
 * NB: alcuni doppiaggi NON hanno `-ita` nello slug (es. i film di Gurren
 * Lagann usano solo "(ITA)" nel nome).
 */
function isDub(name, jtitle, path) {
  return (
    /\(ita\)/i.test(name) ||
    /\(ita\)/i.test(jtitle) ||
    /-ita([./]|$)/i.test(path.replace('/play/', ''))
  )
}

// ---------------------------------------------------------------------------
// Lista episodi
// ---------------------------------------------------------------------------

// La scheda episodio: `<a data-episode-id="51027" data-id="xatOFs"
// data-episode-num="1" ... href="/play/gurren-lagann.LYGsr/xatOFs">1</a>`.
const EPISODE_RE =
  /data-episode-num="([0-9]+(?:-[0-9]+)?)"[^>]*\bhref="([^"]+)"/gi

/**
 * Gli episodi di un anime, letti dalla sua pagina.
 *
 * La pagina `/play/<slug>.<id>` reindirizza al primo episodio e contiene tutta
 * la lista in una `<ul class="episodes">`: ogni voce ha `data-episode-num` (il
 * numero, che puo' essere un doppio tipo "1-2") e l'`href` assoluto-rispetto-al
 * sito dell'episodio.
 *
 * Restituisce `{ resolvedPath, anilistId, malId, episodes: [{ num, href }] }`.
 * `num` puo' essere una stringa ("1-2"): la numerazione "N-M" e' un episodio
 * doppio e va tenuta come intera solo per il conteggio; nel DB finisce il
 * numero di partenza (vedi `baseNum`).
 *
 * La stessa pagina espone le schede esterne MyAnimeList e AniList: sono il
 * modo ESATTO di riconoscere l'opera (`https://anilist.co/anime/<id>`), senza
 * fidarsi del titolo. E' lo stesso principio con cui AnimeUnity espone
 * `anilist_id`: il match per id non ha falsi positivi.
 */
async function episodes(animePath) {
  const url = `${BASE_URL}${animePath.startsWith('/') ? animePath : `/${animePath}`}`
  const { html } = await fetchHtml(url)
  const resolvedPath = new URL(url).pathname

  const list = []
  const seen = new Set()
  for (const match of html.matchAll(EPISODE_RE)) {
    const num = match[1]
    const href = match[2]
    const key = `${num}|${href}`
    if (seen.has(key)) continue
    seen.add(key)
    list.push({ num, href: href.startsWith('http') ? href : `${BASE_URL}${href}` })
  }

  // Ordina per numero "base" (prima parte di un eventuale "N-M").
  list.sort((a, b) => baseNum(a.num) - baseNum(b.num))

  return {
    resolvedPath,
    anilistId: matchId(html, /anilist\.co\/anime\/(\d+)/i),
    malId: matchId(html, /myanimelist\.net\/anime\/(\d+)/i),
    episodes: list,
  }
}

function matchId(html, re) {
  const m = re.exec(html)
  return m ? Number(m[1]) : null
}

/** La prima parte di una numerazione "N-M" (episodio doppio), come intero. */
function baseNum(value) {
  const n = parseInt(String(value).split('-')[0], 10)
  return Number.isFinite(n) ? n : 0
}

// ---------------------------------------------------------------------------
// Utilita'
// ---------------------------------------------------------------------------

function decodeEntities(value) {
  return value
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;/g, "'")
    .replace(/&#x27;/gi, "'")
}

/** Normalizza un titolo come per il matching del catalogo. */
function cleaned(value) {
  return String(value ?? '')
    .replace(/[\[\(].*?[\]\)]/g, ' ')
    .replace(/&amp;/g, ' ')
    .replace(/&/g, ' ')
    .replace(/[^a-zA-Z0-9À-ÿ']+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
}

/**
 * Normalizza un titolo per la RICERCA, non per il confronto.
 *
 * Differenza cruciale da `cleaned`: conserva la punteggiatura. Il motore di
 * AnimeWorld cerca in modo letterale e la punteggiatura fa parte del titolo:
 * "Re:Zero kara Hajimeru Isekai Seikatsu 3" trova la scheda, "Re Zero kara
 * Hajimeru Isekai Seikatsu 3" non trova nulla. Qui si tolgono solo le
 * parentesi ("(ITA)", "(2024)") e si collassano gli spazi.
 */
function queryText(value) {
  return String(value ?? '')
    .replace(/[\[\(].*?[\]\)]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
}

/** Coefficiente di Dice fra due stringhe di parole (0 = niente, 1 = identiche). */
function dice(a, b) {
  const ta = (a || '').split(' ').filter(Boolean)
  const tb = (b || '').split(' ').filter(Boolean)
  if (!ta.length || !tb.length) return 0
  const setB = new Set(tb)
  let inter = 0
  for (const w of ta) if (setB.has(w)) inter += 1
  return (2 * inter) / (ta.length + tb.length)
}

module.exports = {
  BASE_URL,
  ProviderError,
  cleaned,
  dice,
  baseNum,
  episodes,
  search,
  queryText,
}