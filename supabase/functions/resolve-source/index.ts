// ============================================================================
// resolve-source - risolve una fonte episodio in un URL riproducibile
// ============================================================================
//
// Il buco che questa funzione riempia
// -----------------------------------
// `episode_sources` tiene un indirizzo CANONICO — la pagina o il riferimento
// del provider — che vale per sempre. Non tiene l'indirizzo del video, che vale
// pochi minuti e spesso richiede header per essere aperto. Il player non puo'
// aprire un indirizzo canonico, e puo' aprire solo quello risolto.
//
// Il flusso e' quello di Aniyomi: `resolve()` viene chiamato al momento della
// riproduzione, restituisce l'URL effimero piu' gli header, e nessuno dei due
// viene scritto da nessuna parte.
//
// Perche' una Edge Function e non una RPC
// ---------------------------------------
// Tre ragioni, in ordine di peso:
//
//   1. I segreti del provider (chiavi API, cookie, firme) non possono stare in
//      una funzione del database: una RPC e' sorgente leggibile da chi e'
//      autenticato e la sua firma finisce nei log del client. Le variabili
//      d'ambiente di una Edge Function non sono leggibili dal client.
//   2. Il resolver parla con la rete — e una funzione SQL non puo'.
//   3. Il tempo di risposta e' quello di una chiamata HTTP, e una RPC che
//      chiama la rete blocca una connessione di Postgres per tutto quel tempo.
//
// Cosa NON fa
// -----------
// Non scrive l'URL risolto. Non sa chi ha chiesto il video. Non valuta se
// l'utente puo' guardare quell'episodio: questo arriva dal fatto che la richiesta
// e' autenticata e che la fonte esiste ed e' attiva, e niente di piu'. Un
// resolver che decidesse chi puo' vedere cosa diventerebbe il posto dove mettere
// la logica di accesso, ed e' il posto sbagliato.
//
// Rotte
// -----
//   POST /resolve   body { "source_id": "<uuid>" }
//   GET  /health    stato della funzione e degli adapter registrati
//
// Il gateway chiama sempre la radice della funzione, quindi l'URL che arriva
// qui e' `/functions/v1/resolve-source`. Come in `jikan-proxy`, la rotta e' un
// parametro (`?route=`) e non un path, e il path resta accettato per chi chiama
// a mano.
// ============================================================================

import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'

import { extractWatchId, mockResolver } from './providers/mock.ts'
import { genericApiResolver } from './providers/generic-api.ts'
import { nativeResolver, ProviderError, requiresClientExtraction } from './providers/native.ts'
import { hentaiworldResolver } from './providers/hentaiworld.ts'
import type { AnimeEpisodeMeta, ProviderRow, SourceRow, SourceType, VideoResolver } from './types.ts'

// Iniezione di SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY: sono nelle
// impostazioni della funzione, non nel file.
//
// La service key serve perche' `episode_sources` e `providers` non hanno
// privilegi per `authenticated` (e non devono averli: si leggono da
// `episode_sources_list`, vedi la migration 028). La funzione e' l'unico
// soggetto autorizzato a leggerle in chiaro, ed e' quello che le fa da confine:
// il client non puo' chiedere "risolvi questo URL che ti mando io", puo' solo
// chiedere "risolvi la fonte numero X".
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

// Client creato in modo pigro, non al caricamento del modulo.
//
// Il motivo e' il test: `index.test.ts` importa questo file per provare le
// funzioni pure, e i test girano senza le variabili d'ambiente di Supabase. Un
// controllo che lancia all'avvio farebbe fallire l'intero file di test per un
// problema che riguarda solo la produzione.
type UntypedClient = SupabaseClient<any>

let supabaseClient: UntypedClient | null = null

