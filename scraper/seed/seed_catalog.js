// ============================================================================
// seed_catalog.js - rende guardabili gli anime del catalogo via AnimeUnity
// ============================================================================
//
// Legge `seed/catalog.json` (esportazione di public.anime), matcha ogni titolo
// sull'indice AnimeUnity (sitemap) e genera SQL deterministico per
// `episodes` + `episode_sources`. Le righe sono idempotenti: i vincoli
// `(anime_id, episode_num)` e `(episode_id, canonical_url)` fanno si' che un
// secondo giro non duplichi nulla.
//
// La risoluzione del video e' dinamica (EF resolve-source -> generic_api ->
// scraper -> AnimeUnity), quindi serve solo la pagina canonica dell'anime:
// una riga per episodio, nessun probing per episodio.
//
// Uso:
//   node seed_catalog.js            # dry run: match e stima
//   node seed_catalog.js --write    # scrive i chunk SQL in seed/chunks/
// ============================================================================

const fs = require('fs')
const path = require('path')
const crypto = require('crypto')
const au = require('../animeunity.js')

const PROVIDER_ID = 'da92e844-6560-4038-8431-f609f92b9a21'
const CHUNK_SIZE = 800 // episodi per file SQL
const MAX_EPISODES = 200 // tetto di sicurezza per anime

const dir = __dirname
const catalogPath = path.join(dir, 'catalog.json')
const chunksDir = path.join(dir, 'chunks')

function uuid5(namespaceSeed, name) {
  const hex = crypto
    .createHash('sha1')
    .update(`${namespaceSeed}:${name}`)
    .digest('hex')
    .slice(0, 32)
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(
    16,
    20,
  )}-${hex.slice(20, 32)}`
}

function sqlEscape(value) {
  return String(value).replace(/'/g, "''")
}

function episodeCount(dbCount, infoCount) {
  if (Number.isInteger(infoCount) && infoCount > 0) return Math.min(infoCount, MAX_EPISODES)
  if (Number.isInteger(dbCount) && dbCount > 0) return Math.min(dbCount, MAX_EPISODES)
  return 0
}

async function main() {
  if (!fs.existsSync(catalogPath)) {
    console.error('manca seed/catalog.json')
    process.exit(1)
  }

  const catalog = JSON.parse(fs.readFileSync(catalogPath, 'utf8'))
  const write = process.argv.includes('--write')

  console.log(`catalogo: ${catalog.length} anime`)

  const plan = [] // { animeId, title, auId, canonical, episodes }
  let matched = 0
  let totalEpisodes = 0
  const missingCount = [] // anime matchati ma senza conteggio episodi

  for (const row of catalog) {
    const meta = {
      title: row.title,
      japaneseTitle: row.japanese_title,
      synonyms: row.synonyms ?? [],
      malId: row.external_source === 'mal' ? Number(row.external_id) : null,
    }

    let auId = null
    try {
      auId = await au.findAnimeId(meta)
    } catch (_) {
      auId = null
    }
    if (auId == null) continue

    matched += 1
    const dbCount = Number(row.episodes)

    // Solo se il conteggio manca del tutto si interroga l'API per il numero di
    // episodi; altrimenti ci si fida della cache (source AniList/Kitsu).
    let infoCount = null
    if (!(Number.isInteger(dbCount) && dbCount > 0)) {
      try {
        const session = await au.getSession()
        const url = new URL(`/info_api/${auId}/1`, au.BASE_URL)
        url.searchParams.set('start_range', '1')
        url.searchParams.set('end_range', '1')
        const info = await au.apiJson(url.toString(), au.apiHeaders(session))
        infoCount = Number.isInteger(info.episodes_count) ? info.episodes_count : null
      } catch (_) {
        infoCount = null
      }
      if (infoCount == null) {
        missingCount.push(row.title)
        continue
      }
    }

    const count = episodeCount(dbCount, infoCount)
    if (count === 0) continue

    plan.push({
      animeId: row.id,
      title: row.title,
      auId,
      canonical: `https://www.animeunity.so/anime/${auId}-x`,
      malId: meta.malId,
      episodes: count,
    })
    totalEpisodes += count
  }

  console.log(`match AnimeUnity: ${matched}/${catalog.length}`)
  console.log(`totale episodi da inserire: ${totalEpisodes}`)
  if (missingCount.length) {
    console.log(`anime senza conteggio episodi: ${missingCount.length}`)
  }

  if (!write) return

  // Approccio "mapping + generate_series": il seed scrive SOLO la mappatura
  // anime -> { animeunity_id, animeunity_eps } dentro `external_data` (poche
  // righe), poi gia' in `apply.sql` e' Postgres a fare gli insert con
  // generate_series. Niente letterali da migliaia di righe: il DB genera.
  const mappingPath = path.join(dir, 'seed_mapping.sql')
  const applyPath = path.join(dir, 'seed_apply.sql')

  const lines = []
  const values = plan
    .map((p) => `  ('${p.animeId}', ${p.auId}, ${p.episodes})`)
    .join(',\n')

  const mapping = `-- seed mapping: anime -> { animeunity_id, animeunity_eps }
update public.anime a
set external_data = coalesce(a.external_data, '{}'::jsonb)
  || jsonb_build_object('animeunity_id', v.au_id, 'animeunity_eps', v.eps)
from (values
${values}
) as v(id, au_id, eps)
where a.id = v.id;
`
  fs.writeFileSync(mappingPath, mapping, 'utf8')
  console.log(`scritta ${mappingPath} (${plan.length} anime)`)

  const apply = `-- derive episodi: un riga per numero (generate_series)
insert into public.episodes (anime_id, episode_num)
select a.id, g.n
from public.anime a
cross join generate_series(1, (a.external_data->>'animeunity_eps')::int) g(n)
where a.external_data ? 'animeunity_id'
  and (a.external_data->>'animeunity_eps')::int > 0
on conflict (anime_id, episode_num) do nothing;

-- derive fonti: una per episodio, canonical = pagina anime (risoluzione dinamica)
insert into public.episode_sources
  (episode_id, provider_id, canonical_url, source_type, quality, language, is_active)
select e.id, '${PROVIDER_ID}',
       'https://www.animeunity.so/anime/' || (a.external_data->>'animeunity_id') || '-x',
       'hls', '1080p', 'sub', true
from public.episodes e
join public.anime a on a.id = e.anime_id
where a.external_data ? 'animeunity_id'
on conflict (episode_id, canonical_url) do nothing;
`
  fs.writeFileSync(applyPath, apply, 'utf8')
  console.log(`scritta ${applyPath}`)
}

main().catch((e) => {
  console.error('ERR', e.message)
  process.exit(1)
})