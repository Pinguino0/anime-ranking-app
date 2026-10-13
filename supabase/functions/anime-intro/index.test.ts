// ============================================================================
// anime-intro - test
// ============================================================================
//
// Cosa coprono
// -----------
// Il confine fra la risposta di AniSkip e la finestra che finisce nel player, e
// la lettura della durata che AniSkip pretende. Un errore qui si presenta come
// "il pulsante non compare mai" oppure "salta nel punto sbagliato": entrambi
// senza nessun altro sintomo.
//
// Il fetch non viene toccato: queste sono funzioni pure, e la parte che parla
// con la rete e' verificata end-to-end con una chiamata vera.
// ============================================================================

import { aniskipUrl, episodeLengthSeconds, parseSkipTimes } from './index.ts'

Deno.test('aniskipUrl: chiede il tipo op e la durata episodio', () => {
  const url = new URL(aniskipUrl(21, 3, 1440))
  assertEquals(url.origin + url.pathname, 'https://api.aniskip.com/v2/skip-times/21/3')
  assertEquals(url.searchParams.get('types[]'), 'op')
  assertEquals(url.searchParams.get('episodeLength'), '1440')
})

Deno.test('parseSkipTimes: legge la sigla di testa', () => {
  const window = parseSkipTimes({
    found: true,
    results: [
      { interval: { startTime: 310.571, endTime: 400.571 }, skipType: 'op' },
    ],
  })
  assertEquals(window, { start: 311, end: 401 })
})

Deno.test('parseSkipTimes: ignora la sigla finale', () => {
  const window = parseSkipTimes({
    found: true,
    results: [
      { interval: { startTime: 1300, endTime: 1380 }, skipType: 'ed' },
      { interval: { startTime: 130, endTime: 668 }, skipType: 'op' },
    ],
  })
  assertEquals(window, { start: 130, end: 668 })
})

Deno.test('parseSkipTimes: una risposta vuota non e\' una finestra', () => {
  assertEquals(parseSkipTimes({ found: false, results: [] }), null)
  assertEquals(parseSkipTimes({ found: true, results: [] }), null)
  assertEquals(parseSkipTimes(null), null)
})

Deno.test('parseSkipTimes: una fine prima dell\'inizio non e\' una finestra', () => {
  assertEquals(
    parseSkipTimes({
      found: true,
      results: [{ interval: { startTime: 90, endTime: 30 }, skipType: 'op' }],
    }),
    null,
  )
})

Deno.test('episodeLengthSeconds: converte i minuti di AnimeUnity in secondi', () => {
  assertEquals(episodeLengthSeconds({ episodes_length: 24 }), 1440)
  // Le stringhe arrivano cosi' dai record esterni.
  assertEquals(episodeLengthSeconds({ episodes_length: '24' }), 1440)
})

Deno.test('episodeLengthSeconds: senza il dato usa la misura normale', () => {
  assertEquals(episodeLengthSeconds({}), 1440)
  assertEquals(episodeLengthSeconds(null), 1440)
  // Un valore sporco non e' una durata: si preferisce il default.
  assertEquals(episodeLengthSeconds({ episodes_length: 0.01 }), 1440)
})

function assertEquals<T>(actual: T, expected: T, message?: string): void {
  const a = JSON.stringify(actual)
  const b = JSON.stringify(expected)
  if (a === b) return
  throw new Error(message ?? `atteso ${b}, trovato ${a}`)
}