function supabase(): UntypedClient {
  if (supabaseClient) return supabaseClient

  if (!SUPABASE_URL || !SERVICE_KEY) {
    // Fallire qui e' corretto: senza service key non c'e' nessun modo onesto di
    // sapere se la fonte esiste ed e' attiva, e rispondere 200 con un link
    // finto farebbe sembrare funzionante una funzione che non lo e'.
    throw new HttpError(
      500,
      'SUPABASE_URL o SUPABASE_SERVICE_ROLE_KEY mancanti nelle impostazioni della funzione.',
    )
  }

  supabaseClient = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  }) as UntypedClient

  return supabaseClient
}

// ---------------------------------------------------------------------------
// Adapter registrati
// ---------------------------------------------------------------------------
//
// Una mappa, non uno `if` per provider: aggiungere il provider vero vuol dire
// una riga in `providers` e una riga qui dentro, senza toccare la logica.
//
// Il valore di `providers.resolve_endpoint` e' il nome che fa da chiave. Se
// punta a qualcosa che non e' in questa mappa, la richiesta risponde 501 e lo
// dice: e' un adapter mancante, non un video non disponibile, e i due hanno
// cause diverse.
const RESOLVERS: Record<string, VideoResolver> = {
  mock: mockResolver,
  generic_api: genericApiResolver,
  native: nativeResolver,
  hentaiworld: hentaiworldResolver,
}

// ---------------------------------------------------------------------------
// Errori
// ---------------------------------------------------------------------------

class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly code = 'error',
  ) {
    super(message)
    this.name = 'HttpError'
  }
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      // Nessuna cache HTTP, e qui il motivo e' piu' forte che in jikan-proxy:
      // la risposta contiene un token con una scadenza. Una cache del browser
      // o del gateway rimanderebbe un token scaduto a un utente che sta solo
      // cercando di guardare un episodio.
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
    },
  })
}

// La funzione viene chiamata dall'app Flutter, che su Android e' un client
// nativo e su web fa richieste con Origin. Senza questi header il browser
// blocca la risposta.
//
// `POST` e' in lista perche' la risoluzione viaggia in body: il path della
// fonte puo' essere lungo e finire negli header di una richiesta su una riga e'
// fragile su alcuni proxy.
const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
}

// Le regole CORS valgono su qualunque risposta, anche d'errore: senza
// `Access-Control-Allow-Origin` il browser fa leggere a JavaScript solo il
// codice di stato e l'app vedrebbe "errore di rete" senza il motivo.
function withCors(response: Response): Response {
  for (const [key, value] of Object.entries(CORS_HEADERS)) {
    response.headers.set(key, value)
  }
  return response
}

function errorResponse(error: unknown): Response {
  if (error instanceof HttpError) {
    return json(
      { error: error.message, code: error.code },
      error.status,
    )
  }

  // Un provider che fallisce con uno stato proprio (404 episodio assente, 422
  // numero episodio mancante) ha un messaggio pensato per l'utente e un codice
  // piu' preciso del generico 500: si propaga, invece di appiattirlo tutto su
  // "Risoluzione non riuscita".
  if (error instanceof ProviderError) {
    return json({ error: error.message, code: error.code }, error.status)
  }

  console.error('resolve-source: errore non gestito', error)
  // Il messaggio interno non esce: puo' contenere URL con token o dettagli
  // della struttura del provider. Il client riceve un messaggio generico e il
  // dettaglio resta nei log.
  return json({ error: 'Risoluzione non riuscita. Riprova.', code: 'internal' }, 500)
}

// ---------------------------------------------------------------------------
// Rotte
// ---------------------------------------------------------------------------

const ROUTES = new Set(['/resolve', '/health'])

