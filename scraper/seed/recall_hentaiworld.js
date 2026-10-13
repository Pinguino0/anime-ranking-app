// ============================================================================
// recall_hentaiworld.js - recupero dei match HentaiWorld SFUGGITI al fuzzy
// ============================================================================
//
// Perche' serve un secondo giro
// -----------------------------
// `map_hentaiworld.js` aggancia per somiglianza di titolo, quindi sbaglia (o
// lascia a meta') proprio i casi in cui il titolo del provider non somiglia a
// quello del catalogo: nomi tradotti a mano, romaji contro inglese, sottotitoli
// aggiunti dal provider. Sono centinaia di serie.
//
// Qui si usa AniList come traduttore: si cerca il titolo HentaiWorld su AniList,
// si prende l'id AniList (e l'id MyAnimeList) del media trovato e si risolve
// contro il catalogo, che quegli id li conserva. Un match per id non e' un
// match per titolo: e' la stessa opera, quindi e' affidabile.
//
// Due strade, due fiducie
// -----------------------
//   match = 'id'     l'id AniList/MyAnimeList del risultato e' nel catalogo.
//                    Forte: due cataloghi diversi dicono la stessa cosa.
//   match = 'title'  nessun id combacia, ma il titolo AniList somiglia molto a
//                    un anime NSFW senza fonte. Debole: e' un secondo parere,
//                    non una prova.
//
// Il CSV di revisione (`map_hentaiworld_recall.csv`) e' il pannello: ogni riga
// e' una proposta con la sua fiducia. `--apply` scrive le sole righe 'id';
// `--apply-title` aggiunge anche le 'title' (da usare dopo aver guardato il
// CSV). L'assegnazione resta ONE-TO-ONE, come nel matcher principale, perche'
// `record_unique (provider_slug, provider_anime_id)` non permette riusi.
//
// La ricerca AniList e' in cache (`recall_hentaiworld_cache.json`): un giro
// interrotto non ricomincia da capo, e AniList non viene interrogata due volte
// per lo stesso titolo.
//
// Uso:
//   $env:SUPABASE_SERVICE_ROLE_KEY="..."; node scraper/seed/recall_hentaiworld.js
//   node scraper/seed/recall_hentaiworld.js --limit=100
//   node scraper/seed/recall_hentaiworld.js --apply
//   node scraper/seed/recall_hentaiworld.js --apply --apply-title
// ============================================================================

const fs = require('fs')
const path = require('path')
const aw = require('../animeworld.js')

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://sjbstiexythmapxmrfyp.supabase.co'
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY
if (!SERVICE_ROLE_KEY) {
  console.error('manca SUPABASE_SERVICE_ROLE_KEY')
  process.exit(1)
}

const PROVIDER_SLUG = 'hentaiworld'
const SOURCE_TYPE = 'mp4'
const LANGUAGE = 'sub'
const MAX_EPISODES = 200

const ANILIST_API = 'https://graphql.anilist.co'
// AniList: ~90 richieste/minuto. Una ogni 1.1s sta sotto con margine.
const DELAY_MS = 1100
const CANDIDATES = 6

// Soglia per il match 'title': piu' alta di quella del matcher fuzzy, perche'
// qui un match debole non ha nemmeno l'id a sostenerlo.
const ACCEPT_TITLE = Number(process.env.ACCEPT_TITLE ?? '0.86')

const argNum = (name, def) => {
  const a = process.argv.find((x) => x.startsWith(`--${name}=`))
  return a ? Number(a.split('=')[1]) : def
}
const APPLY = process.argv.includes('--apply')
const APPLY_TITLE = process.argv.includes('--apply-title')
const LIMIT = argNum('limit', 0)

const LOG_FILE = path.join(__dirname, 'recall_hentaiworld.log')
const CACHE_FILE = path.join(__dirname, 'recall_hentaiworld_cache.json')
const REVIEW_FILE = path.join(__dirname, 'map_hentaiworld_recall.csv')

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

