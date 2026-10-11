const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

async function fetchOnce() {
  const r = await fetch('https://www.animeunity.so/sitemap.xml', {
    headers: { 'user-agent': UA },
    redirect: 'follow',
    signal: AbortSignal.timeout(30000),
  })
  const xml = await r.text()
  const ids = new Set()
  for (const m of xml.matchAll(/\/anime\/(\d+)-/g)) ids.add(m[1])
  return { len: xml.length, ids }
}

;(async () => {
  const all = new Set()
  for (let i = 1; i <= 8; i += 1) {
    const { len, ids } = await fetchOnce()
    const before = all.size
    for (const id of ids) all.add(id)
    console.log(`fetch ${i}: bytes=${len} ids=${ids.size} | cumulativo=${all.size} (+${all.size - before})`)
    await new Promise((r) => setTimeout(r, 500))
  }
  console.log('TOTALE union:', all.size)
})()