function resolveRoute(url: URL): string {
  // La rotta in query viene restituita cosi' com'e', anche se non e' in `ROUTES`:
  // serve al 404 per dire quale rotta era stata chiesta. Filtrarla qui
  // trasformerebbe "rotta inesistente" in "nessuna rotta", e il messaggio
  // d'errore perderebbe l'unica informazione utile.
  const fromQuery = url.searchParams.get('route')
  if (fromQuery && fromQuery.startsWith('/')) return fromQuery

  // Path diretto: l'ultimo segmento utile e' quello dopo il nome della funzione.
  // `/functions/v1/resolve-source/health` -> `/health`.
  const segments = url.pathname.split('/').filter(Boolean)
  const last = segments.length > 0 ? `/${segments[segments.length - 1]}` : url.pathname
  if (ROUTES.has(last)) return last

  // I client (supabase_flutter) invocano la funzione per nome senza `?route=`:
  // `/functions/v1/resolve-source`. L'ultimo segmento coincide col nome della
  // funzione, e la rotta implicita e' `/resolve`.
  if (last === '/resolve-source') return '/resolve'

  return url.pathname
}

// ---------------------------------------------------------------------------
// Validazione dell'input
// ---------------------------------------------------------------------------

// Un UUID, e nient'altro.
//
// Il campo viene interpolato in una query, quindi la validazione qui non e'
// solo buona pratica: e' quello che tiene lontano dal database una stringa
// costruita a mano. Il controllo e' sul formato intero, perche' un confronto
// solo "sembra un uuid" lascerebbe passare `00000000-0000-0000-0000-000000000001`
// come sarebbe legittimo e non lo e'.
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function isUuid(value: unknown): value is string {
  return typeof value === 'string' && UUID_PATTERN.test(value)
}

/**
 * Un indirizzo http o https?
 *
 * Il `canonical_url` viene dal database e lo scrivono solo gli amministratori,
 * ma il controllo costa due righe e chiude un caso che altrimenti si presenta
 * fra sei mesi: un `javascript:` o un `file:` in colonna fa passare la funzione
 * e il player ci manda sopra l'URL ricevuto, che a quel punto non e' piu' un
 * video.
 */
export function isHttpUrl(value: unknown): value is string {
  if (typeof value !== 'string') return false

  try {
    const url = new URL(value)
    return url.protocol === 'http:' || url.protocol === 'https:'
  } catch {
    return false
  }
}

const SOURCE_TYPES = new Set<SourceType>(['mp4', 'hls', 'iframe'])

function asSourceType(value: unknown): SourceType | null {
  return typeof value === 'string' && SOURCE_TYPES.has(value as SourceType)
    ? (value as SourceType)
    : null
}

// ---------------------------------------------------------------------------
// Lettura dal database
// ---------------------------------------------------------------------------

/**
 * I metadati dell'episodio: numero episodio e titoli dell'anime.
 *
 * Servono ai provider di backup: un canonical AnimeWorld si risolve da solo,
 * ma per ritrovare lo stesso episodio su AnimeUnity serve sapere di quale
 * titolo e di quale numero si sta parlando. La lettura e' best-effort: se la
 * catena anime->episodio non c'e' (dati incompleti), il resolver primario
 * continua a funzionare e solo il fallback risponderà che non sa dove cercare.
 */
async function readEpisodeMeta(episodeId: unknown): Promise<AnimeEpisodeMeta | undefined> {
  if (typeof episodeId !== 'string') return undefined

  const { data, error } = await supabase()
    .from('episodes')
    .select(
      'episode_num, anime:anime_id ( title, japanese_title, synonyms, external_id )',
    )
    .eq('id', episodeId)
    .maybeSingle()

  if (error) {
    console.error('resolve-source: lettura metadati episodio fallita', error.message)
    return undefined
  }

  // La relazione `anime` puo' arrivare come oggetto o come array di un
  // elemento a seconda di come il generatore di tipi la modella: si gestisce
  // entrambe le forme con la stessa lettura.
  const animeRow = Array.isArray(data?.anime) ? data.anime[0] : data?.anime

  // L'episodio senza anime non si risolve altrove: non c'e' titolo da cercare.
  if (!animeRow) return undefined

  return {
    episodeNumber:
      data && typeof data.episode_num === 'number' ? data.episode_num : null,
    title: typeof animeRow.title === 'string' ? animeRow.title : null,
    japaneseTitle:
      typeof animeRow.japanese_title === 'string'
        ? animeRow.japanese_title
        : null,
    synonyms: Array.isArray(animeRow.synonyms)
      ? animeRow.synonyms.filter((s: unknown): s is string => typeof s === 'string')
      : [],
    malId:
      typeof animeRow.external_id === 'string' &&
        /^\d+$/.test(animeRow.external_id)
        ? Number(animeRow.external_id)
        : null,
  }
}

