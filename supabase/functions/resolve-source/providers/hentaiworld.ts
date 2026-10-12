// ============================================================================
// hentaiworld.ts - risoluzione HentaiWorld (contenuti per adulti)
// ============================================================================
//
// Provider separato dagli altri: e' l'unica fonte a contenuto per adulti del
// catalogo, quindi ha un adapter suo invece di finire dentro `native.ts` con
// AnimeUnity e AnimeWorld. Cosi' si vede a colpo d'occhio da dove arriva un
// video, e si puo' spegnere la fonte senza toccare gli altri: basta mettere
// `is_active = false` sulla riga di `providers`.
//
// L'estrazione copre i meccanismi che HentaiWorld usa davvero, verificati dal
// vivo con `scraper/probe_hentaiworld.js` (e poi end-to-end):
//
//  - lo stream e' un `.mp4` scritto direttamente nella pagina, su un host
//    esterno (`server.hcherry.net`), mentre il player (jwplayer) lo referenzia
//    con `file: videoUrl`. La strategia "stream diretto" lo trova.
//  - l'unico iframe della pagina e' pubblicitario: seguirlo sarebbe un giro a
//    vuoto, quindi la strategia diretta ha la precedenza e l'iframe resta solo
//    come ultima risorsa per un eventuale cambio di forma del sito.
//
// Le stesse strategie generali (`masterPlaylist`, `.m3u8`, iframe) restano per
// se il sito cambia player: se succede, `scraper/probe_hentaiworld.js`
// dice dove, e l'errore di fallimento lo ricorda.
// ============================================================================

import type { ResolveRequest, ResolveResult, VideoResolver } from '../types.ts'
import { ProviderError } from './native.ts'

const USER_AGENT =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

const SESSION_TTL_MS = 3 * 60 * 60 * 1000

/** Un URL riproducibile trovato nella pagina, con il formato che gli compete. */
export interface StreamCandidate {
  url: string
  sourceType: 'hls' | 'mp4'
}

// La cache e' per origin, non globale: il player spesso sta su un host diverso
// dalla pagina, e mandargli il cookie dell'altro host sarebbe sia inutile sia
// sbagliato.
const sessions = new Map<string, { cookie: string; expiresAt: number }>()

// ---------------------------------------------------------------------------
// Sessione
// ---------------------------------------------------------------------------
//
// Come per gli altri provider: la home rilascia un cookie di sessione e passarlo
// evita che ogni richiesta sia trattata come una sessione nuova (e prima o poi
// scatti un rate limit). Si ricompra quando scade.
async function getSession(origin: string): Promise<string> {
  const cached = sessions.get(origin)
  if (cached && Date.now() < cached.expiresAt && cached.cookie) {
    return cached.cookie
  }

  const response = await fetch(`${origin}/`, {
    headers: { 'user-agent': USER_AGENT, accept: 'text/html' },
    redirect: 'follow',
    signal: AbortSignal.timeout(15000),
  })
  if (!response.ok) {
    throw new ProviderError(502, `HentaiWorld ha risposto HTTP ${response.status}.`)
  }

  const rawCookies = response.headers.getSetCookie?.() ?? []
  const cookie = rawCookies.map((c) => c.split(';')[0]).join('; ')
  sessions.set(origin, { cookie, expiresAt: Date.now() + SESSION_TTL_MS })
  return cookie
}

// ---------------------------------------------------------------------------
// Estrazione
// ---------------------------------------------------------------------------

/** Rende assoluto un URL relativo rispetto alla pagina. */
function absolutize(value: string, base: string): string | null {
  try {
    return new URL(value, base).toString()
  } catch {
    return null
  }
}

/**
 * Scioglie gli escape delle stringhe JavaScript.
 *
 * Gli URL dei player vivono dentro `<script>` come `https:\/\/cdn...\/v.m3u8`
 * oppure con `\u0026` al posto di `&`: senza scioglierli la regex non aggancia
 * e la fonte sembra assente pur essendoci.
 */
