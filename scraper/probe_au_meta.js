const BASE = 'https://www.animeunity.so'
const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

function snippet(text, re) {
  const m = re.exec(text)
  if (!m) return null
  return text.slice(Math.max(0, m.index - 30), m.index + 80).replace(/\s+/g, ' ')
}

async function probe(id) {
  console.log('==== AnimeUnity id', id, '====')
  try {
    const r = await fetch(`${BASE}/anime/${id}-x`, {
      headers: { 'user-agent': UA, accept: 'text/html' },
      redirect: 'follow',
    })
    const t = await r.text()
    console.log('  page /anime/' + id + '-x HTTP', r.status, 'len', t.length)
    console.log('    anilist_id present:', /anilist_id/.test(t), '| snippet:', snippet(t, /anilist_id/))
    console.log('    mal_id present:', /mal_id/.test(t), '| snippet:', snippet(t, /mal_id/))
    console.log('    dub present:', /["']dub["']/.test(t), '| snippet:', snippet(t, /["']dub["']/))
  } catch (e) {
    console.log('  page ERR', e.message)
  }

  for (const path of [`/info_api/${id}`, `/info_api/${id}/1`]) {
    try {
      const rr = await fetch(BASE + path, {
        headers: { 'user-agent': UA, accept: 'application/json', 'x-requested-with': 'XMLHttpRequest' },
        redirect: 'follow',
      })
      const ct = rr.headers.get('content-type') || ''
      if (ct.includes('json')) {
        const j = await rr.json()
        const a = j.anime || {}
        console.log(
          '  ' + path,
          'HTTP',
          rr.status,
          'topKeys=',
          JSON.stringify(Object.keys(j)),
          'animeKeys=',
          JSON.stringify(Object.keys(a)),
        )
        console.log('      anilist_id=', a.anilist_id, 'mal_id=', a.mal_id, 'dub=', a.dub, 'title=', a.title)
      } else {
        const x = await rr.text()
        console.log('  ' + path, 'HTTP', rr.status, 'non-json:', x.slice(0, 100).replace(/\s+/g, ' '))
      }
    } catch (e) {
      console.log('  ' + path, 'ERR', e.message)
    }
  }
}

;(async () => {
  for (const id of [4292, 7192, 3099, 3101]) await probe(id)
})().catch((e) => console.log('ERR', e.message))