/**
 * La fonte da risolvere sul client, con tutto quello che serve per farlo.
 *
 * Non e' un errore e non e' una risoluzione a meta': e' la risposta giusta per
 * le fonti che il backend non puo' risolvere (AnimeUnity, dietro Cloudflare) ma
 * che il telefono risolve benissimo con il suo IP residenziale. Il client riceve
 * l'indirizzo canonico invece dell'URL effimero e lo estrae da solo.
 *
 * `resolved_url` resta `null` apposta: metterci il canonico farebbe credere al
 * chiamante che sia riproducibile, e il player aprirebbe la pagina dell'anime
 * come se fosse un video.
 */
function clientResolutionPayload(
  source: SourceRow,
  provider: ProviderRow,
  anime: AnimeEpisodeMeta | undefined,
): Record<string, unknown> {
  return {
    source_id: source.id,
    canonical_url: source.canonicalUrl,
    resolved_url: null,
    headers: {},
    source_type: source.sourceType,
    expires_at: null,
    // Il campo che distingue questa risposta da una risoluzione server: e' il
    // client a doverla interpretare, e senza di esso sembrerebbe una
    // risoluzione fallita con un URL vuoto.
    resolution: 'client',
    // Il numero dell'episodio e' l'unica cosa che il canonico AnimeUnity non
    // porta con se': il path e' `/anime/{id}-x` e non contiene l'episodio.
    // Arriva dai metadati, che sono l'unico posto dove sta.
    episode_number: anime?.episodeNumber ?? null,
    quality: source.quality,
    provider: {
      slug: provider.slug,
      label: provider.label,
      adapter: 'client',
    },
  }
}

/**
 * La fonte richiesta, con il provider che la sa risolvere.
 *
 * Due query e non una con una join: la fonte arriva dal catalogo e il provider
 * e' una tabella di poche righe che cambia di rado, e tenere separate le due
 * letture rende piu' semplice capire quale delle due sta fallendo quando una
 * richiesta va storta.
 */
