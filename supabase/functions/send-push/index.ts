// ============================================================================
// send-push - manda su FCM le notifiche appena scritte in `notifications`
// ============================================================================
//
// Come funziona la catena
// -----------------------
// Le notifiche le scrivono i TRIGGER del database (vedi 011_notifications.sql):
// il client non e' mai coinvolto, e va bene cosi', perche' "Marco ti ha
// consigliato un anime" deve arrivare anche se la raccomandazione arriva dalla
// coda offline. Il database pero' sa solo scrivere una riga: per raggiungere il
// telefono serve qualcuno che parli con Google.
//
// Quel qualcuno e' questa funzione, agganciata a un Database Webhook su
// `notifications` (INSERT). Riceve la riga appena creata, legge i token del
// destinatario da `device_tokens` e spedisce su FCM HTTP v1.
//
// Perche' non `notify_user` manda il push da solo
// -----------------------------------------------
// I segreti FCM (la chiave privata della service account) non possono stare in
// una funzione del database: una funzione SQL e' leggibile da chi e'
// autenticato. Le variabili d'ambiente di una Edge Function no.
//
// Cosa NON fa
// -----------
// Non decide il testo: arriva gia' scritto da `notifications`. Non decide chi
// riceve: la riga dice `user_id`. Non scrive notifiche: le legge e le spedisce.
// Un push che fallisce non tocca la notifica in-app, che resta li' comunque.
//
// Limite giornaliero per dispositivo
// ----------------------------------
// Un dispositivo non riceve piu' di `PUSH_DAILY_LIMIT` push al giorno (default
// 3). Il conteggio vive su `device_tokens` (`push_count`/`push_date`) e lo
// prenota la RPC `reserve_push_slot` *prima* di ogni invio: due notifiche scritte
// nello stesso istante non possono sforare il tetto, perche' il controllo sta
// dentro l'UPDATE (vedi 20261011203000_push_daily_limit.sql).
//
// Il limite riguarda gli avvisi *sul dispositivo*, non il centro notifiche:
// quando una push viene fermata, la riga in `notifications` resta e l'utente la
// vede aprendo l'app. Vale per tutti i tipi, `app_update` compreso.
//
// Rotte
// -----
//   POST /            webhook standard di Supabase
//                     { "type": "INSERT", "table": "notifications", "record": {...} }
//   POST /?route=push stesso corpo; accetta anche { "notification": {...} }
//   GET  /?route=health stato della funzione (project id presente, chiave presente)
//
// Sicurezza
// ---------
// La funzione rifiuta chi non presenta la SERVICE ROLE KEY nell'header
// `Authorization`. Il webhook di Supabase, configurato con la service key,
// passa; lo stesso token e' quello che usa `notify_user` e che un client non
// possiede. Senza questo controllo chiunque conosca l'URL potrebbe fabbricare
// un push a un utente a caso.
// ============================================================================

import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''

/** Il JSON della service account Firebase, in un unico segreto. */
const FIREBASE_SERVICE_ACCOUNT = Deno.env.get('FIREBASE_SERVICE_ACCOUNT') ?? ''

/**
 * Segreto condiviso col trigger del database (`notify_push_webhook`).
 *
 * La service role key non puo' stare nel trigger: sarebbe un segreto potente
 * scritto nel database (e quindi nella migration). Il trigger legge invece
 * questo valore da Vault e lo manda nell'header `x-webhook-secret`. Vuoto = il
 * webhook non e' configurato, ma la funzione resta usabile a mano con la
 * service key.
 */
const WEBHOOK_SECRET = Deno.env.get('PUSH_WEBHOOK_SECRET') ?? ''

// Canale Android creato dal client prima di ricevere il primo push. Il nome deve
// combaciare con quello registrato in `flutter_local_notifications`; se non
// esiste, Android mostra l'avviso con il canale di default del sistema.
const ANDROID_CHANNEL_ID = 'animerank_default'

/**
 * Quante push al giorno puo' ricevere un singolo dispositivo.
 *
 * Modificabile dal segreto `PUSH_DAILY_LIMIT` della funzione; senza segreto vale
 * 3. Un valore assente o non numerico ricade sul default invece di bloccare i
 * push per sempre: un errore di configurazione non deve spegnere le notifiche.
 */
export function parseDailyLimit(raw: string): number {
  const value = Number.parseInt(raw.trim(), 10)
  if (!Number.isFinite(value) || value < 0) return 3
  return value
}

const DAILY_LIMIT = parseDailyLimit(Deno.env.get('PUSH_DAILY_LIMIT') ?? '')

type UntypedClient = SupabaseClient<any>

let supabaseClient: UntypedClient | null = null

