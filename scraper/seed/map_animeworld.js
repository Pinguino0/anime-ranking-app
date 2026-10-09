// ============================================================================
// map_animeworld.js - aggancia ad AnimeWorld gli anime rimasti senza fonte
// ============================================================================
//
// Chiude il buco lasciato da AnimeUnity: la vista `anime_missing_sources`
// elenca gli anime del catalogo senza nessuna fonte attiva (escluso `mock`).
// Per ognuno si cerca il titolo su AnimeWorld, si apre la scheda dei candidati
// e si tiene SOLO chi espone lo stesso id AniList (o MAL) del catalogo.
//
// Perche' il match e' per id e non per titolo
// -------------------------------------------
// AnimeWorld non ha una ricerca JSON (gli endpoint POST /livesearch sono
// protetti): si usano le pagine HTML pubbliche. Il titolo da solo e' debole —
// AW nomina le opere in italiano/inglese mentre il catalogo e' romaji — e un
// match sbagliato scrive fonti su un anime che non c'entra. La scheda di ogni
// anime, pero', linka MyAnimeList e AniList: si confronta l'id, che e' esatto,
// e il titolo serve solo a ordinare i candidati (per non aprire 20 pagine a
// caso). Stesso principio di AnimeUnity (`anilist_id`).
//
// Cosa scrive
// -----------
//   episodes         una riga per episodio (episode_num, unique per anime)
//   episode_sources  l'indirizzo canonico di quell'episodio su AnimeWorld
//                    (source_url NULL, canonical_url = /play/<slug>/<ep>,
//                    source_type mp4, provider mio_provider)
//
// Preferenza lingua: se l'opera ha sia la versione doppiata (-ita) sia la
// sottotitolata, si mettono ENTRAMBE come fonti dello stesso episodio (come
// Attack on Titan), con `language` `ita`/`sub`. Se ne esiste una sola, quella.
//
// Uso:
//   $env:SUPABASE_SERVICE_ROLE_KEY = "..."
//   node map_animeworld.js            # scrive
//   $env:DRY_RUN = "1"; node map_animeworld.js   # mostra soltanto
//   $env:ONLY = "2001,20"; node map_animeworld.js  # solo alcuni external_id
//   $env:FALLBACK = "1"; $env:DRY_RUN = "1"; node map_animeworld.js
//       # misura il ripiego per titolo (stessa opera con lo stesso numero di
//       # episodi) sulle righe che nessun id aggancia. Non scrive se manca
//       # FALLBACK_WRITE=1.
//
// E' idempotente: rilanciarlo aggiorna le stesse fonti invece di duplicarle.
// ============================================================================

const fs = require('fs')
const path = require('path')
const aw = require('../animeworld.js')

const SUPABASE_URL = process.env.SUPABASE_URL ?? 'https://sjbstiexythmapxmrfyp.supabase.co'
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY

