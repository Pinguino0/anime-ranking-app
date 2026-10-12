// ============================================================================
// map_hentaiworld.js - aggancia gli anime NSFW senza fonte alle serie HentaiWorld
// ============================================================================
//
// Perche' esiste
// --------------
// HentaiWorld non espone id AniList/MAL: l'unico appiglio e' il titolo. Questa
// e' l'eccezione dichiarata alla regola "mai legare per titolo" degli altri
// provider, quindi il matching e' conservativo e si ferma sui casi limpidi:
//
//   - si parte solo dagli anime NSFW (genere Hentai) senza fonte non-mock;
//     sono l'unico contenuto che HentaiWorld puo' avere;
//   - i titoli si normalizzano togliendo punteggiatura E parole di formato
//     ("the", "animation", "ova", "sub"...), che altrimenti farebbero combaciare
//     "X The Animation" con "Y The Animation";
//   - si accetta un titolo quasi identico (Dice >= 0.8) oppure un titolo piu'
//     corto interamente contenuto in quello piu' lungo (es. la serie senza il
//     sottotitolo), con almeno 3 parole significative;
//   - l'assegnazione e' ONE-TO-ONE (vincolo `record_unique`): ogni serie
//     HentaiWorld finisce su un solo anime e viceversa.
//
// Il resto resta in un CSV di revisione, non scritto.
//
// Cosa legge / scrive
// -------------------
//   legge   anime_missing_sources    gli anime senza fonte non-mock
//   legge   anime                    i generi (per filtrare gli NSFW)
//   legge   provider_anime_index     l'indice HentaiWorld (harvest_hentaiworld.js)
//   scrive  anime_provider_mappings  matched_by = 'fuzzy_review'
//           episodes                 1..N dagli episodi HentaiWorld
//           episode_sources          l'URL /watch/<serie>-episode-<n>, mp4
//
// La lingua delle fonti e' 'sub' (HentaiWorld e' sottotitolato). Le varianti
// "(SUB ENG)" restano candidate ma perdono i pareggi contro la versione
// italiana, cosi' vince quella giusta per l'app.
//
// Uso:
//   $env:SUPABASE_SERVICE_ROLE_KEY="..."; node scraper/seed/map_hentaiworld.js
//   node scraper/seed/map_hentaiworld.js --dry     # misura, nessuna scrittura
//   node scraper/seed/map_hentaiworld.js --limit=50
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
// `source_type` non descrive la pagina ma il RISULTATO della risoluzione:
// l'app lo usa solo per decidere se la fonte e' riproducibile in-app
// (`iframe` = apri il provider). HentaiWorld si risolve lato server in un mp4,
// quindi la riga e' `mp4`; il resolver restituisce poi il tipo reale (mp4/hls).
const SOURCE_TYPE = 'mp4'
const LANGUAGE = 'sub'
const MAX_EPISODES = 200

const argNum = (name, def) => {
  const a = process.argv.find((x) => x.startsWith(`--${name}=`))
  return a ? Number(a.split('=')[1]) : def
}
const DRY = process.argv.includes('--dry')
const LIMIT = argNum('limit', 0)

// Soglie. Un titolo con Dice >= ACCEPT e' accettato; sotto, lo e' solo se un
// titolo e' interamente contenuto nell'altro (con abbastanza parole).
const MIN_CAND = Number(process.env.MIN_CAND ?? '0.5')
const ACCEPT = Number(process.env.ACCEPT ?? '0.8')
const MIN_CONTAIN = Number(process.env.MIN_CONTAIN ?? '3')

const LOG_FILE = path.join(__dirname, 'map_hentaiworld.log')
const REVIEW_FILE = path.join(__dirname, 'map_hentaiworld_review.csv')

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