async function fetchAll(pathAndQuery) {
  const out = []
  let offset = 0
  const page = 1000
  for (;;) {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/${pathAndQuery}`, {
      headers: { ...restHeaders, range: `${offset}-${offset + page - 1}` },
      signal: AbortSignal.timeout(30000),
    })
    if (!res.ok) {
      throw new Error(`GET ${pathAndQuery} -> ${res.status}: ${(await res.text()).slice(0, 300)}`)
    }
    const rows = await res.json()
    out.push(...rows)
    if (rows.length < page) break
    offset += page
  }
  return out
}

// ---------------------------------------------------------------------------
// AniList
// ---------------------------------------------------------------------------

let cache = {}

function loadCache() {
  try {
    cache = JSON.parse(fs.readFileSync(CACHE_FILE, 'utf8'))
  } catch (_) {
    cache = {}
  }
}

/** Il termine da cercare: la variante "(SUB ENG)" cerca il titolo base. */
function searchTerm(title) {
  return String(title ?? '')
    .replace(/\(\s*sub\s*eng\s*\)/i, ' ')
    .replace(/\s+/g, ' ')
    .trim()
}

const SEARCH_QUERY = `query ($search: String) {
  Page(page: 1, perPage: ${CANDIDATES}) {
    media(search: $search, type: ANIME, isAdult: true, sort: SEARCH_MATCH) {
      id
      idMal
      isAdult
      format
      episodes
      title { romaji english native }
      synonyms
    }
  }
}`

async function searchAniList(term) {
  // La cache evita di riinterrogare AniList per un titolo gia' visto: un giro
  // lungo (migliaia di titoli) si puo' interrompere e riprendere senza ripartire
  // da zero, e il provider non paga due volte la stessa domanda.
  const key = aw.cleaned(term).toLowerCase()
  if (key in cache) return cache[key]

  for (let attempt = 1; attempt <= 4; attempt += 1) {
    try {
      const res = await fetch(ANILIST_API, {
        method: 'POST',
        headers: { 'content-type': 'application/json', accept: 'application/json' },
        body: JSON.stringify({ query: SEARCH_QUERY, variables: { search: term } }),
        signal: AbortSignal.timeout(40000),
      })
      if (res.status === 429) {
        log(`  429 su "${term}": pausa 60s (tentativo ${attempt})`)
        await sleep(60000)
        continue
      }
      if (!res.ok) {
        await sleep(5000 * attempt)
        continue
      }
      const data = await res.json()
      if (data?.errors) {
        await sleep(5000 * attempt)
        continue
      }
      const media = (data?.data?.Page?.media ?? []).map((m) => ({
        id: m.id,
        idMal: m.idMal,
        format: m.format,
        episodes: m.episodes,
        title: m.title,
        synonyms: m.synonyms ?? [],
      }))
      cache[key] = media
      fs.writeFileSync(CACHE_FILE, JSON.stringify(cache))
      return media
    } catch (e) {
      await sleep(5000 * attempt)
    }
  }

  // Un guasto di rete non e' un "non trovato": non si mette in cache, cosi' il
  // prossimo giro ritenta invece di ricordare un vuoto che non c'e' stato.
  log(`  ricerca fallita dopo i tentativi: "${term}"`)
  return []
}

// ---------------------------------------------------------------------------
// Confronto titoli
// ---------------------------------------------------------------------------

function isHentai(genres) {
  return Array.isArray(genres) && genres.includes('Hentai')
}

/** Tutte le stringhe-titolo di un anime del catalogo. */
function animeFields(a) {
  return [a.title, a.english_title, a.japanese_title, ...(a.synonyms ?? [])].filter(Boolean)
}

/** Tutte le stringhe-titolo di un media AniList. */
function mediaFields(m) {
  return [m.title?.romaji, m.title?.english, m.title?.native, ...(m.synonyms ?? [])].filter(Boolean)
}

/** Il miglior Dice fra due gruppi di titoli. */
function bestDice(fieldsA, fieldsB) {
  let best = 0
  for (const a of fieldsA) {
    for (const b of fieldsB) {
      const d = aw.dice(aw.cleaned(a).toLowerCase(), aw.cleaned(b).toLowerCase())
      if (d > best) best = d
    }
  }
  return best
}

// ---------------------------------------------------------------------------
// Scritture
// ---------------------------------------------------------------------------

async function upsertEpisodes(animeId, nums) {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/episodes?on_conflict=anime_id,episode_num`,
    {
      method: 'POST',
      headers: { ...restHeaders, prefer: 'resolution=ignore-duplicates,return=minimal' },
      body: JSON.stringify(nums.map((n) => ({ anime_id: animeId, episode_num: n }))),
      signal: AbortSignal.timeout(30000),
    },
  )
  if (!res.ok) throw new Error(`insert episodes HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`)
}

async function episodeIdMap(animeId) {
  const rows = await fetchAll(`episodes?anime_id=eq.${animeId}&select=id,episode_num`)
  return new Map(rows.map((r) => [r.episode_num, r.id]))
}

