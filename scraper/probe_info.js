const BASE = 'https://www.animeunity.so'
const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

async function probe(id) {
  const r = await fetch(`${BASE}/info_api/${id}`, {
    headers: {
      'user-agent': UA,
      accept: 'application/json',
      'x-requested-with': 'XMLHttpRequest',
    },
    redirect: 'follow',
  })
  const j = await r.json()
  console.log(`id=${id} HTTP=${r.status}`, {
    id: j.id,
    anilist_id: j.anilist_id,
    mal_id: j.mal_id,
    dub: j.dub,
    title: j.title,
    title_eng: j.title_eng,
    title_it: j.title_it ?? '(assente)',
    slug: j.slug,
    type: j.type,
    date: j.date,
    episodes_count: j.episodes_count,
  })
}

;(async () => {
  for (const id of [4292, 7192, 3099, 3101, 12, 1, 1469, 21]) {
    try {
      await probe(id)
    } catch (e) {
      console.log(`id=${id} ERR ${e.message}`)
    }
    await new Promise((r) => setTimeout(r, 400))
  }
})()