async function readSource(
  sourceId: string,
): Promise<{ source: SourceRow; provider: ProviderRow; anime?: AnimeEpisodeMeta }> {
  const client = supabase()

  const sourceResult = await client
    .from('episode_sources')
    .select(
      'id, episode_id, source_url, canonical_url, provider_id, source_type, quality, language, is_active',
    )
    .eq('id', sourceId)
    .maybeSingle()

  if (sourceResult.error) {
    // Non si propaga il messaggio di PostgREST com'e': puo' contenere nomi di
    // colonne e dettagli dello schema, che non serve al client sapere.
    console.error('resolve-source: lettura fonte fallita', sourceResult.error.message)
    throw new HttpError(500, 'Fonte non leggibile. Riprova.', 'source_unreadable')
  }

  const row = (sourceResult.data ?? {}) as Record<string, unknown>

  // 404 e non 403: la richiesta e' autenticata, quindi "non esiste" e "non e'
  // tua" non sono due domande diverse, e rispondere 403 farebbe pensare a un
  // problema di permessi dove invece la riga semplicemente non c'e'.
  if (!row.id) throw new HttpError(404, 'Fonte non trovata.', 'source_not_found')

  // Una fonte spenta e' una fonte che il backend ha deciso di non usare. Se
  // arrivasse qui la si risolverebbe lo stesso, vanificando la disattivazione:
  // il fallback automatico del client riproverebbe la fonte che e' stata
  // spenta apposta perche' non funziona piu'.
  if (row.is_active !== true) {
    throw new HttpError(404, 'Fonte non trovata.', 'source_not_found')
  }

  const type = asSourceType(row.source_type)
  if (type === null) {
    throw new HttpError(422, 'Formato della fonte non riconosciuto.', 'bad_source_type')
  }

  // Una fonte il cui provider e' stato cancellato ha `provider_id` a null
  // (ON DELETE SET NULL): mandare `null` in una `.eq` produce un errore di
  // PostgREST che finirebbe come 500 "provider illeggibile", mentre la
  // situazione reale e' che non c'e' nessun adapter che possa occuparsene.
  if (typeof row.provider_id !== 'string') {
    throw new HttpError(
      422,
      'Questa fonte non ha un provider associato.',
      'provider_missing',
    )
  }

  const providerResult = await client
    .from('providers')
    .select('slug, label, resolve_endpoint, is_active')
    .eq('id', row.provider_id)
    .maybeSingle()

  if (providerResult.error) {
    console.error('resolve-source: lettura provider fallita', providerResult.error.message)
    throw new HttpError(500, 'Provider non leggibile. Riprova.', 'provider_unreadable')
  }

  const providerRow = (providerResult.data ?? {}) as Record<string, unknown>

  if (!providerRow.slug) {
    throw new HttpError(
      422,
      'Questa fonte non ha un provider associato.',
      'provider_missing',
    )
  }

  if (providerRow.is_active !== true) {
    throw new HttpError(
      422,
      'Il provider di questa fonte non e\' attivo.',
      'provider_inactive',
    )
  }

  return {
    source: {
      id: String(row.id),
      sourceUrl: typeof row.source_url === 'string' ? row.source_url : null,
      canonicalUrl:
        typeof row.canonical_url === 'string' && row.canonical_url !== ''
          ? row.canonical_url
          : null,
      sourceType: type,
      quality: typeof row.quality === 'string' ? row.quality : null,
      language: typeof row.language === 'string' ? row.language : null,
    },
    provider: {
      slug: String(providerRow.slug),
      label: String(providerRow.label ?? providerRow.slug),
      resolveEndpoint: String(providerRow.resolve_endpoint ?? 'mock'),
    },
    anime: await readEpisodeMeta(row.episode_id),
  }
}

// ---------------------------------------------------------------------------
// Azioni
// ---------------------------------------------------------------------------

/**
 * Risolve una fonte.
 *
 * `canonicalUrl` viene riletto dal database e non preso dal body. E' la
 * differenza fra una funzione che risolve una fonte del catalogo e una che fa
 * da proxy aperto per qualunque indirizzo: il client che chiama puo' scegliere
 * *quale* fonte risolvere, non *cosa* risolvere.
 */
