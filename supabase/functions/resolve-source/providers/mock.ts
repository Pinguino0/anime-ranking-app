// ============================================================================
// provider/mock - adapter finto per resolve-source
// ============================================================================
//
// Cosa simula
// -----------
// Il provider di prova fa esattamente cio' che fanno i provider veri quando
// prendono il posto di `example`:
//
//   1. riceve un indirizzo CANONICO (`https://api.example.com/watch/123`)
//   2. lo interpreta, estrae l'id dell'episodio
//   3. risponde con un indirizzo EFFIMERO firmato, che scade
//   4. risponde anche con gli HEADER necessari per farlo aprire
//
// Il video restituito e' Big Buck Bunny, pubblico e su dominio pubblico, quindi
// si riproduce davvero: la catena si puo' provare end to end prima di avere il
// provider vero.
//
// Perche' questo file e' separato da `index.ts`
// --------------------------------------------
// `index.ts` non sa niente di come si risolve: legge la fonte, sceglie
// l'adapter dal `resolve_endpoint` della riga in `providers` e gli passa il
// lavoro. Il provider vero sara' un altro file con la stessa interfaccia
// `VideoResolver`, piu' una riga in `providers`. Nello schema, nel client e nel
// player non si cambia niente.
//
// La firma da implementare e' [VideoResolver]: `resolve()` riceve un
// [ResolveRequest] e restituisce un [ResolveResult], oppure lancia.
//
// Sicurezza
// ---------
// Il segreto con cui si firma il token viene da `MOCK_PROVIDER_SECRET`. Se
// manca — cioe' su un ambiente dove nessuno ha ancora impostato niente — la
// funzione genera una chiave casuale per il processo e lo dice nei log. Il
// effetto e' che i token emessi prima di un riavvio smettono di valere: il
// player se ne accorge e risolve di nuovo. Meglio che una chiave fissa scritta
// nel sorgente, che finirebbe nel pacchetto deployato.
// ============================================================================

import type { ResolveRequest, ResolveResult, VideoResolver } from '../types.ts'

// Il file di prova pubblico di Big Buck Bunny.
//
// Non e' un segreto e non e' un posto dove mettere contenuti nostri: serve
// solo a far partire il player. Le due varianti servono a coprire i due
// formati che l'app sa riprodurre, cosi' il collaudo del fallback non prova
// due volte lo stesso ramo.
const MOCK_MP4 = 'https://test-streams.mux.dev/bbb-360/bbb-360.mp4'
const MOCK_HLS = 'https://test-streams.mux.dev/test_001/stream.m3u8'

// Dove il finto provider "sta". Non serve a nulla tecnicamente: e' il
// `Referer` che finisce negli header, e serve a far capire guardando una
// richiesta di chi e' stato a fare la risoluzione.
const MOCK_ORIGIN = 'https://example.com'

// Quanto dura un link risolto.
//
// Cinque minuti sono un numero arbitrario ma non casuale: piu' breve di un
// video lungo e l'episodio si interromperebbe a meta'; molto piu' lungo e il
// vantaggio del link effimero — non poter essere riusato per sempre — sparisce.
// Il valore reale lo dettano i provider veri, e arriva qui dentro.
const TTL_SECONDS = 300

// ---------------------------------------------------------------------------
// Firma del token
// ---------------------------------------------------------------------------

const encoder = new TextEncoder()

let cachedKey: CryptoKey | null = null
let cachedSecret: string | null = null

/**
 * Chiave HMAC per firmare i token del finto provider.
 *
 * La chiave si rifa solo quando il segreto cambia: `importKey` e' asincrono e
 * rifarlo a ogni richiesta costerebbe una promessa per niente.
 */
async function signingKey(): Promise<CryptoKey> {
  const secret = Deno.env.get('MOCK_PROVIDER_SECRET') ?? null

  if (cachedKey !== null && cachedSecret === secret) return cachedKey

  if (secret === null) {
    console.warn(
      'resolve-source: MOCK_PROVIDER_SECRET non impostata, uso una chiave casuale. ' +
        'I token emessi prima di un riavvio non saranno piu\' validi.',
    )
  }

  // Senza segreto configurato si usa un valore casuale per processo. Non e'
  // casuale nel senso di "lo indovino": e' `crypto.getRandomValues`, quindi non
  // e' indovinabile. Cambia a ogni riavvio, ed e' esattamente il comportamento
  // voluto: un token firmato con una chiave che scappa col riavvio non vale
  // niente, quindi non e' un segreto che si puo' riusare.
  const material = secret ?? crypto.randomUUID()

  cachedKey = await crypto.subtle.importKey(
    'raw',
    encoder.encode(material),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  cachedSecret = secret

  return cachedKey
}

/**
 * Firma il contenuto del token e restituisce la parte opaca delBearer token.
 *
 * Il formato e' `<base64url(payload)>.<base64url(sig)>`: ispezionabile nella
 * prima parte, verificabile nella seconda, che e' la forma che usano i
 * provider veri e che rende inutile reinventare un formato solo per il mock.
 */
async function sign(payload: string): Promise<string> {
  const key = await signingKey()
  const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(payload))

  return `${base64Url(encoder.encode(payload))}.${base64Url(new Uint8Array(signature))}`
}