async function replaceSources(providerId, episodeIds, rows) {
  if (episodeIds.length) {
    const inList = episodeIds.map((id) => `"${id}"`).join(',')
    const del = await fetch(
      `${SUPABASE_URL}/rest/v1/episode_sources?provider_id=eq.${providerId}&episode_id=in.(${inList})`,
      { method: 'DELETE', headers: restHeaders, signal: AbortSignal.timeout(30000) },
    )
    if (!del.ok) throw new Error(`delete sources HTTP ${del.status}: ${(await del.text()).slice(0, 200)}`)
  }
  if (rows.length) {
    const ins = await fetch(`${SUPABASE_URL}/rest/v1/episode_sources`, {
      method: 'POST',
      headers: { ...restHeaders, prefer: 'return=minimal' },
      body: JSON.stringify(rows),
      signal: AbortSignal.timeout(30000),
    })
    if (!ins.ok) throw new Error(`insert sources HTTP ${ins.status}: ${(await ins.text()).slice(0, 200)}`)
  }
}

async function writeAnime(providerId, animeId, episodes) {
  const valid = episodes
    .map((e) => ({ n: Number(e.n), url: e.url }))
    .filter((e) => Number.isInteger(e.n) && e.n > 0 && e.n <= MAX_EPISODES && e.url)
  if (valid.length === 0) return 0

  await upsertEpisodes(animeId, valid.map((e) => e.n))
  const idByNum = await episodeIdMap(animeId)
  const rows = []
  for (const e of valid) {
    const episodeId = idByNum.get(e.n)
    if (!episodeId) continue
    rows.push({
      episode_id: episodeId,
      provider_id: providerId,
      canonical_url: e.url,
      source_url: null,
      source_type: SOURCE_TYPE,
      quality: null,
      language: LANGUAGE,
      is_active: true,
    })
  }
  await replaceSources(providerId, rows.map((r) => r.episode_id), rows)
  return rows.length
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function csvCell(value) {
  const s = String(value ?? '')
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s
}

async function main() {
  loadCache()
  log(`recall ${PROVIDER_SLUG} (ACCEPT_TITLE ${ACCEPT_TITLE})${APPLY ? ' APPLY' : ''}${LIMIT ? ` limit=${LIMIT}` : ''}`)

  const hwRows = await fetchAll(
    `provider_anime_index?provider_slug=eq.${PROVIDER_SLUG}&select=provider_anime_id,title,episodes_count,raw_data`,
  )
  const mappings = await fetchAll(
    `anime_provider_mappings?provider_slug=eq.${PROVIDER_SLUG}&select=provider_anime_id,anime_id,is_dub`,
  )
  const usedHw = new Set(mappings.filter((m) => !m.is_dub).map((m) => m.provider_anime_id))
  const usedAnime = new Set(mappings.map((m) => m.anime_id))
  log(`serie HentaiWorld: ${hwRows.length}, gia' agganciate: ${usedHw.size}`)

  const targets = await fetchAll(
    `anime_missing_sources?select=id,external_id,external_source,title,japanese_title,synonyms,episodes,media_type,english_title,mal_id`,
  )
  const genresById = new Map()
  for (const row of await fetchAll(`anime?select=id,genres`)) genresById.set(row.id, row.genres)

  const hentai = targets.filter((a) => isHentai(genresById.get(a.id)) && !usedAnime.has(a.id))
  const byAnilist = new Map()
  const byMal = new Map()
  for (const a of hentai) {
    if (a.external_source === 'anilist' && a.external_id) byAnilist.set(String(a.external_id), a)
    if (a.mal_id) byMal.set(String(a.mal_id), a)
  }
  log(`anime NSFW senza fonte: ${hentai.length} (${byAnilist.size} con id AniList, ${byMal.size} con id MAL)`)

  const unmatched = hwRows.filter((h) => !usedHw.has(h.provider_anime_id))
  const toSearch = LIMIT ? unmatched.slice(0, LIMIT) : unmatched
  log(`da cercare: ${toSearch.length}`)

  const proposals = []
  let searched = 0
  for (const hw of toSearch) {
    const term = searchTerm(hw.title)
    if (!term) continue
    const media = await searchAniList(term)
    searched += 1
    if (searched % 25 === 0) log(`  ${searched}/${toSearch.length} cercati`)
    if (searched < toSearch.length) await sleep(DELAY_MS)

    let best = null
    for (const m of media ?? []) {
      const strong = byAnilist.get(String(m.id)) ?? (m.idMal ? byMal.get(String(m.idMal)) : null)
      if (strong) {
        // Un id combacia: non serve altro.
        best = { anime: strong, match: 'id', score: 1, media: m }
        break
      }
      // Secondo parere: il titolo AniList combacia con un anime del catalogo,
      // ma serve che somigli anche al titolo del provider.
      const hwFields = [hw.title, String(hw.provider_anime_id).replace(/-/g, ' ')]
      if (bestDice(mediaFields(m), hwFields) < 0.5) continue
      for (const a of hentai) {
        const da = bestDice(mediaFields(m), animeFields(a))
        if (da >= ACCEPT_TITLE && (!best || da > best.score)) {
          best = { anime: a, match: 'title', score: da, media: m }
        }
      }
    }
    if (best) proposals.push({ hw, ...best })
  }

  // One-to-one: prima i match per id, poi per titolo, poi il punteggio.
  proposals.sort(
    (x, y) =>
      (x.match === 'id' ? 0 : 1) - (y.match === 'id' ? 0 : 1) ||
      y.score - x.score ||
      String(x.hw.provider_anime_id).localeCompare(String(y.hw.provider_anime_id)),
  )
  const chosenHw = new Set()
  const chosenAnime = new Set()
  const chosen = []
  for (const p of proposals) {
    if (chosenHw.has(p.hw.provider_anime_id) || chosenAnime.has(p.anime.id)) continue
    chosenHw.add(p.hw.provider_anime_id)
    chosenAnime.add(p.anime.id)
    chosen.push(p)
  }

  const byId = chosen.filter((p) => p.match === 'id').length
  log(`proposte: ${chosen.length} (${byId} per id, ${chosen.length - byId} per titolo)`)

  const lines = ['match,score,anime_id,anime_title,anime_external,hw_id,hw_title,anilist_id,anilist_mal,anilist_title,anilist_format']
  for (const p of chosen) {
    const t = p.media?.title
    lines.push(
      [
        p.match,
        p.score.toFixed(3),
        p.anime.id,
        p.anime.title,
        p.anime.external_id,
        p.hw.provider_anime_id,
        p.hw.title,
        p.media?.id ?? '',
        p.media?.idMal ?? '',
        t?.romaji ?? t?.english ?? t?.native ?? '',
        p.media?.format ?? '',
      ]
        .map(csvCell)
        .join(','),
    )
  }
  fs.writeFileSync(REVIEW_FILE, lines.join('\n') + '\n')
  log(`revisione scritta: ${REVIEW_FILE}`)

  if (!APPLY) {
    log('DRY (nessuna scrittura). Usa --apply per scrivere i match per id.')
    return
  }

  const toApply = chosen.filter((p) => p.match === 'id' || APPLY_TITLE)
  const providerRow = await fetchAll(`providers?select=id&slug=eq.${PROVIDER_SLUG}`)
  if (!providerRow.length) throw new Error(`provider "${PROVIDER_SLUG}" non trovato`)
  const providerId = providerRow[0].id

  const upsert = await fetch(
    `${SUPABASE_URL}/rest/v1/anime_provider_mappings?on_conflict=anime_id,provider_slug,is_dub`,
    {
      method: 'POST',
      headers: { ...restHeaders, prefer: 'resolution=merge-duplicates,return=minimal' },
      body: JSON.stringify(
        toApply.map((p) => ({
          anime_id: p.anime.id,
          provider_slug: PROVIDER_SLUG,
          provider_anime_id: p.hw.provider_anime_id,
          is_dub: false,
          matched_by: 'anilist_recall',
          confidence: p.match === 'id' ? 1 : Number(p.score.toFixed(4)),
        })),
      ),
      signal: AbortSignal.timeout(30000),
    },
  )
  if (!upsert.ok) throw new Error(`upsert mappings HTTP ${upsert.status}: ${(await upsert.text()).slice(0, 200)}`)

  let sources = 0
  for (let i = 0; i < toApply.length; i += 1) {
    const p = toApply[i]
    sources += await writeAnime(providerId, p.anime.id, p.hw.raw_data?.episodes ?? [])
    if ((i + 1) % 25 === 0) log(`  scritti ${i + 1}/${toApply.length}`)
  }
  log(`applicate: ${toApply.length} mapping, ${sources} fonti`)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