const DRY_RUN = process.env.DRY_RUN === '1'
// Ripiego per titolo: DISATTIVATO di default. Serve solo a misurare quanto
// renderebbe, perche' il match per titolo puo' agganciare un'edizione diversa
// (es. la serie principale al posto dello special). Finche' FALLBACK_WRITE!=1
// i suoi esiti restano di sola misura, anche senza DRY_RUN.
const FALLBACK = process.env.FALLBACK === '1'
const FALLBACK_WRITE = process.env.FALLBACK_WRITE === '1'
const FALLBACK_MIN_SCORE = Number(process.env.FALLBACK_MIN_SCORE ?? '0.9')
const ONLY = (process.env.ONLY ?? '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean)

// Quante pagine candidato aprire al massimo per anime: la prima si prende di
// solito al primo/secondo tentativo, il tetto protegge dai titoli generici
// ("Gintama") dove la ricerca restituisce decine di schede.
const MAX_PAGE_FETCHES = 14
// Quante query di ricerca provare (dalla lista ordinata di buildQueries).
const MAX_QUERIES = 12
const DELAY_MS = 350

const PROVIDER_SLUG = 'mio_provider'
const SOURCE_TYPE = 'mp4'
const QUALITY = '1080p'

const LOG_FILE = path.join(__dirname, 'map_animeworld.log')
const PROGRESS_FILE = path.join(__dirname, 'map_animeworld_progress.json')

const restHeaders = {
  apikey: SERVICE_ROLE_KEY,
  authorization: `Bearer ${SERVICE_ROLE_KEY}`,
  'content-type': 'application/json',
}

function log(line) {
  const ts = new Date().toISOString().replace('T', ' ').slice(0, 19)
  const out = `[${ts}] ${line}`
  console.log(out)
  fs.appendFileSync(LOG_FILE, out + '\n')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// ---------------------------------------------------------------------------
// Letture
// ---------------------------------------------------------------------------

async function listTargets() {
  const url =
    `${SUPABASE_URL}/rest/v1/anime_missing_sources` +
    `?select=id,external_id,external_source,title,japanese_title,synonyms,episodes,media_type,status,english_title,mal_id` +
    `&order=external_id`
  const response = await fetch(url, { headers: restHeaders, signal: AbortSignal.timeout(30000) })
  if (!response.ok) {
    throw new Error(`anime_missing_sources HTTP ${response.status}: ${(await response.text()).slice(0, 300)}`)
  }
  let rows = await response.json()
  if (ONLY.length) {
    const set = new Set(ONLY)
    rows = rows.filter((r) => ONLY.includes(String(r.external_id)) || ONLY.includes(String(r.id)))
  }
  return rows
}

async function getProviderId() {
  const url = `${SUPABASE_URL}/rest/v1/providers?select=id&slug=eq.${PROVIDER_SLUG}`
  const response = await fetch(url, { headers: restHeaders, signal: AbortSignal.timeout(30000) })
  if (!response.ok) {
    throw new Error(`provider HTTP ${response.status}: ${(await response.text()).slice(0, 300)}`)
  }
  const rows = await response.json()
  if (!rows.length) throw new Error(`provider "${PROVIDER_SLUG}" non trovato`)
  return rows[0].id
}

// ---------------------------------------------------------------------------
// Candidati e match
// ---------------------------------------------------------------------------

/** Le nostre stringhe-titolo su cui confrontare i candidati. */
function ourFields(anime) {
  return [anime.title, anime.english_title, anime.japanese_title]
    .map(aw.cleaned)
    .filter(Boolean)
}

/**
 * Query di ricerca, dalla piu' specifica alla piu' permissiva.
 *
 * Ordine importante: i troncamenti in coda del titolo vengono PRIMA dei
 * sinonimi. AW spesso numera diversamente il catalogo (il nostro "3rd Season"
 * e' il suo "3"), quindi la query che azzecca e' il titolo accorciato
 * ("Re:Zero kara Hajimeru Isekai Seikatsu" -> 13 risultati, incluse le
 * stagioni 3 e 4). Se i sinonimi (che AW quasi mai indicizza) riempissero il
 * tetto MAX_QUERIES, quelle query utili non verrebbero mai provate.
 */
function buildQueries(anime) {
  const out = []
  const push = (v) => {
    const c = aw.queryText(v)
    if (c.length >= 3 && !out.includes(c)) out.push(c)
  }

  const titleTokens = aw.queryText(anime.title).split(' ').filter(Boolean)

  push(anime.title)
  for (let drop = 1; drop <= 4 && titleTokens.length - drop >= 2; drop += 1) {
    push(titleTokens.slice(0, -drop).join(' '))
  }
  for (let cut = 1; cut <= 2 && titleTokens.length - cut >= 2; cut += 1) {
    push(titleTokens.slice(cut).join(' '))
  }

  push(anime.english_title)
  const enTokens = aw.queryText(anime.english_title).split(' ').filter(Boolean)
  for (let drop = 1; drop <= 2 && enTokens.length - drop >= 2; drop += 1) {
    push(enTokens.slice(0, -drop).join(' '))
  }

  for (const s of anime.synonyms ?? []) push(s)
  push(anime.japanese_title)

  return out.slice(0, MAX_QUERIES)
}

function candidateScore(anime, candidate) {
  const ours = ourFields(anime)
  const fields = [candidate.name, candidate.jtitle, candidate.slug.replace(/-/g, ' ')]
    .map(aw.cleaned)
    .filter(Boolean)
  let best = 0
  for (const o of ours) {
    for (const f of fields) best = Math.max(best, aw.dice(o, f))
  }
  return best
}

/** Raccoglie i candidati di tutte le query, tenendo il punteggio migliore. */
async function collectCandidates(anime) {
  const byPath = new Map()
  for (const query of buildQueries(anime)) {
    let found = []
    try {
      found = await aw.search(query)
    } catch (e) {
      log(`    ricerca "${query}" ERR: ${e.message}`)
      continue
    }
    for (const c of found) {
      const score = candidateScore(anime, c)
      const prev = byPath.get(c.path)
      if (!prev || score > prev.score) byPath.set(c.path, { ...c, score })
    }
    await sleep(DELAY_MS)
  }
  return [...byPath.values()].sort((a, b) => b.score - a.score)
}

// Cache delle pagine gia' aperte (stesso path puo' ricorrere fra anime).
const pageCache = new Map()

async function openPage(animePath) {
  if (pageCache.has(animePath)) return pageCache.get(animePath)
  const page = await aw.episodes(animePath)
  pageCache.set(animePath, page)
  return page
}

/**
 * Trova tutte le pagine AnimeWorld che sono DAVVERO la nostra opera (id AniList
 * o MAL combacia) e le restituisce con i loro episodi. Si ferma presto: appena
 * ha una versione doppiata, o dopo MAX_PAGE_FETCHES schede aperte.
 */
async function resolveAnime(anime, candidates) {
  const target = String(anime.external_id)
  const targetMal = anime.mal_id != null ? String(anime.mal_id) : null
  const matches = []
  let fetched = 0

  for (const cand of candidates) {
    if (fetched >= MAX_PAGE_FETCHES) break
    if (matches.length > 0 && fetched >= 6 && cand.score < 0.5) break

    fetched += 1
    let page
    try {
      page = await openPage(cand.path)
    } catch (e) {
      log(`    scheda ${cand.path} ERR: ${e.message}`)
      continue
    }
    await sleep(DELAY_MS)

    const byAnilist = page.anilistId != null && String(page.anilistId) === target
    const byMal = targetMal && page.malId != null && String(page.malId) === targetMal
    if (!byAnilist && !byMal) continue

    if (page.episodes.length === 0) continue
    if (matches.some((m) => m.path === cand.path)) continue
    matches.push({ ...cand, ...page })

    if (matches.some((m) => m.dub)) break
  }

  return { matches, fetched }
}

/**
 * Ripiego per titolo, solo per misurazione (FALLBACK=1). Quando nessun id
 * combacia, accetta il primo candidato con similarita' altissima E lo stesso
 * numero di episodi del catalogo. Ogni match viene marcato `fallback: true` per
 * poterlo contare a parte senza confonderlo con gli agganci certi per id.
 */
async function resolveByTitle(anime, candidates) {
  const targetEps = anime.episodes
  for (const cand of candidates) {
    if (cand.score < FALLBACK_MIN_SCORE) break
    let page
    try {
      page = await openPage(cand.path)
    } catch {
      continue
    }
    await sleep(DELAY_MS)
    if (!page.episodes || page.episodes.length === 0) continue
    if (targetEps != null && page.episodes.length !== targetEps) continue
    return [{ ...cand, ...page, fallback: true }]
  }
  return []
}

// ---------------------------------------------------------------------------
// Scritture
// ---------------------------------------------------------------------------

async function upsertEpisodes(animeId, nums) {
  const rows = nums.map((n) => ({ anime_id: animeId, episode_num: aw.baseNum(n) }))
  const unique = [...new Map(rows.map((r) => [r.episode_num, r])).values()]
  const response = await fetch(
    `${SUPABASE_URL}/rest/v1/episodes?on_conflict=anime_id,episode_num`,
    {
      method: 'POST',
      headers: { ...restHeaders, prefer: 'resolution=ignore-duplicates,return=minimal' },
      body: JSON.stringify(unique),
      signal: AbortSignal.timeout(30000),
    },
  )
  if (!response.ok) {
    throw new Error(`upsert episodes HTTP ${response.status}: ${(await response.text()).slice(0, 300)}`)
  }
}

async function episodeIdMap(animeId) {
  const response = await fetch(
    `${SUPABASE_URL}/rest/v1/episodes?anime_id=eq.${animeId}&select=id,episode_num`,
    { headers: restHeaders, signal: AbortSignal.timeout(30000) },
  )
  if (!response.ok) {
    throw new Error(`lista episodes HTTP ${response.status}: ${(await response.text()).slice(0, 300)}`)
  }
  const rows = await response.json()
  return new Map(rows.map((r) => [r.episode_num, r.id]))
}

async function replaceSources(providerId, episodeIds, rows) {
  if (episodeIds.length) {
    const inList = episodeIds.map((id) => `"${id}"`).join(',')
    const del = await fetch(
      `${SUPABASE_URL}/rest/v1/episode_sources?provider_id=eq.${providerId}&episode_id=in.(${inList})`,
      { method: 'DELETE', headers: restHeaders, signal: AbortSignal.timeout(30000) },
    )
    if (!del.ok) {
      throw new Error(`delete sources HTTP ${del.status}: ${(await del.text()).slice(0, 300)}`)
    }
  }

  if (rows.length) {
    const ins = await fetch(`${SUPABASE_URL}/rest/v1/episode_sources`, {
      method: 'POST',
      headers: { ...restHeaders, prefer: 'return=minimal' },
      body: JSON.stringify(rows),
      signal: AbortSignal.timeout(30000),
    })
    if (!ins.ok) {
      throw new Error(`insert sources HTTP ${ins.status}: ${(await ins.text()).slice(0, 300)}`)
    }
  }
}

/**
 * Scrive episodi e fonti per un anime agganciato. `pages` = versioni AW trovate
 * (sub e/o ita). L'elenco episodi lo detta la versione piu' completa; per ogni
 * episodio si aggiunge una fonte per ciascuna versione che lo contiene.
 */
async function writeAnime(anime, providerId, pages) {
  const nums = pages
    .flatMap((p) => p.episodes.map((e) => e.num))
    .filter((n) => aw.baseNum(n) > 0)
  const episodeCount = new Set(nums.map((n) => aw.baseNum(n))).size

  if (DRY_RUN) {
    const sources = pages.reduce(
      (sum, p) => sum + p.episodes.filter((e) => aw.baseNum(e.num) > 0).length,
      0,
    )
    return { episodes: episodeCount, sources }
  }

  await upsertEpisodes(anime.id, nums)
  const idByNum = await episodeIdMap(anime.id)

  const rows = []
  for (const p of pages) {
    const language = p.dub ? 'ita' : 'sub'
    for (const ep of p.episodes) {
      const num = aw.baseNum(ep.num)
      if (num <= 0) continue
      const episodeId = idByNum.get(num)
      if (!episodeId) continue
      rows.push({
        episode_id: episodeId,
        source_url: null,
        source_type: SOURCE_TYPE,
        quality: QUALITY,
        language,
        is_active: true,
        canonical_url: ep.href,
        provider_id: providerId,
      })
    }
  }

  await replaceSources(providerId, [...idByNum.values()], rows)
  return { episodes: episodeCount, sources: rows.length }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  if (!SERVICE_ROLE_KEY) {
    console.error('Manca SUPABASE_SERVICE_ROLE_KEY nell\'ambiente.')
    process.exit(1)
  }

  const targets = await listTargets()
  const providerId = await getProviderId()
  log(`provider ${PROVIDER_SLUG} = ${providerId}`)
  log(`da processare: ${targets.length}${ONLY.length ? ` (filtro ONLY: ${ONLY.join(',')})` : ''}`)
  if (DRY_RUN) log('DRY_RUN attivo: nessuna scrittura sul database.')
  if (FALLBACK) {
    log(
      `FALLBACK attivo (soglia ${FALLBACK_MIN_SCORE}, ` +
      `${FALLBACK_WRITE ? 'SCRIVE' : 'sola misura'})`,
    )
  }

  let matched = 0
  let fallbackMatched = 0
  let skipped = 0
  for (let i = 0; i < targets.length; i += 1) {
    const anime = targets[i]
    const label = `[${i + 1}/${targets.length}] ${anime.title} (ext ${anime.external_id}, ${anime.episodes ?? '-'}ep)`

    try {
      const candidates = await collectCandidates(anime)
      if (candidates.length === 0) {
        skipped += 1
        log(`  [SKIP] ${label} -> nessun candidato AW`)
        continue
      }

      let { matches, fetched } = await resolveAnime(anime, candidates)
      let viaFallback = false
      if (matches.length === 0 && FALLBACK) {
        matches = await resolveByTitle(anime, candidates)
        viaFallback = matches.length > 0
      }

      if (matches.length === 0) {
        skipped += 1
        const best = candidates
          .slice(0, 3)
          .map((c) => `${c.path}(${c.score.toFixed(2)})`)
          .join(' ')
        log(`  [SKIP] ${label} -> ${fetched} schede, nessun id combacia [top ${best}]`)
        continue
      }

      const versions = matches
        .map((m) => `${m.path}${m.dub ? ' ita' : ' sub'}:${m.episodes.length}ep`)
        .join(', ')

      if (viaFallback && !FALLBACK_WRITE) {
        fallbackMatched += 1
        const s = matches[0].score.toFixed(2)
        log(`  [FALLBACK-MISURA] ${label} -> titolo ${s} [${versions}]`)
        continue
      }

      const { episodes, sources } = await writeAnime(anime, providerId, matches)
      matched += 1
      log(
        `  [${viaFallback ? 'FALLBACK' : 'MATCH'}] ${label} -> ${matches.length} versione(i) ` +
        `[${versions}] episodi:${episodes} fonti:${sources}`,
      )
    } catch (e) {
      log(`  [ERR] ${label}: ${e.message}`)
    }

    if (!DRY_RUN) {
      fs.writeFileSync(PROGRESS_FILE, JSON.stringify({ i: i + 1 }))
    }
  }

  log(
    `finito: ${matched} agganciati per id, ${fallbackMatched} per titolo (misura), ` +
    `${skipped} senza corrispondenza su AnimeWorld`,
  )
}

module.exports = { collectCandidates, resolveAnime, ourFields, buildQueries, openPage }

if (require.main === module) {
  main().catch((e) => {
    console.error('ERR', e.message)
    process.exit(1)
  })
}