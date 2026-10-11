// ============================================================================
// remap_duplicates.js - rimappa SOLO gli anime con animeunity_id condiviso
// ============================================================================
//
// I passi B/C (import_anilist.js, match_unmatched.js) hanno assegnato lo stesso
// `animeunity_id` a piu' anime (fuzzy troppo permissivo, nessuna prenotazione):
// 891 id condivisi, 2865 anime. Rilanciare l'intera pipeline toccherebbe anche
// i ~3800 anime corretti (sovrascrivendo sinonimi e animeunity_dub). Qui invece
// si toccano SOLO gli anime coinvolti nei duplicati.
//
// Per ognuno il match passa da AnimeUnity `anilist_id` (esatto, a prova di
// lingua): si cercano i record del titolo e si tiene quello col nostro id.
// Gli id gia' usati da anime NON duplicati sono "prenotati" e non riassegnabili;
// anche gli id assegnati durante questa passata lo sono (niente nuovi doppioni).
// Chi non trova piu' una fonte valida resta senza `animeunity_id` (diventa
// eleggibile per il fallback AnimeWorld di map_animeworld.js).
//
// Uso:
//   $env:SUPABASE_SERVICE_ROLE_KEY="..."; node remap_duplicates.js
//   node remap_duplicates.js --dry                 solo log, nessuna scrittura
//   node remap_duplicates.js --only=187921,127399  pilot su anime specifici
// Ripartibile: prosegue dall'indice in remap_progress.json.
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