function supabase(): SupabaseClient<any> {
  if (supabaseClient) return supabaseClient
  if (!SUPABASE_URL || !SERVICE_KEY) {
    throw new HttpError(500, 'SUPABASE_URL o SUPABASE_SERVICE_ROLE_KEY mancanti.')
  }
  supabaseClient = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  }) as SupabaseClient<any>
  return supabaseClient
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
// La notifica che arriva dal webhook
// ---------------------------------------------------------------------------

export interface NotificationRecord {
  id?: string
  user_id: string
  type: string
  title: string
  body: string | null
  data: Record<string, unknown>
  sensitive: boolean
}

/**
 * Estrae la riga di `notifications` dal corpo del webhook.
 *
 * Il Database Webhook standard la mette sotto `record`; una chiamata a mano puo'
 * mandarla sotto `notification`. Accettare entrambe evita di dover ricordare la
 * forma a memoria quando si collauda con `curl`.
 */
export function readNotification(body: unknown): NotificationRecord | null {
  const record = (body ?? {}) as Record<string, unknown>
  const source = (record.record ?? record.notification ?? record) as Record<string, unknown>

  if (typeof source !== 'object' || source === null) return null
  if (typeof source.user_id !== 'string' || source.user_id === '') return null
  if (typeof source.title !== 'string') return null

  return {
    id: typeof source.id === 'string' ? source.id : undefined,
    user_id: source.user_id,
    type: typeof source.type === 'string' ? source.type : 'notification',
    title: source.title,
    body: typeof source.body === 'string' ? source.body : null,
    data:
      typeof source.data === 'object' && source.data !== null
        ? (source.data as Record<string, unknown>)
        : {},
    sensitive: source.sensitive === true,
  }
}

/**
 * Il titolo e il corpo da mettere nella notifica di sistema.
 *
 * `sensitive` esiste proprio per non far leggere il contenuto dalla schermata
 * di blocco (un titolo di anime puo' rivelare cosa sta guardando una persona).
 * FCM non ha un equivalente affidabile di "nascondi sotto il lucchetto", quindi
 * si manda un testo generico: la notifica serve ad aprire l'app, il contenuto
 * vero e' nel centro notifiche in-app.
 */
export function displayText(notification: NotificationRecord): {
  title: string
  body: string
} {
  if (notification.sensitive) {
    return { title: 'animerank', body: 'Hai una nuova notifica. Apri l app per vederla.' }
  }

  return {
    title: notification.title,
    body: notification.body ?? '',
  }
}

// ---------------------------------------------------------------------------
// FCM HTTP v1 - access token dalla service account
// ---------------------------------------------------------------------------
//
// Un access token OAuth2 dura un'ora. La funzione puo' restare calda fra una
// chiamata e l'altra, quindi si tiene in memoria il token e la sua scadenza:
// senza cache ogni notifica pagherebbe un giro di rete verso Google solo per
// farsi autorizzare.

let cachedAccessToken: { token: string; expiresAt: number } | null = null

interface ServiceAccount {
  client_email: string
  private_key: string
  project_id: string
}

export function parseServiceAccount(raw: string): ServiceAccount {
  const parsed = JSON.parse(raw) as Record<string, unknown>

  if (
    typeof parsed.client_email !== 'string' ||
    typeof parsed.private_key !== 'string' ||
    typeof parsed.project_id !== 'string'
  ) {
    throw new HttpError(
      500,
      'FIREBASE_SERVICE_ACCOUNT non contiene client_email, private_key e project_id.',
      'bad_service_account',
    )
  }

  return {
    client_email: parsed.client_email,
    private_key: parsed.private_key,
    project_id: parsed.project_id,
  }
}

function base64Url(bytes: Uint8Array): string {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_')
}

function base64UrlJson(value: unknown): string {
  return base64Url(new TextEncoder().encode(JSON.stringify(value)))
}

/** Dal PEM (`-----BEGIN PRIVATE KEY-----`) ai byte PKCS#8 che WebCrypto importa. */
export function pemToPkcs8(pem: string): Uint8Array<ArrayBuffer> {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\s+/g, '')

  const binary = atob(body)
  // Buffer esplicito di tipo `ArrayBuffer`: WebCrypto non accetta la vista
  // generica `Uint8Array<ArrayBufferLike>` che nasce da `new Uint8Array(length)`.
  const buffer = new ArrayBuffer(binary.length)
  const bytes = new Uint8Array(buffer)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes
}

