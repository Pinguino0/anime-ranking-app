// ============================================================================
// probe_hentaiworld.js - cosa serve sapere per scrivere l'extractor di HentaiWorld
// ============================================================================
//
// A differenza di AnimeUnity (API JSON + sitemap) e AnimeWorld (pagine HTML) qui
// non si sa ancora COME il sito serve il video. Questo script non risolve niente:
// apre una pagina episodio e stampa tutto cio' che serve a decidere come
// scrivere l'adapter:
//
//   - che URL diventa la pagina dopo i redirect (il canonico vero)
//   - gli iframe presenti (il player spesso e' su un altro host)
//   - gli URL .m3u8/.mp4 scritti nella pagina, anche con gli slash escapati
//   - le config dei player piu' diffusi (masterPlaylist, sources, file, jwplayer,
//     playerjs) e gli id che le collegano (`data-id`, `data-episode`)
//   - gli endpoint che la pagina chiama in JS (fetch/ajax/api), per capire se il
//     video arriva dopo una seconda richiesta
//
// Uso
// ---
//   node scraper/probe_hentaiworld.js <url-pagina-episodio> [altre-url...]
//   node scraper/probe_hentaiworld.js --raw <url>     # salva anche l'HTML
//
// Gli URL li passi tu: qui non c'e' nessuna lista di link hardcoded, cosi' il
// probe non contiene indirizzi di contenuti.
// ============================================================================

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

const args = process.argv.slice(2)
const saveRaw = args.includes('--raw')
const urls = args.filter((a) => a !== '--raw')

if (urls.length === 0) {
  console.log('Uso: node scraper/probe_hentaiworld.js [--raw] <url-pagina-episodio> [...]')
  process.exit(1)
}

/** Riga di contesto attorno a un match, per vedere il codice e non solo l'hit. */
function context(text, re, before = 40, after = 90) {
  const m = re.exec(text)
  if (!m) return null
  const start = Math.max(0, m.index - before)
  return text.slice(start, m.index + after).replace(/\s+/g, ' ').trim()
}

function allMatches(text, re) {
  const out = []
  let m
  while ((m = re.exec(text)) !== null) {
    out.push(m[1] ?? m[0])
    if (out.length >= 10) break
  }
  return out
}

/** Raccoglie i cookie della home: alcune pagine rispondono 403 senza sessione. */
async function getCookie(origin) {
  try {
    const res = await fetch(`${origin}/`, {
      headers: { 'user-agent': UA, accept: 'text/html' },
      redirect: 'follow',
    })
    const raw = res.headers.getSetCookie?.() ?? []
    return raw.map((c) => c.split(';')[0]).join('; ')
  } catch {
    return ''
  }
}

async function probe(url) {
  console.log(`\n=== ${url} ===`)

  let origin
  try {
    origin = new URL(url).origin
  } catch {
    console.log('  !! non e\' un URL valido')
    return
  }

  const cookie = await getCookie(origin)
  let res
  try {
    res = await fetch(url, {
      headers: {
        'user-agent': UA,
        accept: 'text/html,application/xhtml+xml',
        'accept-language': 'it-IT,it;q=0.9',
        ...(cookie ? { cookie } : {}),
      },
      redirect: 'follow',
    })
  } catch (error) {
    console.log(`  !! fetch fallito: ${error.message}`)
    return
  }

  const html = await res.text()
  console.log(`  HTTP ${res.status} - URL finale: ${res.url}`)
  console.log(`  cookie di sessione: ${cookie ? 'si' : 'no'}`)
  console.log(`  lunghezza HTML: ${html.length}`)

  const title = context(html, /<title[^>]*>([^<]{0,120})/i, 0, 140)
  if (title) console.log(`  title: ${title}`)

  // Player su un altro host: e' la prima cosa da guardare.
  const iframes = allMatches(html, /<iframe\b[^>]*\bsrc=["']([^"']+)["']/gi)
  console.log(`  iframe (${iframes.length}):`)
  for (const src of iframes) console.log(`    - ${src}`)

  // Stream scritto in pagina (escape inclusi).
  const unescaped = html.replace(/\\\//g, '/').replace(/\\u0026/gi, '&')
  const streams = [
    ...allMatches(unescaped, /(https?:\/\/[^"'\s<>\\]+\.m3u8[^"'\s<>\\]*)/gi),
    ...allMatches(unescaped, /(https?:\/\/[^"'\s<>\\]+\.mp4[^"'\s<>\\]*)/gi),
  ]
  console.log(`  stream diretti in pagina (${streams.length}):`)
  for (const s of streams) console.log(`    - ${s}`)

  // Config dei player piu' diffusi.
  const configMarkers = [
    'masterPlaylist',
    'window.video',
    'jwplayer',
    'playerjs',
    '"sources"',
    "'sources'",
    'file:',
    'data-id',
    'data-episode',
    'data-video',
    'data-file',
  ]
  console.log('  marker di player:')
  for (const marker of configMarkers) {
    const snippet = context(html, new RegExp(marker.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i'))
    if (snippet) console.log(`    [${marker}] ${snippet}`)
  }

  // Endpoint chiamati in JS: se il video non e' in pagina, arriva da qui.
  const endpoints = allMatches(
    unescaped,
    /(?:fetch|axios(?:\.get)?|\.(?:get|post)|url)\s*\(\s*["']([^"']{1,160})["']/gi,
  ).filter((value) => value.startsWith('/') || value.startsWith('http'))
  console.log(`  endpoint chiamati in JS (${endpoints.length}):`)
  for (const endpoint of endpoints.slice(0, 15)) console.log(`    - ${endpoint}`)

  if (saveRaw) {
    const name = `probe_hentaiworld_${Date.now()}.html`
    const { writeFileSync } = await import('node:fs')
    writeFileSync(name, html)
    console.log(`  HTML salvato in: ${name}`)
  }
}

// Il package dello scraper e' CommonJS: niente top-level await, si avvolge in
// una IIFE come fanno gli altri probe (`probe_au_meta.js`).
;(async () => {
  for (const url of urls) {
    await probe(url)
  }
  console.log('\nFatto. Incolla qui l\'output: da iframe/stream/marker si ricava l\'adapter.')
})().catch((error) => {
  console.log(`ERR: ${error.message}`)
  process.exitCode = 1
})
