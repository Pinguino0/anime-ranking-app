// ============================================================================
// fetch_relations.js - importa sequel/prequel e altre relazioni da AniList
// ============================================================================
//
// Il dump `anilist_media.jsonl` NON contiene le relazioni: AniList le espone
// solo via GraphQL sul singolo media. Qui si scaricano a lotti di 50 id
// (Page.media(id_in: [...])) e si scrivono in `anime_relations` con service_role.
//
// Gli id da interrogare sono quelli degli anime gia' in catalogo
// (external_source = 'anilist'). La relazione viene salvata sempre con l'id
// AniList del nodo correlato: la risoluzione verso l'id interno la fa l'RPC
// `anime_related`, cosi' la tabella resta valida anche quando il catalogo
// cresce e un correlato non ancora importato entra in un secondo momento.
//
// Esecuzione (il secret NON finisce nel repo):
//   $env:SUPABASE_SERVICE_ROLE_KEY="..." ; node fetch_relations.js
// ============================================================================

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://sjbstiexythmapxmrfyp.supabase.co'
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY
if (!SERVICE_ROLE_KEY) {
  console.error('manca SUPABASE_SERVICE_ROLE_KEY')
  process.exit(1)
}

const ANILIST_API = 'https://graphql.anilist.co'
const IDS_PER_QUERY = 50
const PAGE_SIZE = 1000
const UPSERT_CHUNK = 500
const DELAY_MS = 750

const QUERY = `query ($ids: [Int]) {
  Page(page: 1, perPage: ${IDS_PER_QUERY}) {
    media(id_in: $ids, type: ANIME) {
      id
      relations {
        edges {
          relationType
          node {
            id
            type
            title { romaji english native }
            coverImage { large }
            format
          }
        }
      }
    }
  }
}`

const MEDIA_TYPE = {
  TV: 'TV',
  TV_SHORT: 'TV',
  MOVIE: 'Movie',
  OVA: 'OVA',
  ONA: 'ONA',
  SPECIAL: 'Special',
  MUSIC: 'Music',
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const HEADERS = {
  apikey: SERVICE_ROLE_KEY,
  authorization: `Bearer ${SERVICE_ROLE_KEY}`,
}

// Gli anime in catalogo con origine AniList: id interno + id AniList.
async function fetchCatalogAnime() {
  const rows = []
  for (let offset = 0; ; offset += PAGE_SIZE) {
    const url =
      `${SUPABASE_URL}/rest/v1/anime` +
      `?select=id,external_id&external_source=eq.anilist` +
      `&order=external_id&limit=${PAGE_SIZE}&offset=${offset}`
    const response = await fetch(url, { headers: HEADERS, signal: AbortSignal.timeout(60000) })
    if (!response.ok) {
      throw new Error(`lettura catalogo HTTP ${response.status}: ${(await response.text()).slice(0, 200)}`)
    }
    const chunk = await response.json()
    rows.push(...chunk)
    if (chunk.length < PAGE_SIZE) break
  }
  return rows
}

async function fetchRelations(ids) {
  for (let attempt = 1; attempt <= 5; attempt += 1) {
    try {
      const response = await fetch(ANILIST_API, {
        method: 'POST',
        headers: { 'content-type': 'application/json', accept: 'application/json' },
        body: JSON.stringify({ query: QUERY, variables: { ids } }),
        signal: AbortSignal.timeout(40000),
      })
      if (response.status === 429) {
        console.log(`  429: pausa 60s (tentativo ${attempt})`)
        await sleep(60000)
        continue
      }
      if (!response.ok) {
        console.log(`  HTTP ${response.status}: ${(await response.text()).slice(0, 160)} (tentativo ${attempt})`)
        await sleep(5000 * attempt)
        continue
      }
      const data = await response.json()
      if (data?.errors) {
        console.log(`  errors: ${JSON.stringify(data.errors).slice(0, 200)} (tentativo ${attempt})`)
        await sleep(5000 * attempt)
        continue
      }
      return data.data.Page.media
    } catch (e) {
      console.log(`  errore (tentativo ${attempt}): ${e.message}`)
      await sleep(5000 * attempt)
    }
  }
  return null
}

async function upsertChunk(rows) {
  const response = await fetch(
    `${SUPABASE_URL}/rest/v1/anime_relations?on_conflict=anime_id,related_anilist_id,relation_type`,
    {
      method: 'POST',
      headers: {
        ...HEADERS,
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

function pickTitle(node) {
  return node.title?.english || node.title?.romaji || node.title?.native || null
}

async function main() {
  console.log('lettura catalogo anime (external_source = anilist)...')
  const catalog = await fetchCatalogAnime()
  console.log(`  anime in catalogo: ${catalog.length}`)

  const byAnilist = new Map()
  for (const row of catalog) {
    const id = Number(row.external_id)
    if (Number.isInteger(id)) byAnilist.set(id, row.id)
  }
  const ids = [...byAnilist.keys()]
  console.log(`  id AniList validi: ${ids.length}`)

  const batch = []
  // AniList puo' ripetere lo stesso arco (stessa opera correlata e stesso tipo)
  // dentro lo stesso lotto: PostgREST rifiuta un upsert con la stessa chiave due
  // volte nella stessa command ("cannot affect row a second time"). Il set
  // deduplica prima dell'invio e protegge anche da duplicati fra lotti.
  const seen = new Set()
  let mediaSeen = 0
  let edgesStored = 0
  let upserted = 0
  let failed = 0

  const keyOf = (row) => `${row.anime_id}|${row.relation_type}|${row.related_anilist_id}`

  const flush = async () => {
    if (batch.length === 0) return
    if (await upsertChunk(batch)) {
      upserted += batch.length
      console.log(`  upsert: +${batch.length} (tot ${upserted})`)
    } else {
      failed += batch.length
    }
    batch.length = 0
  }

  for (let i = 0; i < ids.length; i += IDS_PER_QUERY) {
    const idsChunk = ids.slice(i, i + IDS_PER_QUERY)
    const media = await fetchRelations(idsChunk)
    if (media == null) {
      console.log(`  lotto ${i / IDS_PER_QUERY + 1}: saltato dopo i tentativi`)
      continue
    }

    for (const m of media) {
      const animeId = byAnilist.get(m.id)
      if (!animeId) continue
      mediaSeen += 1
      for (const edge of m.relations?.edges ?? []) {
        const node = edge?.node
        if (!node || node.type !== 'ANIME') continue
        const row = {
          anime_id: animeId,
          relation_type: edge.relationType,
          related_anilist_id: node.id,
          related_title: pickTitle(node),
          related_image_url: node.coverImage?.large ?? null,
          related_format: MEDIA_TYPE[node.format] ?? null,
          updated_at: new Date().toISOString(),
        }
        const k = keyOf(row)
        if (seen.has(k)) continue
        seen.add(k)
        edgesStored += 1
        batch.push(row)
        if (batch.length >= UPSERT_CHUNK) await flush()
      }
    }

    const done = Math.min(i + IDS_PER_QUERY, ids.length)
    console.log(`  ${done}/${ids.length} anime letti (${mediaSeen} media)`)
    if (done < ids.length) await sleep(DELAY_MS)
  }
  await flush()

  console.log(`finito: ${edgesStored} relazioni, upsertate ${upserted}, fallite ${failed}`)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
