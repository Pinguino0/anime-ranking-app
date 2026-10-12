// ============================================================================
// hentaiworld - test
// ============================================================================
//
// Cosa coprono
// -----------
// L'adapter conosce ora il caso reale di HentaiWorld (mp4 diretto in pagina,
// iframe solo pubblicitario), piu' un paio di strategie generali per non
// riscrivere tutto se il sito cambia player. I test qui proteggono:
//
//  - il caso reale (forma della pagina letta con `scraper/probe_hentaiworld.js`)
//  - le strategie generali (config `masterPlaylist`, `.m3u8`/`.mp4` scritti
//    nella pagina, iframe da seguire), perche' un cambio di regex si presenta
//    come "la fonte non parte" senza altri sintomi
//  - gli escape delle stringhe JS (`https:\/\/...`), perche' sono la ragione
//    per cui una regex ingenua non trova un URL che invece c'e'
//  - il messaggio di fallimento, perche' deve indicare cosa fare (la probe),
//    non solo che qualcosa non ha funzionato
//
// Il fetch viene stubbato: qui non si vuole una rete, si vuole verificare che
// il testo della pagina venga letto bene.
// ============================================================================

import {
  extractDirectStream,
  extractIframe,
  extractMasterPlaylist,
  extractStream,
  hentaiworldResolver,
} from './hentaiworld.ts'
import type { ResolveRequest, SourceRow } from '../types.ts'

const PAGE = 'https://hentaiworld.example/watch/serie/ep-1'
const CDN = 'https://cdn.example.com/video.m3u8'

function sourceFixture(overrides: Partial<SourceRow> = {}): SourceRow {
  return {
    id: '11111111-2222-3333-4444-555555555555',
    sourceUrl: null,
    canonicalUrl: PAGE,
    sourceType: 'iframe',
    quality: null,
    language: 'sub',
    ...overrides,
  }
}

function requestFixture(): ResolveRequest {
  return {
    source: sourceFixture(),
    canonicalUrl: PAGE,
    provider: { slug: 'hentaiworld', label: 'HentaiWorld (18+)', resolveEndpoint: 'hentaiworld' },
  }
}

/**
 * Sostituisce il fetch globale.
 *
 * L'handler riceve l'URL e decide il corpo: cosi' i test non dipendono da
 * quante volte viene chiesta la sessione (che e' in cache per origin), cosa
 * che renderebbe fragile un semplice elenco di risposte in sequenza.
 */
function stubFetch(handler: (url: string) => string): {
  calls: string[]
  restore: () => void
} {
  const original = globalThis.fetch
  const calls: string[] = []

  globalThis.fetch = ((input: RequestInfo | URL) => {
    const url = String(input)
    calls.push(url)
    return Promise.resolve(
      new Response(handler(url), {
        status: 200,
        headers: { 'Content-Type': 'text/html' },
      }),
    )
  }) as typeof fetch

  return { calls, restore: () => { globalThis.fetch = original } }
}

// ---------------------------------------------------------------------------
// Strategie di estrazione
// ---------------------------------------------------------------------------

Deno.test('un m3u8 scritto in pagina, con slash escapati, viene riconosciuto come hls', () => {
  const html = `<script>var player = { file: "https:\\/\\/cdn.example.com\\/video.m3u8?token=abc\\u0026x=1" }</script>`

  const found = extractDirectStream(html, PAGE)

  assertEquals(found?.url, `${CDN}?token=abc&x=1`)
  assertEquals(found?.sourceType, 'hls')
})

Deno.test('senza m3u8, un mp4 in pagina viene marcato come mp4', () => {
  const html = '<video src="https://cdn.example.com/ep1.mp4"></video>'

  const found = extractDirectStream(html, PAGE)

  assertEquals(found?.url, 'https://cdn.example.com/ep1.mp4')
  assertEquals(found?.sourceType, 'mp4')
})

Deno.test('l\'m3u8 ha la precedenza sul mp4 quando ci sono entrambi', () => {
  const html = `
    <source src="https://cdn.example.com/fallback.mp4">
    <script>sources: [{ file: "https://cdn.example.com/stream.m3u8" }]</script>
  `

  const found = extractStream(html, PAGE)

  assertEquals(found?.url, 'https://cdn.example.com/stream.m3u8')
  assertEquals(found?.sourceType, 'hls')
})

Deno.test('la pagina reale: mp4 diretto, iframe solo pubblicitario', () => {
  // Forma letta sul sito vero: contenitore jwplayer, config con `file: videoUrl`
  // e un solo iframe pubblicitario. Lo stream mp4 e' scritto nella pagina, con
  // gli slash escapati: la strategia diretta deve trovarlo.
  const html = `
    <div id="jwplayer-container" class="aspect-video w-full"></div>
    <script>
      var videoUrl = 'https:\\/\\/server.hcherry.net\\/DDL\\/HENTAIS\\/ITA\\/Serie\\/Serie_Ep_01_SUB_ITA.mp4'
      playlist: [{ file: videoUrl, title: 'Episodio 1' }]
    </script>
    <iframe src="//acceptable.a-ads.com/2445449/?size=Adaptive"></iframe>
  `

  const found = extractStream(html, PAGE)

  assertEquals(found?.sourceType, 'mp4')
  assertEquals(
    found?.url,
    'https://server.hcherry.net/DDL/HENTAIS/ITA/Serie/Serie_Ep_01_SUB_ITA.mp4',
  )
})