function decodeEscapes(value: string): string {
  return value.replace(/\\\//g, '/').replace(/\\u0026/gi, '&').replace(/&amp;/g, '&')
}

/** Toglie virgolette non valide e trailing comma da un oggetto simile a JSON. */
function normalizeJson(raw: string): string {
  return raw
    .replace(/([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:/g, '$1"$2":')
    .replace(/,\s*}/g, '}')
    .replace(/,\s*]/g, ']')
    .replace(/'/g, '"')
}

/** Il blocco `{...}` che parte da `start`, con il conteggio delle graffe. */
function braceSlice(text: string, start: number): string | null {
  const open = text.indexOf('{', start)
  if (open < 0) return null

  let depth = 0
  for (let i = open; i < text.length; i += 1) {
    const ch = text[i]
    if (ch === '{') depth += 1
    else if (ch === '}') {
      depth -= 1
      if (depth === 0) return text.slice(open, i + 1)
    }
  }
  return null
}

/**
 * Cerca una playlist dichiarata in una config JavaScript.
 *
 * E' il formato `window.masterPlaylist = { url, params }` usato da vixcloud
 * (dietro AnimeUnity) e da molti embed: l'URL non compare come stringa
 * completa, va ricomposto unendo `url` e `params` come query.
 */
export function extractMasterPlaylist(html: string, baseUrl: string): StreamCandidate | null {
  const marker = html.indexOf('masterPlaylist')
  if (marker < 0) return null

  const raw = braceSlice(html, marker)
  if (!raw) return null

  let config: Record<string, unknown>
  try {
    config = JSON.parse(normalizeJson(raw)) as Record<string, unknown>
  } catch {
    return null
  }

  const base = typeof config.url === 'string' ? decodeEscapes(config.url) : ''
  if (!base) return null

  const url = absolutize(base, baseUrl)
  if (!url) return null

  const params = (config.params ?? {}) as Record<string, unknown>
  const composed = new URL(url)
  for (const [key, value] of Object.entries(params)) {
    if (value !== null && value !== undefined && value !== '') {
      composed.searchParams.set(key, String(value))
    }
  }

  return { url: composed.toString(), sourceType: 'hls' }
}

/**
 * Cerca un URL di stream scritto direttamente nella pagina.
 *
 * Preferisce `.m3u8` (HLS) a `.mp4`: quando ci sono entrambi, l'HLS e' quello
 * con piu' rendition e quello che il player gestisce meglio.
 */
export function extractDirectStream(html: string, baseUrl: string): StreamCandidate | null {
  const text = decodeEscapes(html)

  const hls = /https?:\/\/[^\s"'<>\\]+?\.m3u8[^\s"'<>\\]*/i.exec(text)
  if (hls) {
    const url = absolutize(hls[0], baseUrl)
    if (url) return { url, sourceType: 'hls' }
  }

  const mp4 = /https?:\/\/[^\s"'<>\\]+?\.mp4[^\s"'<>\\]*/i.exec(text)
  if (mp4) {
    const url = absolutize(mp4[0], baseUrl)
    if (url) return { url, sourceType: 'mp4' }
  }

  return null
}

/** Il primo `src` di un `<iframe>`, reso assoluto. */
export function extractIframe(html: string, baseUrl: string): string | null {
  const match = /<iframe\b[^>]*\bsrc=["']([^"']+)["']/i.exec(html)
  if (!match) return null
  return absolutize(match[1], baseUrl)
}

/** Le strategie in ordine: config, poi stream diretto. */
export function extractStream(html: string, baseUrl: string): StreamCandidate | null {
  return extractMasterPlaylist(html, baseUrl) ?? extractDirectStream(html, baseUrl)
}

// ---------------------------------------------------------------------------
// Fetch
// ---------------------------------------------------------------------------

interface Page {
  html: string
  finalUrl: string
}

async function fetchPage(url: string, referer?: string): Promise<Page> {
  const origin = new URL(url).origin
  const cookie = await getSession(origin)

  const response = await fetch(url, {
    headers: {
      'user-agent': USER_AGENT,
      accept: 'text/html,application/xhtml+xml',
      'accept-language': 'it-IT,it;q=0.9',
      ...(referer ? { referer } : {}),
      ...(cookie ? { cookie } : {}),
    },
    redirect: 'follow',
    signal: AbortSignal.timeout(20000),
  })
  if (!response.ok) {
    throw new ProviderError(502, `HentaiWorld ha risposto HTTP ${response.status}.`)
  }

  return { html: await response.text(), finalUrl: response.url || url }
}

// ---------------------------------------------------------------------------
// Adapter
// ---------------------------------------------------------------------------

export const hentaiworldResolver: VideoResolver = {
  endpoint: 'hentaiworld',

  async resolve(request: ResolveRequest): Promise<ResolveResult> {
    let origin: string
    try {
      origin = new URL(request.canonicalUrl).origin
    } catch {
      throw new ProviderError(422, "L'indirizzo canonico della fonte non e' valido.")
    }

    const page = await fetchPage(request.canonicalUrl)
    let found = extractStream(page.html, page.finalUrl)

    // Molti siti mettono il player vero dentro un iframe su un altro host: il
    // primo giro serve solo a trovarlo, il secondo a leggerne lo stream.
    if (!found) {
      const iframe = extractIframe(page.html, page.finalUrl)
      if (iframe) {
        const inner = await fetchPage(iframe, page.finalUrl)
        found = extractStream(inner.html, inner.finalUrl)
      }
    }

    if (!found) {
      throw new ProviderError(
        422,
        'Player HentaiWorld non riconosciuto: esegui scraper/probe_hentaiworld.js ' +
          'e aggiorna providers/hentaiworld.ts con il meccanismo trovato.',
      )
    }

    return {
      resolvedUrl: found.url,
      headers: { Referer: `${origin}/`, Origin: origin },
      sourceType: found.sourceType,
    }
  },
}