async function fetchAccessToken(account: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  if (cachedAccessToken && cachedAccessToken.expiresAt > now + 60) {
    return cachedAccessToken.token
  }

  const header = base64UrlJson({ alg: 'RS256', typ: 'JWT' })
  const claims = base64UrlJson({
    iss: account.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  })

  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToPkcs8(account.private_key),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  )

  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    key,
    new TextEncoder().encode(`${header}.${claims}`),
  )

  const jwt = `${header}.${claims}.${base64Url(new Uint8Array(signature))}`

  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  })

  if (!response.ok) {
    const detail = await response.text()
    console.error('send-push: token OAuth2 rifiutato', response.status, detail)
    throw new HttpError(502, 'Autorizzazione verso FCM non riuscita.', 'fcm_auth')
  }

  const payload = (await response.json()) as { access_token?: string; expires_in?: number }
  if (typeof payload.access_token !== 'string') {
    throw new HttpError(502, 'FCM non ha restituito un access token.', 'fcm_auth')
  }

  cachedAccessToken = {
    token: payload.access_token,
    expiresAt: now + (typeof payload.expires_in === 'number' ? payload.expires_in : 3600),
  }

  return cachedAccessToken.token
}

// ---------------------------------------------------------------------------
// Invio
// ---------------------------------------------------------------------------

/** Costruisce il messaggio FCM per un token. */
export function buildMessage(
  token: string,
  notification: NotificationRecord,
): Record<string, unknown> {
  const text = displayText(notification)

  return {
    token,
    notification: {
      title: text.title,
      body: text.body,
    },
    data: {
      // I valori di `data` devono essere stringhe: FCM rifiuta i tipi annidati,
      // quindi il payload di navigazione viene serializzato qui e riletto dal
      // client con `jsonDecode`.
      payload: JSON.stringify(notification.data ?? {}),
      type: notification.type,
      notification_id: notification.id ?? '',
    },
    android: {
      priority: 'high',
      notification: {
        channel_id: 'animerank_default',
        sound: 'default',
      },
    },
    apns: {
      payload: {
        aps: {
          sound: 'default',
          // `sensitive` conta anche per iOS: il contenuto non compare
          // nell'anteprima della schermata di blocco.
          'thread-id': notification.type,
        },
      },
    },
  }
}

interface SendOutcome {
  ok: boolean
  /** true se il token non e' piu' valido e va cancellato dal database. */
  dead: boolean
}

async function sendToToken(
  projectId: string,
  accessToken: string,
  token: string,
  notification: NotificationRecord,
): Promise<SendOutcome> {
  const response = await fetch(
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ message: buildMessage(token, notification) }),
    },
  )

  if (response.ok) return { ok: true, dead: false }

  const detail = await response.text()

  // UNREGISTERED = app disinstallata o token ruotato; INVALID_ARGUMENT su un
  // token malformato. In entrambi i casi il token non tornera' a funzionare:
  // tenerlo significherebbe ritentare per sempre un invio che non arriva.
  const dead =
    response.status === 404 ||
    detail.includes('UNREGISTERED') ||
    detail.includes('INVALID_ARGUMENT') ||
    detail.includes('registration-token-not-registered')

  if (!dead) {
    console.error('send-push: invio rifiutato', response.status, detail)
  }

  return { ok: false, dead }
}

// ---------------------------------------------------------------------------
// Azione
// ---------------------------------------------------------------------------

export async function sendPush(
  notification: NotificationRecord,
  client: SupabaseClient<any> = supabase(),
): Promise<Record<string, unknown>> {
  if (!FIREBASE_SERVICE_ACCOUNT) {
    throw new HttpError(
      500,
      'FIREBASE_SERVICE_ACCOUNT non impostata fra i segreti della funzione.',
      'missing_service_account',
    )
  }

  const account = parseServiceAccount(FIREBASE_SERVICE_ACCOUNT)

  const { data: rows, error } = await client
    .from('device_tokens')
    .select('token')
    .eq('user_id', notification.user_id)

  if (error) {
    console.error('send-push: lettura token fallita', error.message)
    throw new HttpError(500, 'Token non leggibili. Riprova.', 'tokens_unreadable')
  }

  const tokens = (rows ?? [])
    .map((row) => (row as { token?: unknown }).token)
    .filter((token): token is string => typeof token === 'string' && token !== '')

  // Nessun dispositivo: non e' un errore. L'utente ha la notifica in-app e la
  // vedra' alla prossima apertura.
  if (tokens.length === 0) {
    return { sent: 0, failed: 0, removed: 0, throttled: 0, limit: DAILY_LIMIT, skipped: 'no_tokens' }
  }

  const accessToken = await fetchAccessToken(account)

  let sent = 0
  let failed = 0
  let throttled = 0
  const deadTokens: string[] = []

  for (const token of tokens) {
    // Prenota lo slot PRIMA dell'invio: se il dispositivo ha gia' ricevuto
    // `DAILY_LIMIT` push oggi, questa non parte. Lo slot si consuma anche se
    // FCM poi rifiuta, cosi' un errore non apre la strada a una raffica.
    if (!await reservePushSlot(client, token, DAILY_LIMIT)) {
      throttled++
      continue
    }

    const outcome = await sendToToken(account.project_id, accessToken, token, notification)
    if (outcome.ok) {
      sent++
    } else {
      failed++
      if (outcome.dead) deadTokens.push(token)
    }
  }

  if (deadTokens.length > 0) {
    // La cancellazione e' best-effort: se fallisce, la prossima notifica
    // ritentera' e rimuovera' di nuovo. Non deve far fallire l'invio riuscito.
    const { error: deleteError } = await client
      .from('device_tokens')
      .delete()
      .in('token', deadTokens)

    if (deleteError) {
      console.error('send-push: pulizia token morti fallita', deleteError.message)
    }
  }

  return {
    sent,
    failed,
    removed: deadTokens.length,
    throttled,
    limit: DAILY_LIMIT,
    project: account.project_id,
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
      'Cache-Control': 'no-store',
    },
  })
}