export async function resolveSource(
  sourceId: string,
  clientExtract = false,
): Promise<Record<string, unknown>> {
  if (!isUuid(sourceId)) {
    throw new HttpError(400, 'source_id non e\' un identificativo valido.', 'bad_source_id')
  }

  const { source, provider, anime } = await readSource(sourceId)

  // Una fonte senza canonical_url e' una fonte gia' riproducibile: il client
  // non ha nessuna ragione di chiamare questa funzione, e se la chiama e'
  // perche' qualcosa non torna. Rispondere con `source_url` qui sembrerebbe
  // gentile e nasconderebbe il problema, quindi si dice cosa sta succedendo.
  if (source.canonicalUrl === null) {
    throw new HttpError(
      422,
      'Questa fonte e\' gia\' un indirizzo riproducibile e non va risolta.',
      'not_resolvable',
    )
  }

  if (!isHttpUrl(source.canonicalUrl)) {
    throw new HttpError(
      422,
      'L\'indirizzo canonico della fonte non e\' un URL http.',
      'bad_canonical_url',
    )
  }

  // Una fonte che il datacenter non puo' risolvere (AnimeUnity dietro
  // Cloudflare) viene risolta dall'app, che ha l'IP dell'utente. Il client lo
  // segnala esplicitamente: senza il segnale questo ramo cambierebbe la forma
  // della risposta anche per le versioni vecchie dell'app, che non saprebbero
  // leggere `resolution: "client"` e vedrebbero solo un URL vuoto.
  if (clientExtract && requiresClientExtraction(source.canonicalUrl)) {
    return clientResolutionPayload(source, provider, anime)
  }

  const resolver = RESOLVERS[provider.resolveEndpoint]
  if (resolver === undefined) {
    // 501 e non 404: la funzione c'e', ma per questo provider non c'e' nessun
    // adapter. Sono due fatti diversi e un 501 dice "manca un pezzo", mentre un
    // 404 direbbe che la rotta non esiste e porterebbero a guardare nel posto
    // sbagliato.
    console.error(
      `resolve-source: nessun adapter per l'endpoint "${provider.resolveEndpoint}" ` +
        `(provider ${provider.slug}). Adapter registrati: ${Object.keys(RESOLVERS).join(', ')}`,
    )
    throw new HttpError(
      501,
      'Questo provider non e\' ancora supportato.',
      'adapter_missing',
    )
  }

  const started = Date.now()

  const result = await resolver.resolve({
    source,
    canonicalUrl: source.canonicalUrl,
    provider,
    // Presente soltanto quando la catena catalogo->episodio->anime esiste.
    // I resolver che non ne hanno bisogno lo ignorano.
    anime,
  })

  // Il punto del progetto, scritto qui perche' e' il posto in cui si sbaglia
  // piu' facilmente: questa risposta viene buttata via dopo la riproduzione.
  // Scriverla in `episode_sources` trasformerebbe il catalogo in un magazzino di
  // token scaduti, che e' esattamente il problema da cui siamo partiti.
  console.log(
    `resolve-source: ${provider.slug} ha risolto ${source.id} in ${Date.now() - started}ms`,
  )

  return {
    source_id: source.id,
    // L'URL canonico torna indietro perche' il client lo mette accanto al
    // link effimero nei log di debug: quando una fonte non parte, la domanda
    // utile non e' "perche' il file non si apre" ma " quale indirizzo hai
    // aperto", e senza il canonico il link effimero non dice niente.
    canonical_url: source.canonicalUrl,
    resolved_url: result.resolvedUrl,
    headers: result.headers,
    source_type: result.sourceType,
    expires_at: result.expiresAt,
    provider: {
      slug: provider.slug,
      label: provider.label,
      adapter: resolver.endpoint,
    },
  }
}

/**
 * Lo stato della funzione.
 *
 * Non dice solo che il processo e' vivo: dice quali adapter ci sono. Una 200
 * qui con zero adapter e' un'indicazione falsa, perche' finche' nessun provider
 * e' stato risolto non si sa se qualcuno puo' guardare qualcosa.
 */
function health(): Record<string, unknown> {
  const adapters = Object.keys(RESOLVERS)

  return {
    status: adapters.length > 0 ? 'ok' : 'degraded',
    service: 'resolve-source',
    adapters,
    // `true` finche' il provider di prova e' l'unico registrato: e' l'informazione
    // che dice se la catena sta girando sul finto o sul provider vero, e senza
    // di essa un collaudo non distingue le due situazioni.
    mockOnly: adapters.length === 1 && adapters[0] === 'mock',
    time: new Date().toISOString(),
  }
}

// ---------------------------------------------------------------------------
// Gestione della richiesta
// ---------------------------------------------------------------------------

