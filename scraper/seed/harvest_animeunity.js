// ============================================================================
// harvest_animeunity.js - scarica l'indice anime di AnimeUnity in una tabella
// ============================================================================
//
// Perche' esiste
// ---------------------------------------------------------------------------
// Il binding fonte -> episodi non deve mai passare dal titolo. AnimeUnity
// dichiara, per ogni suo record, l'anilist_id/mal_id e se e' la versione sub o
// dub. Questo script scarica l'indice completo (sitemap + GET /info_api/{id})
// nella tabella `provider_anime_index`: da li' il mapping avviene per ID esatto.
//
// Idempotente e ripartibile: la riga (provider_slug, provider_anime_id) e' la
// chiave; l'upsert riscrive solo cio' che cambia. Al riavvio salta gli id gia'
// presenti (a meno di --refresh), quindi un'interruzione non fa danno.
//
// Uso:
//   $env:SUPABASE_SERVICE_ROLE_KEY="..."; node harvest_animeunity.js
//   node harvest_animeunity.js --limit=200         # prova
//   node harvest_animeunity.js --concurrency=3     # default 3
//   node harvest_animeunity.js --refresh           # riscarica anche gli esistenti
//   node harvest_animeunity.js --dry               # nessuna scrittura
// ============================================================================

const fs = require('fs')
const path = require('path')
const au = require('../animeunity.js')

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://sjbstiexythmapxmrfyp.supabase.co'
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY
if (!SERVICE_ROLE_KEY) {
  console.error('manca SUPABASE_SERVICE_ROLE_KEY')
  process.exit(1)
}

const PROVIDER_SLUG = 'mio_provider'
const BASE = au.BASE_URL
const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

const argNum = (name, def) => {
  const a = process.argv.find((x) => x.startsWith(`--${name}=`))
  return a ? Number(a.split('=')[1]) : def
}

const DELAY_MS = argNum('delay', 120)
const CONCURRENCY = Math.max(1, argNum('concurrency', 3))
const LIMIT = argNum('limit', 0)
const REFRESH = process.argv.includes('--refresh')
const DRY = process.argv.includes('--dry')
const MAX_ATTEMPTS = 4

const LOG_FILE = path.join(__dirname, 'harvest_animeunity.log')
const FAILED_FILE = path.join(__dirname, 'harvest_animeunity.failed.json')
const BATCH = 200

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

// ---------------------------------------------------------------------------
// Lettura id esistenti (resume) e id gia' referenziati dal catalogo
// ---------------------------------------------------------------------------

