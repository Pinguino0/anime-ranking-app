const express = require('express')
const cheerio = require('cheerio')
const animeUnity = require('./animeunity')

const PORT = Number(process.env.PORT || 3000)
const HOST = process.env.HOST || '0.0.0.0'

const USER_AGENT =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

const app = express()
app.use(express.json({ limit: '16kb' }))

class ExtractError extends Error {
  constructor(status, message) {
    super(message)
    this.status = status
  }
}

function parseHttpUrl(value) {
  if (typeof value !== 'string' || value.trim() === '') return null
  try {
    const url = new URL(value.trim())
    return url.protocol === 'http:' || url.protocol === 'https:' ? url : null
  } catch {
    return null
  }
}

async function fetchText(url, headers) {
  const response = await fetch(url, {
    headers: { 'user-agent': USER_AGENT, ...headers },
    redirect: 'follow',
    signal: AbortSignal.timeout(15000),
  })

  if (!response.ok) {
    throw new ExtractError(502, `Pagina sorgente ha risposto HTTP ${response.status}.`)
  }

  return response.text()
}

async function fetchJson(url, headers) {
  const response = await fetch(url, {
    headers: { 'user-agent': USER_AGENT, ...headers },
    redirect: 'follow',
    signal: AbortSignal.timeout(15000),
  })

  if (!response.ok) {
    throw new ExtractError(502, `API del provider ha risposto HTTP ${response.status}.`)
  }

  try {
    return await response.json()
  } catch {
    throw new ExtractError(502, 'Risposta non JSON dal provider.')
  }
}

async function extractAnimeWorld(canonicalUrl) {
  const pageUrl = parseHttpUrl(canonicalUrl)
  if (!pageUrl) throw new ExtractError(400, 'canonical_url mancante o non valido.')

  const html = await fetchText(pageUrl.toString(), {
    accept: 'text/html',
    'accept-language': 'it-IT,it;q=0.9',
  })

  const $ = cheerio.load(html)
  const dataId =
    $('#player').attr('data-id') ||
    $('[data-episode-id]').first().attr('data-id') ||
    ''
  const csrf = $('meta[name="csrf-token"]').attr('content') || ''

  if (!dataId) {
    throw new ExtractError(
      422,
      'Nessun player nella pagina: URL episodio errato o pagina cambiata.',
    )
  }
  if (!csrf) {
    throw new ExtractError(502, 'Token CSRF assente nella pagina.')
  }

  const infoUrl = new URL('/api/episode/info', pageUrl.origin)
  infoUrl.searchParams.set('id', dataId)
  infoUrl.searchParams.set('alt', '0')

  const info = await fetchJson(infoUrl.toString(), {
    accept: 'application/json',
    'csrf-token': csrf,
    referer: pageUrl.toString(),
    'x-requested-with': 'XMLHttpRequest',
  })

  const grabber = typeof info.grabber === 'string' ? info.grabber.trim() : ''
  const videoUrl = parseHttpUrl(grabber)
  if (!videoUrl) {
    throw new ExtractError(502, 'Il provider non ha restituito un URL video.')
  }

  return {
    url: videoUrl.toString(),
    headers: {
      Referer: `${pageUrl.origin}/`,
      Origin: pageUrl.origin,
    },
    sourceType: 'mp4',
    provider: 'animeworld',
  }
}

function normalizeMeta(value) {
  if (!value || typeof value !== 'object') return null
  const meta = {}
  meta.episodeNumber =
    typeof value.episodeNumber === 'number' ? value.episodeNumber : null
  meta.title = typeof value.title === 'string' ? value.title : null
  meta.japaneseTitle =
    typeof value.japaneseTitle === 'string' ? value.japaneseTitle : null
  meta.synonyms = Array.isArray(value.synonyms)
    ? value.synonyms.filter((s) => typeof s === 'string')
    : []
  meta.malId = typeof value.malId === 'number' ? value.malId : null
  return meta
}

