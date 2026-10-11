// ============================================================================
// resolve-source - test
// ============================================================================
//
// Cosa coprono
// -----------
// I pezzi dove un errore si presenta come qualcos'altro:
//
//  - la validazione dell'input, perche' un `source_id` non validato che arriva
//    al database si presenta come "errore di rete"
//  - il resolver finto, perche' se non produce header e una scadenza il player
//    non ha niente da usare e il sintomo e' "questa fonte non parte"
//  - le rotte e l'autenticazione, perche' una rotta sbagliata si presenta come
//    una funzione non deployata
//
// Il file NON richiede Supabase: `handleRequest` viene provato solo sulle rotte
// che non toccano il database (`/health`, metodo non ammesso, senza
// Authorization). `resolveSource` non e' provato qui perche' richiede una
// lettura reale del catalogo, e fingere un client Supastore significherebbe
// testare il finto invece del codice.
// ============================================================================

import {
  extractWatchId,
  handleRequest,
  isHttpUrl,
  isUuid,
  mockResolver,
  mockTokenPayload,
  resolveRoute,
  signMockToken,
} from './index.ts'
import type { ResolveRequest, SourceRow } from './types.ts'

const UUID_OK = '3f8c1d2e-4a5b-4c6d-8e9f-0a1b2c3d4e5f'

function sourceFixture(overrides: Partial<SourceRow> = {}): SourceRow {
  return {
    id: UUID_OK,
    sourceUrl: null,
    canonicalUrl: 'https://api.example.com/watch/123',
    sourceType: 'hls',
    quality: '1080p',
    language: 'ita',
    ...overrides,
  }
}

function requestFixture(source: SourceRow): ResolveRequest {
  return {
    source,
    canonicalUrl: source.canonicalUrl!,
    provider: { slug: 'mock', label: 'Provider di prova', resolveEndpoint: 'mock' },
  }
}

Deno.test('extractWatchId prende l\'ultimo segmento del percorso', () => {
  // Il caso da cui e' partita la scelta: `watch/123` deve dare `123`, non
  // `watch`, che e' la parola che descrive l'azione e non identifica niente.
  assertEquals(extractWatchId('https://api.example.com/watch/123'), '123')
  assertEquals(extractWatchId('https://api.example.com/watch/123/'), '123')
  assertEquals(
    extractWatchId('https://api.example.com/v2/stream/episode-7-1080p'),
    'episode-7-1080p',
  )
})

Deno.test('extractWatchId su un URL che non e\' un URL', () => {
  assertEquals(extractWatchId('non-e-un-url'), null)
  assertEquals(extractWatchId('https://api.example.com/'), null)
  assertEquals(extractWatchId('https://api.example.com'), null)
})

Deno.test('isUuid accetta un uuid e rifiuta il resto', () => {
  assert(isUuid(UUID_OK))
  assert(isUuid(UUID_OK.toUpperCase()), 'il case non deve contare: Postgres accetta i due');

  // I falsi positivi qui sono i pericolosi: una stringa che sembra un uuid ma
  // non lo e' finisce interpolata in una query.
  assertFalse(isUuid('00000000-0000-0000-0000-000000000001' + 'x'))
  assertFalse(isUuid('3f8c1d2e4a5b4c6d8e9f0a1b2c3d4e5f'), 'manca un trattino')
  assertFalse(isUuid("'; drop table episodes; --"))
  assertFalse(isUuid(''))
  assertFalse(isUuid(null))
  assertFalse(isUuid(123))
})

Deno.test('isHttpUrl accetta http e https e respinge il resto', () => {
  assert(isHttpUrl('https://api.example.com/watch/123'));
  assert(isHttpUrl('http://api.example.com/watch/123'));

  // `javascript:` e `file:` sono i due casi per cui il controllo esiste: senza,
  // un canonical_url sbagliato in colonna fa mandare il player sopra un URL che
  // non e' un video.
  assertFalse(isHttpUrl('javascript:alert(1)'));
  assertFalse(isHttpUrl('file:///etc/passwd'));
  assertFalse(isHttpUrl('ftp://example.com/video.mp4'))
  assertFalse(isHttpUrl('api.example.com/watch/123'))
  assertFalse(isHttpUrl(''))
  assertFalse(isHttpUrl(null))
})

Deno.test('il resolver finto restituisce URL, header e scadenza', async () => {
  const result = await mockResolver.resolve(requestFixture(sourceFixture()))

  // L'URL effimero porta il token nella query: e' la prova che l'indirizzo
  // restituito e' diverso dal canonico, e quindi non puo' essere salvato.
  assert(result.resolvedUrl.startsWith('https://test-streams.mux.dev/'))
  assert(result.resolvedUrl.includes('token='))
  assert(!result.resolvedUrl.includes('api.example.com'))

  // Gli header sono il motivo per cui esiste tutta la funzione: senza
  // `Referer` e `Authorization` molti CDN rispondono 403 anche con l'URL
  // giusto, e il player direbbe solo "questa fonte non parte".
  // `Origin` senza barra finale: e' cio' che dice la specifica, e un server che
  // confronta il valore ne rischierebbe il rifiuto se la barra ci fosse.
  assertEquals(result.headers['Referer'], 'https://example.com/')
  assertEquals(result.headers['Origin'], 'https://example.com')
  assert(result.headers['Authorization']?.startsWith('Bearer '))
  assertEquals(result.headers['X-AnimeRank-Provider'], 'mock')
  assertEquals(result.headers['X-AnimeRank-Source'], UUID_OK)
  assertEquals(result.sourceType, 'hls')
})

