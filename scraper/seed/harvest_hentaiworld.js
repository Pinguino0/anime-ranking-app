// ============================================================================
// harvest_hentaiworld.js - scarica l'indice del catalogo HentaiWorld
// ============================================================================
//
// Perche' esiste
// --------------
// HentaiWorld non espone da nessuna parte un id AniList/MAL: l'unico modo per
// legare i suoi video agli anime del catalogo e' il titolo (scelta presa a
// monte, con soglia alta e revisione — vedi `map_hentaiworld.js`). Per farlo
// servono titolo e slug di ogni serie e la lista dei suoi episodi; questo
// script li raccoglie in `provider_anime_index`, la stessa tabella degli altri
// provider, cosi' il matching lavora su dati locali e idempotenti.
//
// Da dove arrivano i dati
// -----------------------
//   sitemap-episodes.xml  tutte le pagine episodio, nel formato
//                         /watch/<serie>[-lingua]-episode-<n>. Da qui gli
//                         episodi di ogni serie e i loro URL esatti.
//   /archive               le schede serie a 20 per pagina, con titolo
//                         leggibile e slug. ~85 richieste coprono tutte le
//                         ~1600 serie (aprire le singole pagine episodio
//                         sarebbe ~4000 richieste).
//
// La chiave di riga e' lo "stem" dell'episodio (tutto cio' che precede
// `-episode-N`), non lo slug dell'archivio: cosi' ogni variante (ita/eng)
// resta una riga a se' e l'URL canonico si ricostruisce esatto.
//
// Cosa scrive
// -----------
//   provider_anime_index  una riga per serie (provider_slug = 'hentaiworld'),
//                         con title, slug, episodes_count e in raw_data gli
//                         URL degli episodi.
//
// Idempotente: la chiave (provider_slug, provider_anime_id) viene riscritta.
//
// Uso:
//   $env:SUPABASE_SERVICE_ROLE_KEY="..."; node scraper/seed/harvest_hentaiworld.js
//   node scraper/seed/harvest_hentaiworld.js --dry        # nessuna scrittura
//   node scraper/seed/harvest_hentaiworld.js --pages=3    # prova su poche pagine
// ============================================================================

const fs = require('fs')
const path = require('path')

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://sjbstiexythmapxmrfyp.supabase.co'
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY
if (!SERVICE_ROLE_KEY) {
  console.error('manca SUPABASE_SERVICE_ROLE_KEY')
  process.exit(1)
}

const PROVIDER_SLUG = 'hentaiworld'
const BASE = 'https://www.hentaiworld.me'
const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

const argNum = (name, def) => {
  const a = process.argv.find((x) => x.startsWith(`--${name}=`))
  return a ? Number(a.split('=')[1]) : def
}

const DELAY_MS = argNum('delay', 150)
const MAX_PAGES = argNum('pages', 140)
const LIMIT = argNum('limit', 0)
const DRY = process.argv.includes('--dry')
const MAX_ATTEMPTS = 4
const BATCH = 200

const LOG_FILE = path.join(__dirname, 'harvest_hentaiworld.log')

const restHeaders = {
  apikey: SERVICE_ROLE_KEY,
  authorization: `Bearer ${SERVICE_ROLE_KEY}`,
  'content-type': 'application/json',
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function log(line) {
  const ts = new Date().toISOString().replace('T', ' ').slice(0, 19)
  const out = `[${ts}] ${line}`
  console.log(out)
  fs.appendFileSync(LOG_FILE, out + '\n')
}

/** GET con ritentativi sui 429/5xx. `ok:false` sugli altri errori. */
async function get(url) {
  let lastErr
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1) {
    try {
      const res = await fetch(url, {
        headers: { 'user-agent': UA, 'accept-language': 'it-IT,it;q=0.9' },
        redirect: 'follow',
        signal: AbortSignal.timeout(30000),
      })
      if (res.status === 429 || res.status >= 500) throw new Error(`HTTP ${res.status}`)
      if (!res.ok) return { ok: false, status: res.status }
      return { ok: true, status: res.status, text: await res.text() }
    } catch (e) {
      lastErr = e
      await sleep(700 * attempt)
    }
  }
  return { ok: false, error: lastErr?.message ?? 'errore' }
}

// ---------------------------------------------------------------------------
// Archivio: slug -> titolo
// ---------------------------------------------------------------------------

/** La lingua di una variante, dedotta dal suffisso dello stem. */
function detectLanguage(stem) {
  if (/(^|-)(sub-eng|eng)$/i.test(stem)) return 'eng'
  if (/(^|-)(sub-ita|ita)$/i.test(stem)) return 'ita'
  return null
}

/** Titolo di ripiego quando lo stem non compare in archivio. */
function prettifyStem(stem) {
  return stem
    .replace(/-(sub|dub)-(eng|ita)$/i, '')
    .replace(/-(eng|ita)$/i, '')
    .split('-')
    .filter(Boolean)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(' ')
}

function decodeEntities(value) {
  return value
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;/g, "'")
    .replace(/&#x27;/gi, "'")
}

