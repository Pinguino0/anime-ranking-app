// ============================================================================
// send-push - test
// ============================================================================
//
// Cosa coprono
// -----------
// I pezzi dove un errore si presenta come qualcos'altro:
//
//  - il riconoscimento del webhook, perche' un corpo non letto si presenta come
//    "push che non arriva" e non come "webhook configurato male";
//  - il mascheramento delle notifiche `sensitive`, perche' un titolo che sfugge
//    al lucchetto e' un danno per la privacy e non un bug visibile;
//  - l'autenticazione, perche' una funzione aperta e' un modo per mandare push a
//    chiunque.
//
// Il file NON tocca Supabase ne' Google: `sendPush` non viene invocato, perche'
// richiede una service account vera. Si provano le funzioni pure e le rotte che
// si fermano prima della rete.
// ============================================================================

import { assertEquals, assert } from 'jsr:@std/assert@1'

import {
  buildMessage,
  displayText,
  handleRequest,
  parseDailyLimit,
  parseServiceAccount,
  pemToPkcs8,
  readNotification,
} from './index.ts'

Deno.test('readNotification legge il record del webhook di Supabase', () => {
  const notification = readNotification({
    type: 'INSERT',
    table: 'notifications',
    record: {
      id: 'n1',
      user_id: 'u1',
      type: 'anime_recommended',
      title: 'Marco ti ha consigliato di vedere: Cowboy Bebop',
      body: 'Guardalo!',
      data: { anime_id: 'a1', group_id: 'g1' },
      sensitive: true,
    },
  })

  assert(notification !== null)
  assertEquals(notification.user_id, 'u1')
  assertEquals(notification.type, 'anime_recommended')
  assertEquals(notification.sensitive, true)
  assertEquals(notification.data, { anime_id: 'a1', group_id: 'g1' })
})

Deno.test('readNotification accetta anche la forma { notification }', () => {
  const notification = readNotification({
    notification: { user_id: 'u1', title: 'Ciao' },
  })

  assert(notification !== null)
  assertEquals(notification.title, 'Ciao')
  // Campi assenti hanno un default sensato invece di far fallire la lettura.
  assertEquals(notification.body, null)
  assertEquals(notification.data, {})
  assertEquals(notification.sensitive, false)
})

Deno.test('readNotification rifiuta un corpo senza destinatario', () => {
  assertEquals(readNotification({ record: { title: 'Ciao' } }), null)
  assertEquals(readNotification(null), null)
  assertEquals(readNotification({ record: { user_id: 'u1' } }), null)
})

Deno.test('displayText nasconde il contenuto delle notifiche sensitive', () => {
  const masked = displayText({
    user_id: 'u1',
    type: 'same_anime_rated',
    title: 'Un titolo che rivela cosa guarda',
    body: 'Corpo dettagliato',
    data: {},
    sensitive: true,
  })

  assertEquals(masked.title, 'animerank')
  assert(!masked.body.includes('dettagliato'))
})

Deno.test('displayText lascia intatto il testo quando non e sensitive', () => {
  const text = displayText({
    user_id: 'u1',
    type: 'anime_recommended',
    title: 'Consiglio',
    body: 'Guardalo',
    data: {},
    sensitive: false,
  })

  assertEquals(text, { title: 'Consiglio', body: 'Guardalo' })
})

Deno.test('buildMessage serializza i data in una stringa', () => {
  // FCM rifiuta i valori annidati in `data`: se qui restasse un oggetto, l'invio
  // tornerebbe INVALID_ARGUMENT e sembrerebbe un token sbagliato.
  const message = buildMessage('token-1', {
    id: 'n1',
    user_id: 'u1',
    type: 'anime_recommended',
    title: 'Consiglio',
    body: 'Guardalo',
    data: { anime_id: 'a1' },
    sensitive: false,
  })

  assertEquals(message.token, 'token-1')
  const data = message.data as Record<string, string>
  assertEquals(typeof data.payload, 'string')
  assertEquals(JSON.parse(data.payload), { anime_id: 'a1' })
  assertEquals(data.type, 'anime_recommended')
})

Deno.test('parseServiceAccount richiede tutti i campi', () => {
  let threw = false
  try {
    parseServiceAccount(JSON.stringify({ client_email: 'a@b.c' }))
  } catch (_) {
    threw = true
  }
  assert(threw)
})

Deno.test('pemToPkcs8 toglie intestazioni e a capo', () => {
  // Un PEM reale e' lungo: qui basta verificare che header, footer e spazi non
  // finiscano nei byte passati a WebCrypto.
  const bytes = pemToPkcs8('-----BEGIN PRIVATE KEY-----\nQUJD\n-----END PRIVATE KEY-----\n')
  assertEquals(Array.from(bytes), [65, 66, 67])
})

Deno.test('senza autenticazione il push viene rifiutato', async () => {
  const response = await handleRequest(
    new Request('https://example.com/send-push', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ record: { user_id: 'u1', title: 'Ciao' } }),
    }),
  )

  // Nessuna variabile d'ambiente nei test: la service key e' vuota e nessun
  // chiamante puo' risultare autorizzato.
  assertEquals(response.status, 401)
})

Deno.test('un segreto webhook inventato viene rifiutato', async () => {
  const response = await handleRequest(
    new Request('https://example.com/send-push', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-webhook-secret': 'indovinato',
      },
      body: JSON.stringify({ record: { user_id: 'u1', title: 'Ciao' } }),
    }),
  )

  assertEquals(response.status, 401)
})

Deno.test('health segnala lo stato degradato senza configurazione', async () => {
  const response = await handleRequest(new Request('https://example.com/health'))
  const body = await response.json() as Record<string, unknown>

  assertEquals(response.status, 503)
  assertEquals(body.service, 'send-push')
})

Deno.test('un metodo non POST viene rifiutato', async () => {
  const response = await handleRequest(
    new Request('https://example.com/send-push', { method: 'GET' }),
  )
  assertEquals(response.status, 405)
})

Deno.test('parseDailyLimit ricade su 3 con un valore assente o non numerico', () => {
  // Un errore di configurazione non deve spegnere le push: meglio il default
  // (3) che un tetto a zero che le bloccherebbe tutte.
  assertEquals(parseDailyLimit(''), 3)
  assertEquals(parseDailyLimit('   '), 3)
  assertEquals(parseDailyLimit('tre'), 3)
  assertEquals(parseDailyLimit('-1'), 3)
})

Deno.test('parseDailyLimit accetta un limite valido, zero compreso', () => {
  assertEquals(parseDailyLimit('3'), 3)
  assertEquals(parseDailyLimit(' 5 '), 5)
  // 0 e' un valore legittimo: nessuna push al giorno.
  assertEquals(parseDailyLimit('0'), 0)
})