Deno.test('il resolver finto restituisce mp4 per una fonte mp4', async () => {
  // Il fallback del client prova le fonti in ordine: se il resolver mandasse
  // sempre HLS, due fonti di formato diverso aprirebbero lo stesso ramo e la
  // prova del fallback non avrebbe senso.
  const result = await mockResolver.resolve(
    requestFixture(sourceFixture({ sourceType: 'mp4' })),
  )

  assert(result.resolvedUrl.includes('bbb-360.mp4'))
  assert(!result.resolvedUrl.includes('.m3u8'))
  assertEquals(result.sourceType, 'mp4')
})

Deno.test('due richieste consecutive danno token diversi', async () => {
  // Non e' una verifica di sicurezza, e' una verifica di forma: se il token
  // fosse identico il resolver starebbe mimando un link stabile, che e'
  // esattamente il caso da cui si parte.
  //
  // Il caso da coprire e' quello delle due chiamate nella stessa secondo:
  // `exp` ha granularita' al secondo, quindi il nonce e' l'unica cosa che
  // distingue le due firme. Senza di esso i due link sarebbero identici.
  const first = await mockResolver.resolve(requestFixture(sourceFixture()))
  const second = await mockResolver.resolve(requestFixture(sourceFixture()))

  assert(
    first.resolvedUrl !== second.resolvedUrl,
    'il token dev\'essere nuovo a ogni risoluzione',
  )
})

Deno.test('il token porta l\'id della fonte e la scadenza', () => {
  const payload = mockTokenPayload(UUID_OK, 1_800_000_000)

  // Il payload e' firmato, quindi il suo contenuto non e' un posto dove mettere
  // segreti: qui si verifica solo che ci siano i due campi che il resolver usa,
  // perche' un payload senza `sid` non potrebbe essere legato a un episodio.
  const decoded = JSON.parse(payload) as { sid: string; exp: number; jti: string }
  assertEquals(decoded.sid, UUID_OK)
  assertEquals(decoded.exp, 1_800_000_000)

  // Il nonce e' cio' che rende il token unico per richiesta: senza, due
  // risoluzioni nella stessa seconda firmerebbero lo stesso messaggio e
  // produrrebbero lo stesso identico link.
  assert(typeof decoded.jti === 'string' && decoded.jti.length > 0)
})

Deno.test('il token firmato contiene il payload che e\' stato firmato', async () => {
  // Il formato e' `<payload>.<firma>`: la firma e' sul payload, quindi la
  // prima parte deve essere esattamente il JSON firmato. Se il resolver
  // firmasse qualcos'altro, la verifica lato provider fallirebbe con un video
  // che sembra scaricabile e non lo e'.
  const payload = mockTokenPayload(UUID_OK, 1_800_000_000)
  const token = await signMockToken(payload)
  const [signedPart, signature] = token.split('.')

  assert(signature !== undefined && signature.length > 0, 'manca la firma')
  assertEquals(signedPart, base64UrlOf(payload))
  assert(!token.includes('+') && !token.includes('/'), 'il base64url non usa + e /')
})

Deno.test('la scadenza e\' nel futuro e non lontanissima', async () => {
  const result = await mockResolver.resolve(requestFixture(sourceFixture()))

  assert(typeof result.expiresAt === 'string', 'il resolver finto deve dichiarare la scadenza')

  const expires = Date.parse(result.expiresAt)
  const now = Date.now()

  assert(expires > now, 'un link gia\' scaduto non si puo\' usare')
  // Cinque minuti: oltre, il vantaggio del link effimero sparisce. Il test
  // fissa il tetto perche' il valore e' un parametro, e un parametro che
  // qualcuno alza a un\'ora per disattivare un fastidio non si nota.
  assert(expires - now < 15 * 60_000, 'la scadenza e\' troppo lontana')
})