async function harvestArchive() {
  const bySlug = new Map()
  for (let page = 1; page <= MAX_PAGES; page += 1) {
    const url = page === 1 ? `${BASE}/archive` : `${BASE}/archive?page=${page}`
    const res = await get(url)
    if (!res.ok) {
      log(`archivio pagina ${page}: ${res.error ?? `HTTP ${res.status}`}`)
      break
    }
    // Ogni card e': <a href="/hentai/<slug>"><span class="sr-only">Guarda <titolo></span>
    const cards = [
      ...res.text.matchAll(
        /<a[^>]*href="\/hentai\/([^"]+)"[^>]*>\s*<span class="sr-only">Guarda ([\s\S]*?)<\/span>/g,
      ),
    ].map((m) => ({ slug: m[1], title: decodeEntities(m[2]).trim() }))

    let added = 0
    for (const c of cards) {
      if (!bySlug.has(c.slug)) {
        bySlug.set(c.slug, c.title)
        added += 1
      }
    }
    log(`archivio pagina ${page}: ${cards.length} card, +${added} nuove (totale ${bySlug.size})`)
    if (cards.length === 0 || added === 0) break
    await sleep(DELAY_MS)
  }
  return bySlug
}

// ---------------------------------------------------------------------------
// Sitemap episodi -> righe indice
// ---------------------------------------------------------------------------

async function fetchEpisodeUrls() {
  const res = await get(`${BASE}/sitemap-episodes.xml`)
  if (!res.ok) throw new Error(`sitemap-episodes: ${res.error ?? `HTTP ${res.status}`}`)
  return [...res.text.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1])
}

function buildRows(episodeUrls, archiveBySlug) {
  // stem -> Map(numero -> URL)
  const byStem = new Map()
  for (const u of episodeUrls) {
    let pathname
    try {
      pathname = new URL(u).pathname.replace(/^\//, '')
    } catch {
      continue
    }
    const m = pathname.match(/^watch\/(.+)-episode-(\d+)$/)
    if (!m) continue
    const stem = m[1]
    if (!byStem.has(stem)) byStem.set(stem, new Map())
    byStem.get(stem).set(Number(m[2]), u)
  }

  const slugsByLen = [...archiveBySlug.keys()].sort((a, b) => b.length - a.length)
  const rows = []
  for (const [stem, eps] of byStem) {
    const sourceSlug = slugsByLen.find((s) => stem === s || stem.startsWith(s + '-')) ?? null
    const title = sourceSlug ? archiveBySlug.get(sourceSlug) : prettifyStem(stem)
    const nums = [...eps.keys()].sort((a, b) => a - b)
    rows.push({
      provider_slug: PROVIDER_SLUG,
      provider_anime_id: stem,
      anilist_id: null,
      mal_id: null,
      title,
      title_eng: null,
      title_it: null,
      slug: stem,
      is_dub: false,
      episodes_count: nums.length,
      raw_data: {
        source_slug: sourceSlug,
        language: detectLanguage(stem),
        episodes: nums.map((n) => ({ n, url: eps.get(n) })),
      },
    })
  }
  rows.sort((a, b) => a.provider_anime_id.localeCompare(b.provider_anime_id))
  return rows
}

// ---------------------------------------------------------------------------
// Upsert
// ---------------------------------------------------------------------------

async function upsert(rows) {
  if (DRY || rows.length === 0) return
  const res = await fetch(`${SUPABASE_URL}/rest/v1/provider_anime_index`, {
    method: 'POST',
    headers: {
      ...restHeaders,
      prefer: 'resolution=merge-duplicates,return=minimal',
    },
    body: JSON.stringify(rows),
    signal: AbortSignal.timeout(60000),
  })
  if (!res.ok) {
    throw new Error(`upsert HTTP ${res.status}: ${(await res.text()).slice(0, 300)}`)
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  log(`harvest ${PROVIDER_SLUG}${DRY ? ' (DRY)' : ''}`)

  const archiveBySlug = await harvestArchive()
  log(`archivio: ${archiveBySlug.size} serie distinte`)

  const episodeUrls = await fetchEpisodeUrls()
  log(`sitemap episodi: ${episodeUrls.length} URL`)

  let rows = buildRows(episodeUrls, archiveBySlug)
  log(`righe indice: ${rows.length}`)

  if (LIMIT > 0) {
    rows = rows.slice(0, LIMIT)
    log(`limite: ${LIMIT} righe`)
  }

  const withTitle = rows.filter((r) => r.raw_data.source_slug).length
  log(`con titolo dall'archivio: ${withTitle}, di ripiego: ${rows.length - withTitle}`)

  let written = 0
  for (let i = 0; i < rows.length; i += BATCH) {
    const batch = rows.slice(i, i + BATCH)
    await upsert(batch)
    written += batch.length
    if (!DRY && (i / BATCH) % 2 === 0) log(`progresso righe: ${Math.min(written, rows.length)}/${rows.length}`)
  }

  log(`fatto: ${written} righe ${DRY ? '(non scritte, DRY)' : 'scritte'} su ${PROVIDER_SLUG}`)
}

module.exports = { buildRows, harvestArchive, prettifyStem, detectLanguage }

if (require.main === module) {
  main().catch((e) => {
    console.error('ERR', e.message)
    process.exit(1)
  })
}