/**
 * La catena dei provider.
 *
 * Il canonico dice chi fa il primario: un URL AnimeWorld si risolve da solo.
 * Quando il primario cade, il fallback ritrova lo stesso episodio su
 * AnimeUnity grazie ai metadati dell'anime passati dalla Edge Function —
 * per titolo (sitemap), oppure direttamente quando il canonico e' gia' una
 * pagina AnimeUnity.
 */
async function extract(canonicalUrl, metaValue, requestedQuality) {
  const pageUrl = parseHttpUrl(canonicalUrl)
  if (!pageUrl) throw new ExtractError(400, 'canonical_url mancante o non valido.')

  const meta = normalizeMeta(metaValue)
  const quality = typeof requestedQuality === 'string' ? requestedQuality : '1080p'
  const host = pageUrl.hostname.toLowerCase()

  if (host.endsWith('animeunity.so') || host.endsWith('animeunity.to')) {
    // Un canonico AnimeUnity: l'id dell'anime sta nel path; il numero episodio
    // viene dai metadati.
    if (!meta?.episodeNumber) {
      throw new ExtractError(
        422,
        'Serve il numero episodio (metadati) per un canonico AnimeUnity.',
      )
    }
    return animeUnity.extractFromCanonical(canonicalUrl, meta, quality)
  }

  if (!host.endsWith('animeworld.ac')) {
    throw new ExtractError(422, `Host non gestito: ${pageUrl.hostname}.`)
  }

  try {
    return await extractAnimeWorld(pageUrl.toString())
  } catch (primaryError) {
    console.log(
      `[fallback] estrazione principale fallita (${primaryError.status ?? 500}): ${primaryError.message}`,
    )
    // Fallback: senza metadati non c'e' un titolo con cui cercare altrove.
    if (!meta?.episodeNumber || (!meta.title && meta.synonyms.length === 0)) {
      throw primaryError
    }
    console.log(`[fallback] AnimeUnity (ep. ${meta.episodeNumber}).`)
    try {
      return await animeUnity.extractByMeta(meta, quality)
    } catch (backupError) {
      console.log(
        `[fallback] AnimeUnity fallito (${backupError.status ?? 500}): ${backupError.message}`,
      )
      throw primaryError
    }
  }
}

function canonicalFrom(req) {
  if (req.method === 'POST') {
    const body = req.body ?? {}
    return body.canonicalUrl ?? body.canonical_url ?? body.url ?? null
  }
  return req.query.url ?? req.query.canonical_url ?? null
}

function metaFrom(req) {
  if (req.method === 'POST') return req.body?.anime ?? null
  if (!req.query.anime) return null
  try {
    return JSON.parse(req.query.anime)
  } catch {
    return null
  }
}

function qualityFrom(req) {
  if (req.method === 'POST') return req.body?.quality ?? null
  return req.query.quality ?? null
}

async function handleExtract(req, res) {
  const canonical = canonicalFrom(req)
  const meta = metaFrom(req)
  const quality = qualityFrom(req)
  const started = Date.now()

  try {
    const result = await extract(canonical, meta, quality)
    console.log(
      `[${req.method}] /extract ${canonical} -> OK (${Date.now() - started}ms)` +
        (result.provider ? ` via ${result.provider}` : ''),
    )
    res.json(result)
  } catch (error) {
    const status =
      error instanceof ExtractError || error instanceof animeUnity.ProviderError
        ? error.status
        : 500
    const message =
      error instanceof ExtractError || error instanceof animeUnity.ProviderError
        ? error.message
        : 'Estrazione fallita.'
    console.log(
      `[${req.method}] /extract ${canonical} -> ERRORE ${status}: ${message}`,
    )
    res.status(status).json({ error: message })
  }
}

app.get('/health', (_req, res) => {
  res.json({ status: 'ok', service: 'anime-extractor', providers: ['animeworld', 'animeunity'] })
})

app.get('/extract', handleExtract)
app.post('/extract', handleExtract)

app.use((_req, res) => {
  res.status(404).json({ error: 'Rotta inesistente.' })
})

app.listen(PORT, HOST, () => {
  console.log(`anime-extractor in ascolto su http://${HOST}:${PORT}`)
})
