// Harness di prova SENZA database: valida la ricerca/il match AW sui 65 anime
// della vista anime_missing_sources, usando i dati raccolti a mano in
// _targets.json. Non scrive nulla: serve solo a rivedere quali titoli AW copre
// e con quanti episodi, prima di lanciare il seed vero.
const targets = require('./_targets.json')
const { collectCandidates, resolveAnime } = require('./seed/map_animeworld.js')

async function main() {
  const matched = []
  const skipped = []

  for (let i = 0; i < targets.length; i += 1) {
    const a = targets[i]
    // Normalizza verso la forma attesa dallo script (external_id/mal_id/...).
    const anime = {
      external_id: a.e,
      mal_id: a.m,
      external_source: a.s ?? 'anilist',
      title: a.t,
      english_title: a.en,
      japanese_title: null,
      synonyms: [],
      media_type: a.ty,
      episodes: a.ep,
    }
    const label = `[${i + 1}/${targets.length}] ${a.t} (ext ${a.e}${a.s === 'kitsu' ? ' kitsu' : ''})`

    try {
      const candidates = await collectCandidates(anime)
      if (candidates.length === 0) {
        skipped.push(label)
        console.log(`[SKIP] ${label} -> nessun candidato`)
        continue
      }
      const { matches, fetched } = await resolveAnime(anime, candidates)
      if (matches.length === 0) {
        skipped.push(label)
        const top = candidates.slice(0, 3).map((c) => `${c.path}(${c.score.toFixed(2)})`).join(' ')
        console.log(`[SKIP] ${label} -> ${fetched} schede [${top}]`)
        continue
      }
      matched.push({ label, matches })
      console.log(
        `[MATCH] ${label} -> ` +
          matches.map((m) => `${m.path}${m.dub ? ' ita' : ' sub'}:${m.episodes.length}ep`).join(' | '),
      )
    } catch (e) {
      skipped.push(label)
      console.log(`[ERR ] ${label}: ${e.message}`)
    }
  }

  console.log(`\n===== riepilogo =====`)
  console.log(`agganciabili: ${matched.length}`)
  console.log(`senza corrispondenza: ${skipped.length}`)
}

main().catch((e) => {
  console.error('FATAL', e)
  process.exit(1)
})