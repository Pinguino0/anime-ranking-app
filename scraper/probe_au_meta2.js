const au = require('./animeunity.js')
const BASE = 'https://www.animeunity.so'
const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

async function info(id) {
  try {
    const r = await fetch(`${BASE}/info_api/${id}`, {
      headers: { 'user-agent': UA, accept: 'application/json', 'x-requested-with': 'XMLHttpRequest' },
    })
    const j = await r.json()
    return { id, au: j.id, title: j.title, eng: j.title_eng, anilist: j.anilist_id, mal: j.mal_id, dub: j.dub, eps: j.episodes_count }
  } catch (e) {
    return { id, err: e.message }
  }
}

;(async () => {
  console.log('--- /info_api per id noti ---')
  for (const id of [12, 1469, 6381, 2796, 4292, 7192, 3099, 3101]) {
    console.log(JSON.stringify(await info(id)))
  }
  console.log('--- livesearch("Record of Ragnarok") ---')
  for (const q of ['Record of Ragnarok', 'Shuumatsu no Walkure', 'One Piece', 'Naruto']) {
    const recs = await au.liveSearch(q)
    console.log('Q:', q, '->', recs.length)
    for (const r of recs) {
      console.log('   ', JSON.stringify({ id: r.id, anilist_id: r.anilist_id, dub: r.dub, title: r.title }))
    }
    await new Promise((r) => setTimeout(r, 400))
  }
})().catch((e) => console.log('ERR', e.message))