Deno.test('una config masterPlaylist costruisce l\'URL con i suoi parametri', () => {
  const html = `
    <script>
      window.masterPlaylist = {
        url: 'https://cdn.example.com/playlist',
        params: { token: 'abc123', expires: '9999' }
      };
    </script>
  `

  const found = extractMasterPlaylist(html, PAGE)

  assertEquals(
    found?.url,
    'https://cdn.example.com/playlist?token=abc123&expires=9999',
  )
  assertEquals(found?.sourceType, 'hls')
})

Deno.test('senza masterPlaylist la config non viene inventata', () => {
  assertEquals(extractMasterPlaylist('<div>niente player</div>', PAGE), null)
})

Deno.test('il primo iframe viene reso assoluto rispetto alla pagina', () => {
  const html = '<div class="player"><iframe src="/embed/123?x=1"></iframe></div>'

  assertEquals(extractIframe(html, PAGE), 'https://hentaiworld.example/embed/123?x=1')
})

// ---------------------------------------------------------------------------
// Adapter
// ---------------------------------------------------------------------------

Deno.test('risolve un m3u8 trovato direttamente nella pagina', async () => {
  const stub = stubFetch((url) => {
    if (url.endsWith('/')) return '<html></html>'
    return `<script>file: "https://cdn.example.com/video.m3u8"</script>`
  })

  try {
    const result = await hentaiworldResolver.resolve(requestFixture())

    assertEquals(result.resolvedUrl, CDN)
    assertEquals(result.sourceType, 'hls')
    assertEquals(result.headers['Referer'], 'https://hentaiworld.example/')
  } finally {
    stub.restore()
  }
})

Deno.test('se la pagina non ha lo stream, segue l\'iframe e lo trova li\'', async () => {
  const inner = 'https://player.example.com/embed/ep-1'

  const stub = stubFetch((url) => {
    if (url.endsWith('/')) return '<html></html>'
    if (url === PAGE) return `<iframe src="${inner}"></iframe>`
    if (url === inner) return '<script>sources: [{ file: "https://cdn.example.com/v.m3u8" }]</script>'
    return '<html></html>'
  })

  try {
    const result = await hentaiworldResolver.resolve(requestFixture())

    assertEquals(result.resolvedUrl, 'https://cdn.example.com/v.m3u8')
    assertEquals(result.sourceType, 'hls')
    assert(stub.calls.includes(inner), `l'iframe non e' stato aperto: ${stub.calls.join(', ')}`)
  } finally {
    stub.restore()
  }
})

Deno.test('un iframe pubblicitario non oscura lo stream in pagina', async () => {
  // Sul sito vero l'unico iframe e' un annuncio: se l'estrazione lo seguisse
  // sprecherebbe un giro di rete e leggerebbe una pagina che non ha il video.
  const html = `
    <script>var videoUrl = 'https:\\/\\/cdn.example.com\\/ep1.mp4'</script>
    <iframe src="//ads.example.com/banner"></iframe>
  `
  const stub = stubFetch(() => html)

  try {
    const result = await hentaiworldResolver.resolve(requestFixture())

    assertEquals(result.resolvedUrl, 'https://cdn.example.com/ep1.mp4')
    assertEquals(result.sourceType, 'mp4')
    assert(
      !stub.calls.some((url) => url.includes('ads.example.com')),
      `l'iframe pubblicitario non va seguito: ${stub.calls.join(', ')}`,
    )
  } finally {
    stub.restore()
  }
})

Deno.test('una pagina senza player fallisce indicando di eseguire la probe', async () => {
  const stub = stubFetch(() => '<html><body>solo testo</body></html>')

  try {
    let message = ''
    try {
      await hentaiworldResolver.resolve(requestFixture())
    } catch (error) {
      message = error instanceof Error ? error.message : String(error)
    }

    assert(message.includes('probe_hentaiworld'), `messaggio inatteso: ${message}`)
  } finally {
    stub.restore()
  }
})

Deno.test('un canonico non valido fallisce con 422 e non tocca la rete', async () => {
  const stub = stubFetch(() => '<html></html>')

  try {
    let status = 0
    try {
      await hentaiworldResolver.resolve({ ...requestFixture(), canonicalUrl: 'non-un-url' })
    } catch (error) {
      status = (error as { status?: number }).status ?? 0
    }

    assertEquals(status, 422)
    assertEquals(stub.calls.length, 0)
  } finally {
    stub.restore()
  }
})

// ---------------------------------------------------------------------------
// Assert duplicati da `index.test.ts`: stesso motivo, nessun file condiviso.
// ---------------------------------------------------------------------------

function assert(condition: boolean, message = 'condizione non vera'): asserts condition {
  if (!condition) throw new Error(message)
}

function assertEquals<T>(actual: T, expected: T, message?: string): void {
  const a = JSON.stringify(actual)
  const b = JSON.stringify(expected)
  if (a === b) return

  throw new Error(message ?? `atteso ${b}, trovato ${a}`)
}
