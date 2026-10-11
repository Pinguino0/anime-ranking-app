import type { ResolveRequest, ResolveResult, VideoResolver } from '../types.ts'

function extractIdFromCanonical(canonicalUrl: string): string | null {
  try {
    const url = new URL(canonicalUrl)

    const qEpisodeId = url.searchParams.get('episode_id')
    if (qEpisodeId) return qEpisodeId

    const qId = url.searchParams.get('id')
    if (qId) return qId

    const qEp = url.searchParams.get('ep')
    if (qEp) return qEp

    const watchMatch = url.pathname.match(/\/watch\/([^/?#]+)$/)
    if (watchMatch) return decodeURIComponent(watchMatch[1])

    const genericMatch = url.pathname.match(/\/(?:episode|ep|stream|video)\/([^/?#]+)$/i)
    if (genericMatch) return decodeURIComponent(genericMatch[1])

    const segments = url.pathname.split('/').filter(Boolean)
    if (segments.length > 0) {
      const last = segments[segments.length - 1]
      if (last && last !== 'watch') return decodeURIComponent(last)
    }

    return null
  } catch {
    return null
  }
}

function normalizeHeaders(
  input: unknown,
): Record<string, string> {
  if (!input || typeof input !== 'object') return {}

  return Object.fromEntries(
    Object.entries(input as Record<string, unknown>).filter(
      ([, v]) => typeof v === 'string',
    ),
  ) as Record<string, string>
}

/**
 * I metadati d'episodio come li riceve il provider esterno.
 *
 * Cosa non si manda: `synonyms` intero e' per il caso in cui il provider esterno
 * fa il match sul titolo (AnimeUnity guarda gli slug inglesi, che non sono mai
 * i romaji del catalogo); `title`/`japaneseTitle` sono i candidati primari.
 */
function animeMetaPayload(request: ResolveRequest): Record<string, unknown> | null {
  const meta = request.anime
  if (!meta) return null

  return {
    episodeNumber: meta.episodeNumber,
    title: meta.title,
    japaneseTitle: meta.japaneseTitle,
    synonyms: meta.synonyms,
    malId: meta.malId,
  }
}

export const genericApiResolver: VideoResolver = {
  endpoint: 'generic_api',

  async resolve(request: ResolveRequest): Promise<ResolveResult> {
    const endpointEnv = Deno.env.get('GENERIC_PROVIDER_ENDPOINT')
    const baseUrl = Deno.env.get('GENERIC_PROVIDER_BASE_URL')
    const pathTemplate = Deno.env.get('GENERIC_PROVIDER_PATH_TEMPLATE') ?? '/watch/{id}'
    const method = (Deno.env.get('GENERIC_PROVIDER_METHOD') ?? 'POST').toUpperCase()
    const format = (Deno.env.get('GENERIC_PROVIDER_FORMAT') ?? 'auto').toLowerCase()
    const authHeader = Deno.env.get('GENERIC_PROVIDER_AUTH_HEADER')

    let targetUrl: string | null = null

    if (endpointEnv) {
      targetUrl = endpointEnv
    } else if (baseUrl) {
      const id = extractIdFromCanonical(request.canonicalUrl) ?? request.source.id
      const path = pathTemplate.replace('{id}', encodeURIComponent(id)).replace(
        '{sourceId}',
        encodeURIComponent(request.source.id),
      )
      targetUrl = baseUrl.replace(/\/$/, '') + (path.startsWith('/') ? path : `/${path}`)
    }

    if (!targetUrl) {
      throw new Error(
        'Configurare GENERIC_PROVIDER_ENDPOINT o GENERIC_PROVIDER_BASE_URL + GENERIC_PROVIDER_PATH_TEMPLATE.',
      )
    }

    const started = Date.now()
    let response: Response

    try {
      if (method === 'GET') {
        const url = new URL(targetUrl)
        const id = extractIdFromCanonical(request.canonicalUrl) ?? request.source.id
        if (!url.searchParams.has('id') && !url.searchParams.has('episode_id')) {
          url.searchParams.set('episode_id', id)
        }

        // Nell'URL ci stanno solo i metadati scarsi: per il resto del fallback
        // servono il numero episodio e un titolo, e senza di loro un provider
        // di backup non ha nessun appiglio per cercare lo stesso episodio.
        const meta = animeMetaPayload(request)
        if (meta) {
          if (typeof meta.episodeNumber === 'number') {
            url.searchParams.set('episode_number', String(meta.episodeNumber))
          }
          if (typeof meta.title === 'string' && meta.title !== '') {
            url.searchParams.set('title', meta.title)
          }
          if (typeof meta.malId === 'number') {
            url.searchParams.set('mal_id', String(meta.malId))
          }
        }

        response = await fetch(url.toString(), {
          method: 'GET',
          headers: {
            'Accept': 'application/json',
            'X-Provider-Source': request.source.id,
            ...(authHeader ? { Authorization: authHeader } : {}),
          },
        })
      } else {
        const animeMeta = animeMetaPayload(request)
        const payload = {
          sourceId: request.source.id,
          canonicalUrl: request.canonicalUrl,
          sourceType: request.source.sourceType,
          quality: request.source.quality,
          language: request.source.language,
          ...(animeMeta !== null ? { anime: animeMeta } : {}),
        }

        response = await fetch(targetUrl, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'X-Provider-Source': request.source.id,
            ...(authHeader ? { Authorization: authHeader } : {}),
          },
          body: JSON.stringify(payload),
        })
      }
    } catch (error) {
      console.error(
        `resolve-source: generic_api fetch fallito in ${Date.now() - started}ms`,
        error,
      )
      throw new Error('Impossibile contattare il provider esterno.')
    }

    if (!response.ok) {
      const text = await response.text().catch(() => '')
      console.error(
        `resolve-source: generic_api ha risposto ${response.status} in ${Date.now() - started}ms`,
        text,
      )
      throw new Error('Il provider esterno ha rifiutato la richiesta.')
    }

    let data: unknown
    try {
      data = await response.json()
    } catch {
      throw new Error('Risposta non valida dal provider esterno.')
    }

    const row = (data ?? {}) as Record<string, unknown>

    let resolvedUrl: string | null = null
    let outHeaders: Record<string, string> = {}
    let outSourceType: 'mp4' | 'hls' | 'iframe' = request.source.sourceType
    let expiresAt: string | undefined

    if (Array.isArray((row as any).sources) && (row as any).sources.length > 0) {
      const sources = (row as any).sources as Array<Record<string, unknown>>
      for (const s of sources) {
        const urlSrc = typeof s.url === 'string' ? s.url : null
        if (!urlSrc) continue

        resolvedUrl = urlSrc
        outHeaders = normalizeHeaders(s.headers)

        const isM3u8 = s.isM3U8 === true || /m3u8/i.test(urlSrc)
        if (isM3u8) outSourceType = 'hls'
        else if (outSourceType !== 'hls') outSourceType = 'mp4'

        break
      }
    }

    if (!resolvedUrl && row.video && typeof (row.video as any).url === 'string') {
      resolvedUrl = (row.video as any).url
    }
    if (!resolvedUrl && row.stream && typeof (row.stream as any).url === 'string') {
      resolvedUrl = (row.stream as any).url
    }
    if (!resolvedUrl && row.data && typeof (row.data as any).url === 'string') {
      resolvedUrl = (row.data as any).url
    }

    if (!resolvedUrl && typeof row.url === 'string') {
      resolvedUrl = row.url
      outHeaders = normalizeHeaders(row.headers)
      if (
        typeof row.sourceType === 'string' &&
        ['mp4', 'hls', 'iframe'].includes(row.sourceType)
      ) {
        outSourceType = row.sourceType as 'mp4' | 'hls' | 'iframe'
      }
      if (typeof row.expiresAt === 'string') expiresAt = row.expiresAt
    }

    if (!resolvedUrl) {
      throw new Error('Il provider esterno non ha restituito un URL valido.')
    }

    if (Object.keys(outHeaders).length === 0) {
      outHeaders = normalizeHeaders(row.headers)
    }

    console.log(
      `resolve-source: generic_api ha risolto ${request.source.id} in ${Date.now() - started}ms`,
    )

    return {
      resolvedUrl,
      headers: outHeaders,
      sourceType: outSourceType,
      expiresAt,
    }
  },
}