async function fetchAll(pathAndQuery) {
  const out = []
  let offset = 0
  const page = 1000
  for (;;) {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/${pathAndQuery}`, {
      headers: { ...restHeaders, range: `${offset}-${offset + page - 1}` },
      signal: AbortSignal.timeout(30000),
    })
    if (!res.ok) throw new Error(`GET ${pathAndQuery} -> ${res.status}: ${(await res.text()).slice(0, 300)}`)
    const rows = await res.json()
    out.push(...rows)
    if (rows.length < page) break
    offset += page
  }
  return out
}

// ---------------------------------------------------------------------------
// Punteggio
// ---------------------------------------------------------------------------

// Parole di formato/riempimento: se restassero, "X The Animation" e
// "Y The Animation" si somiglierebbero per il solo "the animation".
const STOP = new Set([
  'the', 'a', 'an', 'and', 'of', 'animation',
  'ova', 'oav', 'oad', 'ona', 'special', 'specials', 'movie', 'tv',
  'sub', 'eng', 'ita', 'dub', 'uncensored', 'censored',
])

function tokens(value) {
  return aw
    .cleaned(value)
    .toLowerCase()
    .split(' ')
    .filter((t) => t && !STOP.has(t))
}

/** Le stringhe-titolo di un anime del catalogo. */
function animeFields(anime) {
  return [anime.title, anime.english_title, anime.japanese_title, ...(anime.synonyms ?? [])].filter(Boolean)
}

/** Le stringhe-titolo di una serie HentaiWorld (titolo + slug). */
function hwFields(hw) {
  return [hw.title, String(hw.provider_anime_id).replace(/-/g, ' ')].filter(Boolean)
}

function tokenSets(fields) {
  return fields
    .map((f) => {
      const arr = tokens(f)
      return { arr, set: new Set(arr) }
    })
    .filter((t) => t.arr.length > 0)
}

function isSubset(small, big) {
  if (small.size === 0 || small.size > big.size) return false
  for (const t of small) if (!big.has(t)) return false
  return true
}

/** Il confronto migliore fra due liste di titoli tokenizzati. */
function compare(la, lb) {
  let best = { dice: 0, contained: false, sizeMin: 0 }
  for (const a of la) {
    for (const b of lb) {
      const inter = a.set.size <= b.set.size
        ? [...a.set].filter((t) => b.set.has(t)).length
        : [...b.set].filter((t) => a.set.has(t)).length
      const dice = (2 * inter) / (a.set.size + b.set.size)
      const contained = isSubset(a.set, b.set) || isSubset(b.set, a.set)
      const sizeMin = Math.min(a.set.size, b.set.size)
      if (
        dice > best.dice ||
        (dice === best.dice && Number(contained) > Number(best.contained)) ||
        (dice === best.dice && contained === best.contained && sizeMin > best.sizeMin)
      ) {
        best = { dice, contained, sizeMin }
      }
    }
  }
  return best
}

function isPlausible(m) {
  if (m.dice >= ACCEPT) return true
  if (m.contained && m.sizeMin >= MIN_CONTAIN && m.dice >= MIN_CAND) return true
  return false
}

// ---------------------------------------------------------------------------
// Matching
// ---------------------------------------------------------------------------

function isHentai(genres) {
  return Array.isArray(genres) && genres.includes('Hentai')
}

/**
 * Assegna in modo one-to-one le serie HentaiWorld agli anime NSFW. Si tengono
 * solo le coppie plausibili, ordinate per Dice (a parita', prima il
 * contenimento, poi la variante non-inglese).
 */
function assign(animes, hwRows, usedHwIds = new Set()) {
  const pairs = []
  const bestByAnime = new Map()
  for (const anime of animes) {
    const la = tokenSets(animeFields(anime))
    if (la.length === 0) continue
    for (const hw of hwRows) {
      // Una serie gia' agganciata a un altro anime non si riusa: il vincolo
      // `record_unique (provider_slug, provider_anime_id)` non lo permette.
      if (usedHwIds.has(hw.provider_anime_id)) continue
      const lb = tokenSets(hwFields(hw))
      if (lb.length === 0) continue
      const m = compare(la, lb)
      const prev = bestByAnime.get(anime.id)
      if (!prev || m.dice > prev.m.dice) bestByAnime.set(anime.id, { anime, hw, m })
      if (m.dice >= MIN_CAND && isPlausible(m)) pairs.push({ anime, hw, m })
    }
  }

  const isEng = (p) => (p.hw.raw_data && p.hw.raw_data.language === 'eng' ? 1 : 0)
  pairs.sort(
    (x, y) =>
      y.m.dice - x.m.dice ||
      Number(y.m.contained) - Number(x.m.contained) ||
      y.m.sizeMin - x.m.sizeMin ||
      isEng(x) - isEng(y) ||
      String(x.hw.provider_anime_id).localeCompare(String(y.hw.provider_anime_id)),
  )

  const usedAnime = new Set()
  const usedHw = new Set()
  const chosen = []
  for (const p of pairs) {
    if (usedAnime.has(p.anime.id) || usedHw.has(p.hw.provider_anime_id)) continue
    usedAnime.add(p.anime.id)
    usedHw.add(p.hw.provider_anime_id)
    chosen.push(p)
  }
  return { chosen, bestByAnime }
}

// ---------------------------------------------------------------------------
// Scritture
// ---------------------------------------------------------------------------

async function getProviderId() {
  const rows = await fetchAll(`providers?select=id&slug=eq.${PROVIDER_SLUG}`)
  if (!rows.length) throw new Error(`provider "${PROVIDER_SLUG}" non trovato`)
  return rows[0].id
}

async function upsertMappings(rows) {
  if (rows.length === 0) return
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/anime_provider_mappings?on_conflict=anime_id,provider_slug,is_dub`,
    {
      method: 'POST',
      headers: { ...restHeaders, prefer: 'resolution=merge-duplicates,return=minimal' },
      body: JSON.stringify(rows),
      signal: AbortSignal.timeout(30000),
    },
  )
  if (!res.ok) throw new Error(`upsert mappings HTTP ${res.status}: ${(await res.text()).slice(0, 300)}`)
}

