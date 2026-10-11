// ============================================================================
// fix_eps.js - corregge i conteggi episodi prendendoli da AnimeUnity
// ============================================================================
// AniList lascia `episodes` null per molte serie (soprattutto in onda o OVA).
// Lo script tocca AnimeUnity `info_api` per il conteggio vero e aggiorna
// `anime.episodes` + `external_data.animeunity_eps`. Riga per riga, resumable.
//
// Esecuzione:
//   $env:SUPABASE_SERVICE_ROLE_KEY="..." ; node fix_eps.js
// ============================================================================

const fs = require('fs')
const path = require('path')
const au = require('../animeunity.js')

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://sjbstiexythmapxmrfyp.supabase.co'
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY
const PROGRESS_FILE = path.join(__dirname, 'fix_eps_progress.json')
const DELAY_MS = 900

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function listAnime() {
  const out = []
  let start = 0
  while (true) {
    const url = `${SUPABASE_URL}/rest/v1/anime?select=id,external_data,media_type,status,episodes&offset=${start}&limit=1000`
    const r = await fetch(url, {
      headers: { apikey: SERVICE_ROLE_KEY, authorization: `Bearer ${SERVICE_ROLE_KEY}` },
    })
    if (!r.ok) throw new Error(`anime HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`)
    const rows = await r.json()
    out.push(...rows)
    if (rows.length < 1000) break
    start += 1000
  }
  return out
}

async function countFromAU(auid) {
  for (let attempt = 1; attempt <= 4; attempt += 1) {
    try {
      const session = await au.getSession()
      const url = new URL(`/info_api/${auid}/1`, au.BASE_URL)
      url.searchParams.set('start_range', '1')
      url.searchParams.set('end_range', '1')
      const info = await au.apiJson(url.toString(), au.apiHeaders(session))
      if (Number.isInteger(info.episodes_count)) return info.episodes_count
      return null
    } catch (e) {
      if (attempt === 4) {
        console.log(`  auid ${auid}: skip (${e.status || e.message})`)
        return null
      }
      await sleep(15000 * attempt)
    }
  }
  return null
}

async function patchRow(id, episodes, auid) {
  const body = { episodes, external_data: { animeunity_id: auid, animeunity_eps: episodes } }
  const r = await fetch(`${SUPABASE_URL}/rest/v1/anime?id=eq.${id}`, {
    method: 'PATCH',
    headers: {
      apikey: SERVICE_ROLE_KEY,
      authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      'content-type': 'application/json',
      prefer: 'return=minimal',
    },
    body: JSON.stringify(body),
  })
  if (!r.ok) console.log(`  patch ${id}: HTTP ${r.status}`)
  return r.ok
}

async function main() {
  if (!SERVICE_ROLE_KEY) {
    console.error('manca SUPABASE_SERVICE_ROLE_KEY')
    process.exit(1)
  }

  const rows = await listAnime()
  const eligible = rows.filter(
    (a) =>
      a.external_data?.animeunity_id != null &&
      Number(a.external_data?.animeunity_eps ?? 1) === 1 &&
      a.media_type !== 'Movie' &&
      a.media_type !== 'Music',
  )
  console.log(`righe totali ${rows.length}, da correggere ${eligible.length}`)

  let progress = { i: 0 }
  try {
    progress = JSON.parse(fs.readFileSync(PROGRESS_FILE, 'utf8'))
  } catch {
    /* primo giro */
  }

  let fixed = 0
  let skipped = 0
  for (let i = progress.i; i < eligible.length; i += 1) {
    const a = eligible[i]
    const auid = a.external_data.animeunity_id
    const count = await countFromAU(auid)
    if (count != null && count !== 1) {
      if (await patchRow(a.id, count, auid)) fixed += 1
    } else {
      skipped += 1
    }
    if ((i + 1) % 50 === 0) {
      console.log(`  ${i + 1}/${eligible.length} (fix ${fixed}, skip ${skipped})`)
      await fs.promises.writeFile(PROGRESS_FILE, JSON.stringify({ i: i + 1 }))
    }
    await sleep(DELAY_MS)
  }
  await fs.promises.writeFile(PROGRESS_FILE, JSON.stringify({ i: eligible.length }))
  console.log(`FINE: ${fixed} aggiornati, ${skipped} confermati a 1`)
}

main().catch((e) => {
  console.error('ERR', e.message)
  process.exit(1)
})