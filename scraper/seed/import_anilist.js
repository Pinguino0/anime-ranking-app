// ============================================================================
// import_anilist.js - porta il catalogo AnimeUnity (~7.234 anime) su Supabase
// ============================================================================
//
// Due passi separati cosi' i rate-limit di AniList non fanno perdere lavoro:
//
// PASSO A - dump: pagina AniList (GraphQL, 50/pagina, ~400 pagine) e accumula i
//   media grezzi in `anilist_media.jsonl` (append + dedup per id). Ripartibile:
//   se interrotto, al rilancio riprende dalla pagina salvata in progress.
//
// PASSO B - match+import: legge il dump, matcha ogni titolo contro la sitemap
//   AnimeUnity (primariamente esatto su romaji/english/native, poi fuzzy sui
//   non matchati usando il primo vocabolo come indice), e fa upsert a lotti da
//   1000 via PostgREST con service_role:
//   on_conflict=external_source,external_id, resolution=merge-duplicates.
//   In external_data finisce { animeunity_id, animeunity_eps } (serve a
//   seed_apply.sql per generare episodi+fonti con generate_series).
//
// Esecuzione (il secret NON finisce nel repo): pausa; poi rilancio con
//   $env:SUPABASE_SERVICE_ROLE_KEY="..." ; node import_anilist.js
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

const ANILIST_API = 'https://graphql.anilist.co'
const PER_PAGE = 50
const DELAY_MS = 650
const UPSERT_CHUNK = 1000
const DUMP_FILE = path.join(__dirname, 'anilist_media.jsonl')
const PROGRESS_FILE = path.join(__dirname, 'anilist_progress.json')