async function upsertEpisodes(animeId, nums) {
  if (nums.length === 0) return
  const rows = [...new Set(nums)].map((n) => ({ anime_id: animeId, episode_num: n }))
  const res = await fetch(`${SUPABASE_URL}/rest/v1/episodes?on_conflict=anime_id,episode_num`, {
    method: 'POST',
    headers: { ...restHeaders, prefer: 'resolution=ignore-duplicates,return=minimal' },
    body: JSON.stringify(rows),
    signal: AbortSignal.timeout(30000),
  })
  if (!res.ok) throw new Error(`upsert episodes HTTP ${res.status}: ${(await res.text()).slice(0, 300)}`)
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
    if (!del.ok) throw new Error(`delete sources HTTP ${del.status}: ${(await del.text()).slice(0, 300)}`)
  }
  if (rows.length) {
    const ins = await fetch(`${SUPABASE_URL}/rest/v1/episode_sources`, {
      method: 'POST',
      headers: { ...restHeaders, prefer: 'return=minimal' },
      body: JSON.stringify(rows),
      signal: AbortSignal.timeout(30000),
    })
    if (!ins.ok) throw new Error(`insert sources HTTP ${ins.status}: ${(await ins.text()).slice(0, 300)}`)
  }
}

/** Scrive episodi + fonti per un anime agganciato. Ritorna il numero di fonti. */
async function writeAnime(anime, providerId, episodes) {
  const valid = episodes
    .map((e) => ({ n: Number(e.n), url: e.url }))
    .filter((e) => Number.isInteger(e.n) && e.n > 0 && e.n <= MAX_EPISODES && e.url)
  if (valid.length === 0) return 0
  if (DRY) return valid.length

  await upsertEpisodes(anime.id, valid.map((e) => e.n))
  const idByNum = await episodeIdMap(anime.id)
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
  log(`map ${PROVIDER_SLUG} (MIN ${MIN_CAND}, ACCEPT ${ACCEPT}, CONTAIN ${MIN_CONTAIN})${DRY ? ' DRY' : ''}`)

  const targets = await fetchAll(
    `anime_missing_sources?select=id,external_id,title,japanese_title,synonyms,episodes,media_type,english_title,mal_id`,
  )
  log(`anime senza fonte: ${targets.length}`)

  const genresById = new Map()
  for (const row of await fetchAll(`anime?select=id,genres`)) genresById.set(row.id, row.genres)
  const hentaiTargets = targets.filter((a) => isHentai(genresById.get(a.id)))
  log(`  di cui NSFW (genere Hentai): ${hentaiTargets.length}`)

  const hwRows = await fetchAll(
    `provider_anime_index?select=provider_anime_id,title,episodes_count,raw_data&provider_slug=eq.${PROVIDER_SLUG}`,
  )
  log(`serie HentaiWorld in indice: ${hwRows.length}`)

  // Le serie gia' agganciate (da run precedenti) si escludono: cosi' rieseguire
  // lo script aggiunge solo abbinamenti nuovi e non viola `record_unique`.
  const existing = await fetchAll(
    `anime_provider_mappings?select=provider_anime_id&provider_slug=eq.${PROVIDER_SLUG}`,
  )
  const usedHw = new Set(existing.map((m) => m.provider_anime_id))
  if (usedHw.size > 0) log(`serie gia' agganciate: ${usedHw.size}`)

  const { chosen: assigned, bestByAnime } = assign(hentaiTargets, hwRows, usedHw)
  const chosen = LIMIT > 0 ? assigned.slice(0, LIMIT) : assigned
  log(`abbinamenti scritti: ${chosen.length} / ${hentaiTargets.length} NSFW`)

  const chosenIds = new Set(chosen.map((p) => p.anime.id))
  const nearMiss = hentaiTargets
    .filter((a) => !chosenIds.has(a.id))
    .map((a) => bestByAnime.get(a.id))
    .filter((p) => p && p.m.dice >= 0.5)

  const lines = ['accepted,score,contained,anime_ext,anime_title,hw_slug,hw_title,hw_eps']
  for (const p of chosen) {
    lines.push(
      ['yes', p.m.dice.toFixed(3), p.m.contained ? 'yes' : 'no', p.anime.external_id, p.anime.title, p.hw.provider_anime_id, p.hw.title, p.hw.episodes_count]
        .map(csvCell)
        .join(','),
    )
  }
  for (const p of nearMiss) {
    lines.push(
      ['no', p.m.dice.toFixed(3), p.m.contained ? 'yes' : 'no', p.anime.external_id, p.anime.title, p.hw.provider_anime_id, p.hw.title, p.hw.episodes_count]
        .map(csvCell)
        .join(','),
    )
  }
  fs.writeFileSync(REVIEW_FILE, lines.join('\n') + '\n')
  log(`revisione scritta: ${REVIEW_FILE} (${chosen.length} si', ${nearMiss.length} no)`)

  if (DRY) {
    const sample = chosen
      .slice(0, 12)
      .map((p) => `${p.m.dice.toFixed(2)} ${p.anime.title}  <=  ${p.hw.title}`)
      .join('\n  ')
    log(`DRY: nessuna scrittura.\n  ${sample}`)
    return
  }

  const providerId = await getProviderId()
  log(`provider ${PROVIDER_SLUG} = ${providerId}`)

  await upsertMappings(
    chosen.map((p) => ({
      anime_id: p.anime.id,
      provider_slug: PROVIDER_SLUG,
      provider_anime_id: p.hw.provider_anime_id,
      is_dub: false,
      matched_by: 'fuzzy_review',
      confidence: Number(p.m.dice.toFixed(4)),
    })),
  )
  log(`mappings scritte: ${chosen.length}`)

  let sources = 0
  for (let i = 0; i < chosen.length; i += 1) {
    const eps = (chosen[i].hw.raw_data && chosen[i].hw.raw_data.episodes) || []
    sources += await writeAnime(chosen[i].anime, providerId, eps)
    if ((i + 1) % 25 === 0) log(`  progresso: ${i + 1}/${chosen.length} anime, ${sources} fonti`)
  }
  log(`fatto: ${chosen.length} anime, ${sources} fonti`)
}

module.exports = { assign, isPlausible, compare, tokens, animeFields, hwFields }

if (require.main === module) {
  main().catch((e) => {
    console.error('ERR', e.message)
    process.exit(1)
  })
}