function base64Url(bytes: Uint8Array): string {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)

  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

/**
 * Firma il token che autorizza a scaricare il video di un episodio.
 *
 * Il payload porta l'id e la scadenza, cosi' chi riceve il token sa per
 * quale episodio vale e non puo' cambiarlo: riapplicarlo a un altro episodio
 * non produce una firma valida, perche' l'id fa parte del messaggio firmato.
 */
export function mockTokenPayload(sourceId: string, expiresAt: number): string {
  // `jti` e' il nonce. Senza, due richieste nella stessa secondo produrrebbero
  // lo stesso identico token — la firma e' deterministica — e il resolver
  // sembrerebbe restituire un link stabile, che e' esattamente la cosa da cui
  // si parte. Un token per richiesta e' anche cio' che fanno i provider veri:
  // il link vale una volta.
  return JSON.stringify({ sid: sourceId, exp: expiresAt, jti: crypto.randomUUID() })
}

export async function signMockToken(payload: string): Promise<string> {
  return await sign(payload)
}

// ---------------------------------------------------------------------------
// Adapter
// ---------------------------------------------------------------------------

/**
 * Il resolver finto.
 *
 * `resolve()` non chiama nessuno: e' una funzione pura del tempo e dell'id, e
 * questa e' una scelta, non una semplificazione. Un resolver finto che facesse
 * una richiesta di reale darebbe due problemi: i test avrebbero bisogno della
 * rete, e un collaudo su un ambiente senza rete fallirebbe proprio dove serve
 * capire se la catena funziona.
 */
export const mockResolver: VideoResolver = {
  endpoint: 'mock',

  async resolve(request: ResolveRequest): Promise<ResolveResult> {
    // L'id viene dal percorso canonico e serve a due cose: a far cambiare
    // l'URL da episodio a episodio, cosi' l'utente vede che la risoluzione
    // produce qualcosa di diverso per ogni fonte, e a firmare un token che non
    // e' riusabile su un altro episodio.
    //
    // Il fallback a `source` quando il percorso non ha un id e' quello che
    // farebbe un provider vero: se non capisce la pagina, risponde comunque con
    // il suo video predefinito invece di far fallire la riproduzione.
    const id = extractWatchId(request.canonicalUrl) ?? request.source.id

    const expiresAt = Math.floor(Date.now() / 1000) + TTL_SECONDS
    const token = await sign(mockTokenPayload(request.source.id, expiresAt))

    // La scelta fra mp4 e hls segue il formato dichiarato sulla fonte, non il
    // caso: e' cosi' che il collaudo del fallback prova davvero due percorsi
    // diversi del player invece di due richieste allo stesso ramo.
    const base = request.source.sourceType === 'hls' ? MOCK_HLS : MOCK_MP4
    const separator = base.includes('?') ? '&' : '?'
    const resolvedUrl = `${base}${separator}token=${encodeURIComponent(token)}&id=${encodeURIComponent(id)}`

    // Gli header sono il punto di questo esercizio: senza `Referer` e
    // `Authorization` molti CDN rispondono 403 anche con l'URL giusto, e il
    // player mostrerebbe "questa fonte non parte" senza che nessuno capisca
    // perche'. Il `User-Agent` non serve per il mock — nessuno lo controlla —
    // ma c'e' perche' i provider veri lo richiedono spesso, e cosi' la catena
    // li prova gia' ora.
    const headers: Record<string, string> = {
      Referer: `${MOCK_ORIGIN}/`,
      Origin: MOCK_ORIGIN,
      Authorization: `Bearer ${token}`,
      'X-AnimeRank-Provider': 'mock',
      'X-AnimeRank-Source': request.source.id,
      'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
        '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36',
      Accept: '*/*',
    }

    return {
      resolvedUrl,
      headers,
      sourceType: request.source.sourceType,
      expiresAt: new Date(expiresAt * 1000).toISOString(),
    }
  },
}

/**
 * L'id dell'episodio dentro un URL canonico.
 *
 * Solo l'ultimo segmento non vuoto, che e' la regola che regge
 * `https://api.example.com/watch/123`. Un percorso piu' lungo viene gestito
 * dall'adapter vero, che conosce il provider: qui' prendere il primo segmento
 * significherebbe tirare fuori "watch" come se fosse l'id.
 */
export function extractWatchId(canonicalUrl: string): string | null {
  try {
    const url = new URL(canonicalUrl)
    const segments = url.pathname.split('/').filter(Boolean)

    if (segments.length === 0) return null
    return segments[segments.length - 1]
  } catch {
    return null
  }
}