const DELAY_MS = 350
const MAX_QUERIES = 12
const PROGRESS_FILE = path.join(__dirname, 'remap_progress.json')
const LOG_FILE = path.join(__dirname, 'remap_duplicates.log')
const DRY = process.argv.includes('--dry')
const ONLY = (process.argv.find((a) => a.startsWith('--only='))?.split('=')[1] ?? '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean)

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

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

// ---------------------------------------------------------------------------
// Helper di matching (gli stessi di match_unmatched.js)
// ---------------------------------------------------------------------------

function cleaned(value) {
  return String(value ?? '')
    .replace(/[\[\(].*?[\]\)]/g, ' ')
    .replace(/&amp;/g, ' ')
    .replace(/&/g, ' ')
    .replace(/[^a-zA-Z0-9À-ÿ']+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
}

function searchQueries(anime) {
  const list = []
  const push = (v) => {
    const c = cleaned(v)
    if (c.length >= 3 && !list.includes(c)) list.push(c)
  }
  push(anime.title)
  push(anime.japanese_title)
  for (const s of anime.synonyms ?? []) push(s)
  const tokens = cleaned(anime.title).split(' ').filter(Boolean)
  // Toglie le prime parole: le serie lunghe ("JoJo no Kimyou na Bouken: Ougon
  // no Kaze") trovano la puntata giusta chiamando la parte.
  for (let cut = 1; cut <= Math.min(3, tokens.length - 1); cut += 1) {
    push(tokens.slice(cut).join(' '))
  }
  // Toglie le parole finali: AnimeUnity non risponde a "Record of Ragnarok II"
  // ma a "Record of Ragnarok", e da li' si trova il record con l'anilist_id
  // giusto (II -> 138056, III -> 187921).
  for (let drop = 1; drop <= 3 && tokens.length - drop >= 2; drop += 1) {
    push(tokens.slice(0, -drop).join(' '))
  }
  // Le ultime n parole sono le piu' caratteristiche (stagione/saga).
  for (const n of [6, 4, 3, 2]) if (tokens.length > n) push(tokens.slice(-n).join(' '))
  return list.slice(0, MAX_QUERIES)
}

function dice(a, b) {
  const ta = (a || '').split(' ').filter(Boolean)
  const tb = (b || '').split(' ').filter(Boolean)
  if (!ta.length || !tb.length) return 0
  const setB = new Set(tb)
  let inter = 0
  for (const w of ta) if (setB.has(w)) inter += 1
  return (2 * inter) / (ta.length + tb.length)
}

function titleScore(anime, record) {
  const fields = []
  for (const v of [record.title, record.title_eng, record.title_it]) {
    const c = cleaned(v)
    if (c) fields.push(c)
  }
  if (typeof record.slug === 'string' && record.slug) {
    const c = cleaned(record.slug.replace(/-/g, ' '))
    if (c) fields.push(c)
  }
  const ours = [anime.title, anime.japanese_title].map(cleaned).filter(Boolean)
  let best = 0
  for (const o of ours) for (const f of fields) best = Math.max(best, dice(o, f))
  return best
}

function typeEquals(anime, record) {
  const norm = (t) => String(t ?? '').toLowerCase().replace(/[_\-\s]+/g, ' ').trim()
  const a = norm(anime.media_type)
  const b = norm(record.type)
  return !!a && a === b
}

function fuzzyAccepted(score, typeEq, epsAgree) {
  if (epsAgree && score >= 0.8) return true
  if (typeEq && score >= 0.9) return true
  if (score >= 0.95) return true
  return false
}

const searchCache = new Map()

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

async function fetchAll() {
  const rows = []
  let offset = 0
  while (true) {
    const url =
      `${SUPABASE_URL}/rest/v1/anime?select=id,external_id,external_source,title,japanese_title,synonyms,episodes,media_type,external_data` +
      `&limit=1000&offset=${offset}`
    const r = await fetch(url, { headers: restHeaders, signal: AbortSignal.timeout(30000) })
    if (!r.ok) throw new Error(`anime HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`)
    const page = await r.json()
    rows.push(...page)
    if (page.length < 1000) break
    offset += 1000
  }
  return rows
}

async function patchAnime(id, body) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/anime?id=eq.${id}`, {
    method: 'PATCH',
    headers: { ...restHeaders, prefer: 'return=minimal' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(30000),
  })
  if (!r.ok) throw new Error(`patch ${id} HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`)
}

// Fase A: scarica in parallelo tutte le query uniche e riempie searchCache.
async function fetchQueries(queries, conc) {
  let cursor = 0
  let done = 0
  let errors = 0
  const started = Date.now()
  const nextIdx = () => {
    const v = cursor
    cursor += 1
    return v
  }
  async function worker() {
    while (true) {
      const idx = nextIdx()
      if (idx >= queries.length) return
      const q = queries[idx]
      if (!searchCache.has(q)) {
        let ok = false
        for (let attempt = 0; attempt < 3 && !ok; attempt += 1) {
          try {
            searchCache.set(q, await au.liveSearch(q))
            ok = true
          } catch (e) {
            if (attempt === 2) {
              errors += 1
              if (errors <= 5) console.log(`  [ERR] "${q}": ${e.message}`)
              searchCache.set(q, [])
            } else {
              await sleep(1000 * (attempt + 1))
            }
          }
        }
      }
      done += 1
      if (done % 200 === 0) {
        const el = ((Date.now() - started) / 1000).toFixed(0)
        console.log(`  fetch ${done}/${queries.length} (${errors} err, ${el}s)`)
      }
      await sleep(DELAY_MS)
    }
  }
  await Promise.all(Array.from({ length: Math.max(1, conc) }, () => worker()))
  const el = ((Date.now() - started) / 1000).toFixed(0)
  console.log(`fetch completato: ${queries.length} query, ${errors} errori, ${el}s`)
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

async function main() {
  const all = await fetchAll()
  const byId = new Map()
  for (const a of all) {
    const auId = a.external_data?.animeunity_id
    if (auId == null) continue
    if (!byId.has(auId)) byId.set(auId, [])
    byId.get(auId).push(a)
  }

  // reserved = id usati da anime NON duplicati (presumibilmente corretti)
  const reserved = new Set()
  const targets = []
  for (const [auId, rows] of byId) {
    if (rows.length === 1) reserved.add(auId)
    else targets.push(...rows)
  }

  const onlyArg = process.argv.find((a) => a.startsWith('--only='))
  const fromArg = Number(process.argv.find((a) => a.startsWith('--from='))?.split('=')[1] ?? 0) || 0
  const limitArg = Number(process.argv.find((a) => a.startsWith('--limit='))?.split('=')[1] ?? 0) || 0
  let list = onlyArg
    ? targets.filter((a) => onlyArg.split('=')[1].split(',').includes(String(a.external_id)))
    : targets
  if (!onlyArg && (fromArg || limitArg)) {
    list = targets.slice(fromArg, limitArg ? fromArg + limitArg : undefined)
  }

  console.log(`anime con animeunity_id condiviso: ${targets.length} (su ${all.length})`)
  console.log(`id prenotati (non duplicati): ${reserved.size}`)
  console.log(`da processare: ${list.length}${DRY ? ' [DRY RUN]' : ''}`)

  // Fase A: raccogli le query uniche e scaricale in parallelo.
  const queryList = []
  const seenQ = new Set()
  for (const anime of list) {
    for (const q of searchQueries(anime)) {
      if (!seenQ.has(q)) {
        seenQ.add(q)
        queryList.push(q)
      }
    }
  }
  console.log(`query uniche: ${queryList.length}`)
  const CONC = Number(process.argv.find((a) => a.startsWith('--concurrency='))?.split('=')[1] ?? 0) || 6
  await fetchQueries(queryList, CONC)

  const taken = new Set()
  let moved = 0
  let cleared = 0
  let unchanged = 0

  for (let i = 0; i < list.length; i += 1) {
    const anime = list[i]
    const target = String(anime.external_id)
    const oldId = anime.external_data.animeunity_id
    let chosen = null
    let how = null
    let best = null

    for (const q of searchQueries(anime)) {
      const records = searchCache.get(q) ?? []

      // Stage 1: match esatto per anilist_id (a prova di lingua).
      const exact = records.filter(
        (r) =>
          r.anilist_id != null &&
          String(r.anilist_id) === target &&
          !reserved.has(r.id) &&
          !taken.has(r.id),
      )
      if (exact.length) {
        chosen = exact.find((r) => r.dub === 0) ?? exact[0]
        how = 'anilist'
        break
      }

      // Stage 2 (accumula): miglior candidato per titolo.
      for (const r of records) {
        if (reserved.has(r.id) || taken.has(r.id)) continue
        const s = titleScore(anime, r)
        if (!best || s > best.score) best = { record: r, score: s }
      }
    }

    if (!chosen && best) {
      const rec = best.record
      const epsAgree =
        anime.episodes > 0 && rec.episodes_count > 0 && anime.episodes === rec.episodes_count
      if (fuzzyAccepted(best.score, typeEquals(anime, rec), epsAgree)) {
        chosen = rec
        how = `fuzzy(${best.score.toFixed(2)})`
      }
    }

    if (chosen) {
      const eps =
        chosen.episodes_count > 0
          ? chosen.episodes_count
          : chosen.real_episodes_count > 0
            ? chosen.real_episodes_count
            : anime.external_data.animeunity_eps
      taken.add(chosen.id)
      const next = {
        ...anime.external_data,
        animeunity_id: chosen.id,
        animeunity_eps: eps,
        animeunity_dub: chosen.dub === 1,
      }
      if (chosen.id === oldId) unchanged += 1
      else moved += 1
      log(`[${i + 1}/${list.length}] ${anime.title} (${target}): ${oldId} -> ${chosen.id} [${how}]`)
      if (!DRY) await patchAnime(anime.id, { external_data: next })
    } else {
      const next = { ...anime.external_data }
      delete next.animeunity_id
      delete next.animeunity_eps
      delete next.animeunity_dub
      cleared += 1
      log(`[${i + 1}/${list.length}] ${anime.title} (${target}): ${oldId} -> CLEAR (nessuna fonte)`)
      if (!DRY) await patchAnime(anime.id, { external_data: next })
    }

    if (!DRY && i % 25 === 0) fs.writeFileSync(PROGRESS_FILE, JSON.stringify({ i }))
  }

  log(`fine: spostati ${moved}, invariati ${unchanged}, azzerati ${cleared}`)
}

main().catch((e) => {
  console.error('ERR', e.message)
  process.exit(1)
})