async function fetchAll(pathAndQuery) {
  const out = []
  let offset = 0
  const page = 1000
  for (;;) {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/${pathAndQuery}`, {
      headers: { ...restHeaders, range: `${offset}-${offset + page - 1}` },
    })
    if (!res.ok) throw new Error(`GET ${pathAndQuery} -> ${res.status}: ${(await res.text()).slice(0, 300)}`)
    const rows = await res.json()
    out.push(...rows)
    if (rows.length < page) break
    offset += page
  }
  return out
}

// La sitemap va letta per ID, non con au.getSitemap() che mappa slug->id: gli
// slug collidono (sub/dub e omonimi) e la Map perderebbe ~1800 id.
//
// Inoltre il server alterna due varianti della sitemap: una completa (~7245 id)
// e una troncata (~5423, con 3 id che l'altra non ha). Un solo fetch non basta:
// si fanno piu' tentativi e si uniscono gli id, fino a convergenza.
async function fetchSitemapIdsOnce() {
  const res = await fetch(`${BASE}/sitemap.xml`, {
    headers: { 'user-agent': UA },
    redirect: 'follow',
    signal: AbortSignal.timeout(30000),
  })
  if (!res.ok) throw new Error(`sitemap HTTP ${res.status}`)
  const xml = await res.text()
  const ids = new Set()
  for (const m of xml.matchAll(/\/anime\/(\d+)-/g)) ids.add(m[1])
  return ids
}

async function fetchSitemapIds(attempts = 5) {
  const ids = new Set()
  for (let i = 0; i < attempts; i += 1) {
    try {
      const found = await fetchSitemapIdsOnce()
      for (const id of found) ids.add(id)
      log(`sitemap tentativo ${i + 1}: ${found.size} id (cumulativo ${ids.size})`)
    } catch (e) {
      log(`sitemap tentativo ${i + 1} fallito: ${e.message}`)
    }
    await sleep(400)
  }
  if (ids.size === 0) throw new Error('sitemap AnimeUnity non disponibile')
  return ids
}

async function existingIndexIds() {
  if (REFRESH) return new Set()
  const rows = await fetchAll(
    `provider_anime_index?select=provider_anime_id&provider_slug=eq.${PROVIDER_SLUG}`,
  )
  return new Set(rows.map((r) => String(r.provider_anime_id)))
}

async function catalogAnimeUnityIds() {
  const rows = await fetchAll(`anime?select=external_data`)
  const ids = new Set()
  for (const r of rows) {
    const v = r.external_data && r.external_data.animeunity_id
    if (v != null) ids.add(String(v))
  }
  return ids
}

// ---------------------------------------------------------------------------
// Fetch di un record
// ---------------------------------------------------------------------------

async function fetchInfo(id) {
  let lastErr
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1) {
    try {
      const res = await fetch(`${BASE}/info_api/${id}`, {
        headers: {
          'user-agent': UA,
          accept: 'application/json',
          'x-requested-with': 'XMLHttpRequest',
        },
        redirect: 'follow',
        signal: AbortSignal.timeout(20000),
      })
      if (res.status === 429 || res.status >= 500) {
        throw new Error(`HTTP ${res.status}`)
      }
      if (!res.ok) {
        return { id, skip: true, reason: `HTTP ${res.status}` }
      }
      const j = await res.json()
      if (j == null || j.id == null) {
        return { id, skip: true, reason: 'record vuoto' }
      }
      return {
        id,
        row: {
          provider_slug: PROVIDER_SLUG,
          provider_anime_id: String(j.id ?? id),
          anilist_id: Number.isFinite(Number(j.anilist_id)) ? Number(j.anilist_id) : null,
          mal_id: Number.isFinite(Number(j.mal_id)) ? Number(j.mal_id) : null,
          title: j.title ?? null,
          title_eng: j.title_eng ?? null,
          title_it: j.title_it ?? null,
          slug: j.slug ?? null,
          is_dub: Number(j.dub) === 1,
          episodes_count:
            Number.isFinite(Number(j.episodes_count)) && Number(j.episodes_count) >= 0
              ? Number(j.episodes_count)
              : null,
          raw_data: j,
        },
      }
    } catch (e) {
      lastErr = e
      await sleep(800 * attempt)
    }
  }
  return { id, error: lastErr?.message ?? 'errore' }
}

// ---------------------------------------------------------------------------
// Upsert
// ---------------------------------------------------------------------------

async function upsert(rows) {
  if (DRY || rows.length === 0) return
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/provider_anime_index?on_conflict=provider_slug,provider_anime_id`,
    {
      method: 'POST',
      headers: { ...restHeaders, prefer: 'resolution=merge-duplicates,return=minimal' },
      body: JSON.stringify(rows),
    },
  )
  if (!res.ok) {
    throw new Error(`upsert -> ${res.status}: ${(await res.text()).slice(0, 400)}`)
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  log(`harvest AnimeUnity (provider=${PROVIDER_SLUG}, conc=${CONCURRENCY}, delay=${DELAY_MS}ms, refresh=${REFRESH}, dry=${DRY})`)

  const sitemapIdSet = await fetchSitemapIds()
  const sitemapIds = [...sitemapIdSet]
  log(`sitemap: ${sitemapIds.length} id distinti`)

  const catalogIds = await catalogAnimeUnityIds()
  log(`id referenziati dal catalogo: ${catalogIds.size}`)

  const allIds = [...new Set([...sitemapIds, ...catalogIds])]
  const done = await existingIndexIds()
  log(`gia' presenti in indice: ${done.size}`)

  let todo = allIds.filter((id) => !done.has(id))
  if (LIMIT > 0) todo = todo.slice(0, LIMIT)
  log(`da scaricare: ${todo.length}`)

  const failed = []
  let ok = 0
  let skipped = 0
  let buffer = []

  const flush = async () => {
    if (buffer.length === 0) return
    await upsert(buffer)
    buffer = []
  }

  let cursor = 0
  async function worker() {
    for (;;) {
      const idx = cursor++
      if (idx >= todo.length) return
      const id = todo[idx]
      const r = await fetchInfo(id)
      if (r.row) {
        buffer.push(r.row)
        ok += 1
        if (buffer.length >= BATCH) await flush()
      } else if (r.skip) {
        skipped += 1
        log(`skip id=${id}: ${r.reason}`)
      } else {
        failed.push({ id, error: r.error })
        log(`FAIL id=${id}: ${r.error}`)
      }
      const total = ok + skipped + failed.length
      if (total % 50 === 0) log(`progresso ${total}/${todo.length} (ok=${ok}, skip=${skipped}, fail=${failed.length})`)
      await sleep(DELAY_MS)
    }
  }

  await Promise.all(Array.from({ length: CONCURRENCY }, worker))
  await flush()

  fs.writeFileSync(FAILED_FILE, JSON.stringify(failed, null, 2), 'utf8')
  log(`fatto: ok=${ok}, skip=${skipped}, fail=${failed.length}${DRY ? ' (dry, nessuna scrittura)' : ''}`)
}

main().catch((e) => {
  console.error('ERR', e.message)
  process.exit(1)
})