function errorResponse(error: unknown): Response {
  if (error instanceof HttpError) {
    return json({ error: error.message, code: error.code }, error.status)
  }

  console.error('send-push: errore non gestito', error)
  return json({ error: 'Invio non riuscito.', code: 'internal' }, 500)
}

/**
 * Il chiamante e' autorizzato?
 *
 * Due strade, entrambe con un confronto semplice: non e' una password scelta da
 * un utente e non c'e' nessun oracolo di timing che valga la pena sfruttare su
 * una funzione che comunque fa un giro fino a Google.
 *
 *  1. La **service role key** nell'header `Authorization`: serve a chi chiama a
 *     mano (collaudo con `curl`).
 *  2. Il **segreto condiviso** del webhook nell'header `x-webhook-secret`: e' la
 *     strada del trigger `notify_push_webhook`, che non conosce la service key.
 */
function isAuthorized(request: Request): boolean {
  const header = request.headers.get('Authorization') ?? ''
  const bearer = header.startsWith('Bearer ') ? header.slice(7) : header
  if (SERVICE_KEY !== '' && bearer !== '' && bearer === SERVICE_KEY) return true

  const webhook = request.headers.get('x-webhook-secret') ?? ''
  if (WEBHOOK_SECRET !== '' && webhook !== '' && webhook === WEBHOOK_SECRET) {
    return true
  }

  return false
}

function health(): Record<string, unknown> {
  let project: string | null = null
  if (FIREBASE_SERVICE_ACCOUNT) {
    try {
      project = parseServiceAccount(FIREBASE_SERVICE_ACCOUNT).project_id
    } catch {
      project = null
    }
  }

  return {
    status: FIREBASE_SERVICE_ACCOUNT && SUPABASE_URL && SERVICE_KEY ? 'ok' : 'degraded',
    service: 'send-push',
    project,
    serviceAccount: FIREBASE_SERVICE_ACCOUNT !== '',
    webhookSecret: WEBHOOK_SECRET !== '',
    supabase: SUPABASE_URL !== '',
    dailyLimit: DAILY_LIMIT,
  }
}

export async function handleRequest(request: Request): Promise<Response> {
  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204 })
  }

  const url = new URL(request.url)
  const route = url.searchParams.get('route') ??
    (url.pathname.endsWith('/health') ? '/health' : '/')

  try {
    // `/health` e' l'unica rotta pubblica: dice se la funzione e' configurata
    // senza chiedere un token, e senza un token non si distingue "non
    // autorizzato" da "non configurata".
    if (route === '/health') {
      if (request.method !== 'GET') {
        return json({ error: 'Solo GET.', code: 'method_not_allowed' }, 405)
      }
      const status = health()
      return json(status, status.status === 'ok' ? 200 : 503)
    }

    if (request.method !== 'POST') {
      return json({ error: 'Solo POST.', code: 'method_not_allowed' }, 405)
    }

    if (!isAuthorized(request)) {
      return json({ error: 'Non autorizzato.', code: 'unauthorized' }, 401)
    }

    let body: unknown
    try {
      body = await request.json()
    } catch {
      return json({ error: 'Corpo JSON non valido.', code: 'bad_body' }, 400)
    }

    const notification = readNotification(body)
    if (notification === null) {
      return json(
        { error: 'Notifica non riconosciuta.', code: 'bad_notification' },
        400,
      )
    }

    return json(await sendPush(notification))
  } catch (error) {
    return errorResponse(error)
  }
}

if (import.meta.main) {
  Deno.serve(handleRequest)
}

// Esportazioni per i test con Deno: senza, masking e parsing sarebbero
// verificabili solo con un invio vero verso Google.
export { errorResponse, isAuthorized, json }
export type { SendOutcome }