/** I parametri della richiesta di risoluzione, dal body o dalla query. */
async function readResolveParams(
  request: Request,
  url: URL,
): Promise<{ sourceId: string | null; clientExtract: boolean }> {
  // Il body e' la via normale. La query string e' accettata per il collaudo a
  // mano con `curl`, dove scrivere un JSON in un POST e' scomodo — non e' una
  // seconda modalita' con comportamento diverso.
  if (request.method === 'POST') {
    const contentType = request.headers.get('content-type') ?? ''
    if (!contentType.includes('application/json')) {
      return { sourceId: null, clientExtract: false }
    }

    let body: unknown
    try {
      body = await request.json()
    } catch {
      return { sourceId: null, clientExtract: false }
    }

    const record = (body ?? {}) as Record<string, unknown>
    return {
      sourceId: typeof record.source_id === 'string' ? record.source_id : null,
      clientExtract: record.client_extract === true,
    }
  }

  return {
    sourceId: url.searchParams.get('source_id'),
    clientExtract: url.searchParams.get('client_extract') === '1',
  }
}

export async function handleRequest(request: Request): Promise<Response> {
  // Preflight: risponde senza eseguire nulla, altrimenti il browser non parte.
  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS })
  }

  const url = new URL(request.url)
  const route = resolveRoute(url)

  try {
    // `/health` e' l'unica rotta pubblica: serve a capire se la funzione e'
    // viva senza avere un token, e senza un token non si puo' nemmeno sapere
    // se il problema e' l'autenticazione o la risoluzione. Non restituisce
    // nulla di sensibile — solo quali adapter ci sono.
    if (route === '/health') {
      const status = health()
      return withCors(json(status, status.status === 'ok' ? 200 : 503))
    }

    // --- Autenticazione -------------------------------------------------------
    //
    // La validazione vera la fa la piattaforma Supabase prima di arrivare qui,
    // se la funzione ha `verify_jwt = true`. Il controllo sotto e' deliberatamente
    // debole perche' non puo' fare di meglio: non c'e' un client Supabase con
    // cui validare il token, e verificare il JWT a mano (firma, scadenza,
    // audience) significherebbe duplicare codice crittografico che puo' sbagliare
    // in silenzio. La difesa vera e' `verify_jwt`, da mettere nelle impostazioni
    // della funzione al deploy.
    if (!request.headers.get('Authorization')) {
      return withCors(
        json({ error: 'Autenticazione richiesta.', code: 'unauthorized' }, 401),
      )
    }

    if (route !== '/resolve') {
      return withCors(
        json(
          {
            error: `Rotta sconosciuta: ${route}`,
            code: 'not_found',
            routes: ['POST /resolve { "source_id": "<uuid>" }', 'GET /health'],
          },
          404,
        ),
      )
    }

    if (request.method !== 'POST' && request.method !== 'GET') {
      return withCors(
        json({ error: 'Solo POST o GET.', code: 'method_not_allowed' }, 405),
      )
    }

    const { sourceId, clientExtract } = await readResolveParams(request, url)
    if (sourceId === null || sourceId.trim() === '') {
      return withCors(
        json(
          { error: 'source_id obbligatorio.', code: 'missing_source_id' },
          400,
        ),
      )
    }

    return withCors(json(await resolveSource(sourceId, clientExtract)))
  } catch (error) {
    return withCors(errorResponse(error))
  }
}

// Avvio del server solo se questo file e' il punto d'ingresso. Sotto
// `deno test` l'import non deve aprire porte.
if (import.meta.main) {
  Deno.serve(handleRequest)
}

// Esportazioni per i test con Deno: senza, la validazione dell'input e il
// resolver finto sarebbero verificabili solo passando da una chiamata HTTP reale.
export { RESOLVERS, extractWatchId, mockResolver, readResolveParams, resolveRoute }
export { mockTokenPayload, signMockToken } from './providers/mock.ts'
export type { ProviderRow, ResolveRequest, ResolveResult, SourceRow, SourceType, VideoResolver } from './types.ts'