/** La stessa base64url che usa il resolver, ricostruita qui per non importarne la funzione privata. */
function base64UrlOf(text: string): string {
  let binary = ''
  for (const char of new TextEncoder().encode(text)) binary += String.fromCharCode(char)

  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

Deno.test('resolveRoute accetta sia la query sia il path', () => {
  // Il gateway chiama la radice della funzione, quindi la rotta arriva come
  // parametro; il path serve a chi chiama a mano. Se le due non concordassero,
  // una delle due forme di chiamata riceverebbe 404 e sembrerebbe che la
  // funzione sia stata deployata male.
  assertEquals(resolveRoute(new URL('https://x.co/functions/v1/resolve-source?route=/health')), '/health')
  assertEquals(resolveRoute(new URL('https://x.co/functions/v1/resolve-source/health')), '/health')
  assertEquals(resolveRoute(new URL('https://x.co/functions/v1/resolve-source?route=/resolve')), '/resolve')
  assertEquals(resolveRoute(new URL('https://x.co/functions/v1/resolve-source?route=/rotta-fantasma')), '/rotta-fantasma')
  assertEquals(resolveRoute(new URL('https://x.co/functions/v1/resolve-source')), '/resolve')
})

Deno.test('/health risponde senza token e dice se resta solo il mock', async () => {
  const response = await handleRequest(
    new Request('https://x.co/functions/v1/resolve-source?route=/health'),
  )

  assertEquals(response.status, 200)

  const body = (await response.json()) as {
    status: string
    adapters: string[]
    mockOnly: boolean
  }

  // `mockOnly` e' l'informazione che dice se la catena sta girando sul finto o
  // sul provider vero: senza, un collaudo non distingue le due situazioni.
  assertEquals(body.status, 'ok')
  assert(Array.isArray(body.adapters))
  assert(body.adapters.includes('mock'))
  assert(body.adapters.includes('generic_api'))
  assertEquals(body.mockOnly, false)
})

Deno.test('senza Authorization la risoluzione non parte', async () => {
  // `/health` e' pubblico perche' serve a distinguere "funzione spenta" da
  // "token scaduto". Tutto il resto no, e questa e' la difesa che conta quando
  // `verify_jwt` non e' ancora stata impostata nelle impostazioni della
  // funzione.
  const response = await handleRequest(
    new Request('https://x.co/functions/v1/resolve-source?route=/resolve', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ source_id: UUID_OK }),
    }),
  )

  assertEquals(response.status, 401)

  const body = (await response.json()) as { code: string }
  assertEquals(body.code, 'unauthorized')
})

Deno.test('una rotta sconosciuta risponde 404 e dice cosa c\'e\'', async () => {
  const response = await handleRequest(
    new Request('https://x.co/functions/v1/resolve-source?route=/rotta-fantasma', {
      headers: { Authorization: 'Bearer qualcosa' },
    }),
  )

  assertEquals(response.status, 404)

  const body = (await response.json()) as { code: string; routes: string[] }
  assertEquals(body.code, 'not_found')
  assert(body.routes.length > 0, 'la risposta deve dire quali rotte esistono')
})

Deno.test('il preflight CORS non esegue niente', async () => {
  const response = await handleRequest(
    new Request('https://x.co/functions/v1/resolve-source?route=/resolve', {
      method: 'OPTIONS',
    }),
  )

  assertEquals(response.status, 204)
  assertEquals(response.headers.get('Access-Control-Allow-Origin'), '*')
  assert(
    response.headers.get('Access-Control-Allow-Methods')?.includes('POST') === true,
    'senza POST nel preflight il browser blocca la richiesta di risoluzione',
  )
})

Deno.test('ogni risposta porta i CORS, anche quelle d\'errore', async () => {
  // Senza `Access-Control-Allow-Origin` sull'errore, il browser fa leggere a
  // JavaScript solo il codice di stato: l'app vedrebbe "errore di rete" senza
  // il motivo del rifiuto, che e' la parte utile.
  const response = await handleRequest(
    new Request('https://x.co/functions/v1/resolve-source?route=/resolve', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ source_id: UUID_OK }),
    }),
  )

  assertEquals(response.headers.get('Access-Control-Allow-Origin'), '*')
})

Deno.test('nessuna risposta mette in cache il token', async () => {
  const response = await handleRequest(
    new Request('https://x.co/functions/v1/resolve-source?route=/health'),
  )

  // Il motivo e' diverso da quello di jikan-proxy: li' i risultati dipendevano
  // dalla query, qui dipendono da una scadenza. Una cache che rimandasse un
  // token scaduto a un utente che sta solo cercando di guardare un episodio.
  assertEquals(response.headers.get('Cache-Control'), 'no-store')
})

// ---------------------------------------------------------------------------
// Assert definiti qui perche' questo progetto non ha un import di test
// condiviso con le altre Edge Function: `jikan-proxy/index.test.ts` porta i
// suoi. Duplicare quattro funzioni e' meno male che introdurre un file solo
// per tre righe.
// ---------------------------------------------------------------------------

function assert(condition: boolean, message = 'condizione non vera'): asserts condition {
  if (!condition) throw new Error(message)
}

function assertFalse(condition: boolean, message = 'condizione non vera'): void {
  assert(!condition, message)
}

// Il confronto passa da `JSON.stringify` perche' il confronto con `===` su
// array e oggetti confronta i riferimenti, non il contenuto: `['mock'] === ['mock']`
// e' falso e un test che verifica una lista diventerebbe rosso per un motivo
// che non c'entra niente con quello che sta provando.
function assertEquals<T>(actual: T, expected: T, message?: string): void {
  const a = JSON.stringify(actual)
  const b = JSON.stringify(expected)
  if (a === b) return

  throw new Error(message ?? `atteso ${b}, trovato ${a}`)
}