// AniList limita la profondita' di pagina OFFSET a 5000 voci. Per scavallare il
// limite si pagina per `seasonYear` (dentro un anno le voci sono centinaia, mai
// vicine a 5000) e si riparte a zero l'offset. Anche i riavvii riprendono da
// `{ year, page }` salvati nel file di progress.
const QUERY = `query ($page: Int, $perPage: Int, $year: Int) {
  Page(page: $page, perPage: $perPage) {
    pageInfo { hasNextPage currentPage lastPage }
    media(type: ANIME, sort: ID, seasonYear: $year) {
      id
      title { romaji english native }
      coverImage { extraLarge large medium }
      format
      episodes
      status
      season
      seasonYear
      averageScore
      popularity
      genres
    }
  }
}`

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function slugify(value) {
  return String(value ?? '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/’/g, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .replace(/-{2,}/g, '-')
}

// score fuzzy identico ad animeunity.js: parole del candidato nello slug
function scoreSlug(candidate, slug) {
  const c = candidate.split('-').filter(Boolean)
  const s = new Set(slug.split('-').filter(Boolean))
  if (c.length === 0) return 0
  let hits = 0
  for (const w of c) if (s.has(w)) hits += 1
  return hits / c.length
}

const MEDIA_TYPE = {
  TV: 'TV',
  TV_SHORT: 'TV',
  MOVIE: 'Movie',
  OVA: 'OVA',
  ONA: 'ONA',
  SPECIAL: 'Special',
  MUSIC: 'Music',
}

const STATUS = {
  RELEASING: 'currently_airing',
  FINISHED: 'finished_airing',
  NOT_YET_RELEASED: 'not_yet_aired',
}

const SEASON = { WINTER: 'winter', SPRING: 'spring', SUMMER: 'summer', FALL: 'fall' }

async function fetchAniListYearPage(year, page) {
  for (let attempt = 1; attempt <= 5; attempt += 1) {
    try {
      const response = await fetch(ANILIST_API, {
        method: 'POST',
        headers: { 'content-type': 'application/json', accept: 'application/json' },
        body: JSON.stringify({
          query: QUERY,
          variables: { page, perPage: PER_PAGE, year },
        }),
        signal: AbortSignal.timeout(40000),
      })
      if (response.status === 429) {
        console.log(`  [${year} pg${page}] 429: pausa 60s (tentativo ${attempt})`)
        await sleep(60000)
        continue
      }
      if (!response.ok) {
        console.log(`  [${year} pg${page}] HTTP ${response.status}: ${(await response.text()).slice(0, 160)} (tentativo ${attempt})`)
        await sleep(5000 * attempt)
        continue
      }
      const data = await response.json()
      if (data?.errors) {
        console.log(`  [${year} pg${page}] errors: ${JSON.stringify(data.errors).slice(0, 200)} (tentativo ${attempt})`)
        await sleep(5000 * attempt)
        continue
      }
      return data.data.Page
    } catch (e) {
      console.log(`  [${year} pg${page}] errore (tentativo ${attempt}): ${e.message}`)
      await sleep(5000 * attempt)
    }
  }
  return null
}

async function upsertChunk(rows) {
  const response = await fetch(
    `${SUPABASE_URL}/rest/v1/anime?on_conflict=external_source,external_id`,
    {
      method: 'POST',
      headers: {
        apikey: SERVICE_ROLE_KEY,
        authorization: `Bearer ${SERVICE_ROLE_KEY}`,
        'content-type': 'application/json',
        prefer: 'resolution=merge-duplicates,return=minimal',
      },
      body: JSON.stringify(rows),
      signal: AbortSignal.timeout(60000),
    },
  )
  if (!response.ok) {
    console.log(`  upsert HTTP ${response.status}: ${(await response.text()).slice(0, 300)}`)
    return false
  }
  return true
}

function ensureDumpSeenIds() {
  const seen = new Set()
  if (fs.existsSync(DUMP_FILE)) {
    for (const line of fs.readFileSync(DUMP_FILE, 'utf8').split('\n')) {
      if (line.trim()) {
        try {
          seen.add(JSON.parse(line).id)
        } catch {
          /* linea corrotta: ignora */
        }
      }
    }
  }
  return seen
}

async function passDump() {
  let progress = { year: 1917, page: 1 }
  try {
    progress = JSON.parse(fs.readFileSync(PROGRESS_FILE, 'utf8'))
  } catch {
    /* primo giro */
  }
  const seen = ensureDumpSeenIds()
  const append = fs.createWriteStream(DUMP_FILE, { flags: 'a' })

  const FIRST_YEAR = 1917
  const LAST_YEAR = new Date().getFullYear() + 1
  console.log(`PASSO A - dump AniList per anno, da ${progress.year} (pagina ${progress.page})`)

  outer: for (let year = progress.year; year <= LAST_YEAR; year += 1) {
    let page = year === progress.year ? progress.page : 1
    while (true) {
      const data = await fetchAniListYearPage(year, page)
      if (!data) {
        console.log(`  dump interrotto a ${year} pg${page}: riprendibile`)
        append.end()
        await fs.promises.writeFile(PROGRESS_FILE, JSON.stringify({ year, page }))
        return
      }
      let added = 0
      for (const m of data.media) {
        if (seen.has(m.id)) continue
        seen.add(m.id)
        append.write(`${JSON.stringify(m)}\n`)
        added += 1
      }
      console.log(`  ${year} pg${page}/${data.pageInfo.lastPage} (+${added})`)
      await fs.promises.writeFile(PROGRESS_FILE, JSON.stringify({ year, page }))
      if (!data.pageInfo.hasNextPage) break
      page += 1
      await sleep(DELAY_MS)
    }
    await sleep(DELAY_MS)
  }
  append.end()
  console.log('PASSO A completato: dump chiuso')
}

async function passMatchImport() {
  console.log('PASSO B - match sitemap + upsert')
  const sitemap = await au.getSitemap()
  console.log(`  sitemap AnimeUnity: ${sitemap.size} slug`)

  // indice fuzzy: primo vocabolo -> lista id slug (per il passaggio fuzzy)
  const byFirst = new Map()
  for (const [slug] of sitemap) {
    const first = slug.split('-').filter(Boolean)[0]
    if (!first) continue
    if (!byFirst.has(first)) byFirst.set(first, [])
    byFirst.get(first).push(slug)
  }

  const lines = fs.readFileSync(DUMP_FILE, 'utf8').split('\n').filter(Boolean)
  console.log(`  media dal dump: ${lines.length}`)

  let matched = 0
  let exact = 0
  let fuzzy = 0
  const batch = []
  let upserted = 0
  // Record AnimeUnity gia' assegnati in questa passata: senza questo, due media
  // AniList diversi possono agganciare lo stesso slug e condividere l'id
  // (era la causa dei 2865 anime con animeunity_id duplicato).
  const reserved = new Set()

  const flush = async () => {
    if (batch.length === 0) return
    if (await upsertChunk(batch)) {
      upserted += batch.length
      console.log(`  upsert: +${batch.length} (tot ${upserted})`)
    }
    batch.length = 0
  }

  for (const line of lines) {
    const m = JSON.parse(line)
    const animeType = MEDIA_TYPE[m.format]
    if (!animeType) continue

    const candidates = []
    for (const v of [m.title?.romaji, m.title?.english, m.title?.native]) {
      const s = slugify(v)
      if (s && !candidates.includes(s)) candidates.push(s)
    }

    let auId = null
    let how = null
    // esatto
    for (const c of candidates) {
      if (sitemap.has(c)) {
        const id = sitemap.get(c)
        if (!reserved.has(id)) {
          auId = id
          how = 'exact'
        }
        break
      }
    }
    // fuzzy: solo candidati con almeno DUE parole. Un titolo di una parola sola
    // ("X", "Z", "Re", "Naruto") ha scoreSlug = 1.0 su qualunque slug che
    // contenga quella parola, e agganciava record di opere diverse. La soglia
    // resta alta (0.9) e si scartano i record gia' presi da un altro media.
    if (auId == null) {
      let best = null
      let bestScore = 0.9
      for (const c of candidates) {
        if (c.split('-').filter(Boolean).length < 2) continue
        const first = c.split('-').filter(Boolean)[0]
        const pool = first ? byFirst.get(first) : null
        if (!pool) continue
        for (const slug of pool) {
          const id = sitemap.get(slug)
          if (reserved.has(id)) continue
          const score = scoreSlug(c, slug)
          if (score > bestScore) {
            best = { id, score }
            bestScore = score
          }
        }
      }
      if (best) {
        auId = best.id
        how = `fuzzy(${best.score.toFixed(2)})`
      }
    }
    if (auId == null) continue
    reserved.add(auId)

    matched += 1
    if (how === 'exact') exact += 1
    else fuzzy += 1

    const episodes = Number.isInteger(m.episodes) && m.episodes > 0 ? m.episodes : 1

    const synonyms = []
    for (const v of [m.title?.english, m.title?.native]) {
      if (typeof v === 'string' && v.trim()) synonyms.push(v.trim())
    }
    const lower = synonyms.map((s) => s.toLowerCase())
    const uniq = synonyms.filter((s, i) => lower.indexOf(s.toLowerCase()) === i)

    batch.push({
      external_id: String(m.id),
      external_source: 'anilist',
      title: m.title?.english || m.title?.romaji || m.title?.native,
      japanese_title: m.title?.native,
      synonyms: uniq,
      image_url: m.coverImage?.extraLarge || m.coverImage?.large || m.coverImage?.medium,
      episodes,
      status: STATUS[m.status] ?? null,
      season: SEASON[m.season] ?? null,
      year: m.seasonYear ?? null,
      media_type: animeType,
      genres: m.genres ?? [],
      score: m.averageScore != null ? Number((m.averageScore / 10).toFixed(2)) : null,
      popularity: m.popularity ?? null,
      external_data: { animeunity_id: auId, animeunity_eps: episodes },
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    if (batch.length >= UPSERT_CHUNK) await flush()
  }
  await flush()

  console.log(`PASSO B finito: ${matched} match (exact ${exact}, fuzzy ${fuzzy}), upsertati ${upserted}`)
}

async function main() {
  const only = process.argv.find((a) => a.startsWith('--only='))?.split('=')[1]
  if (only === 'b') {
    await passMatchImport()
    return
  }
  await passDump()
  await passMatchImport()
}

main().catch((e) => {
  console.error('ERR', e.message)
  process.exit(1)
})