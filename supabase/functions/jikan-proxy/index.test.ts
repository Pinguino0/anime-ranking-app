// Test per jikan-proxy. Girano con: deno test -A
//
// Si testano solo le funzioni pure (la mappatura da Jikan, lo status, la data,
// lo score). Le funzioni che chiamano fetch o il database non si testano qui:
// farebbero richieste vere, e un test che chiama l'API esterna a ogni run
// fallisce quando l'esterno e' lento e non dice niente del codice locale.
//
// Test del resto (rate limit, cache, upsert) serve un ambiente con rete:
// si fa una volta a mano dopo il deploy, non a ogni build.

import {
  assertEquals,
  assertNotEquals,
} from 'jsr:@std/assert@^1'

import {
  isFresh,
  mapEntry,
  mapMediaType,
  mapStatus,
  resolveRoute,
  toDate,
  toScore,
} from './index.ts'

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------
Deno.test('mapStatus: i tre valori attesi', () => {
  assertEquals(mapStatus('Finished Airing'), 'finished_airing')
  assertEquals(mapStatus('Currently Airing'), 'currently_airing')
  assertEquals(mapStatus('Not yet aired'), 'not_yet_aired')
})

Deno.test('mapStatus: spaziature e casi non rompono', () => {
  assertEquals(mapStatus('finished airing'), 'finished_airing')
  assertEquals(mapStatus('FINISHED_AIRING'), 'finished_airing')
  assertEquals(mapStatus('  Currently   Airing  '), 'currently_airing')
})

Deno.test('mapStatus: un valore sconosciuto dà null, non una copia a caso', () => {
  // Il fallback silenzioso su un valore estraneo metterebbe in colonna uno
  // stato inesistente: l'enum lo rifiuterebbe e l'upsert fallirebbe.
  assertEquals(mapStatus('Hiatus'), null)
  assertEquals(mapStatus('Cancelled'), null)
  assertEquals(mapStatus(''), null)
  assertEquals(mapStatus(null), null)
  assertEquals(mapStatus(undefined), null)
  assertEquals(mapStatus(42), null)
})

// ---------------------------------------------------------------------------
// Tipo opera
// ---------------------------------------------------------------------------
Deno.test('mapMediaType: i sei valori dell enum', () => {
  assertEquals(mapMediaType('TV'), 'TV')
  assertEquals(mapMediaType('Movie'), 'Movie')
  assertEquals(mapMediaType('OVA'), 'OVA')
  assertEquals(mapMediaType('ONA'), 'ONA')
  assertEquals(mapMediaType('Special'), 'Special')
  assertEquals(mapMediaType('Music'), 'Music')
})

Deno.test('mapMediaType: minuscolo accettato, sconosciuto ignorato', () => {
  assertEquals(mapMediaType('tv'), 'TV')
  assertEquals(mapMediaType('movie'), 'Movie')
  // Un tipo nuovo non si forza in un enum che lo rifiuterebbe.
  assertEquals(mapMediaType('Documentary'), null)
  assertEquals(mapMediaType(null), null)
})

// ---------------------------------------------------------------------------
// Date
// ---------------------------------------------------------------------------
Deno.test('toDate: tronca l orario ISO', () => {
  assertEquals(toDate('2023-07-08T00:00:00+00:00'), '2023-07-08')
  assertEquals(toDate('1999-10-20T16:00:00+09:00'), '1999-10-20')
  // Data gia' sola: non deve aggiungere niente.
  assertEquals(toDate('1988-07-16'), '1988-07-16')
})

Deno.test('toDate: valori non data danno null', () => {
  assertEquals(toDate(''), null)
  assertEquals(toDate(null), null)
  assertEquals(toDate(undefined), null)
  // Una data a meta' cammino non deve passare come valida.
  assertEquals(toDate('not-a-date'), null)
  assertEquals(toDate('2023-13-45'), null)
})

// ---------------------------------------------------------------------------
// Voto
// ---------------------------------------------------------------------------
Deno.test('toScore: arrotonda a una cifra come la colonna', () => {
  // numeric(3,1): 8.75 non ci sta, deve diventare 8.8 e non fallire.
  assertEquals(toScore(8.75), 8.8)
  assertEquals(toScore(9.1), 9.1)
  assertEquals(toScore(7), 7)
})

Deno.test('toScore: zero e valori non numerici danno null', () => {
  // Jikan usa 0 per "non votato": deve diventare NULL, non 0. Uno zero in
  // colonna farebbe comparire l'anime in "voto almeno 0", che e' tutti.
  assertEquals(toScore(0), null)
  assertEquals(toScore(null), null)
  assertEquals(toScore('9.1'), null)
  assertEquals(toScore(undefined), null)
})

// ---------------------------------------------------------------------------
// Freschezza della cache
// ---------------------------------------------------------------------------
Deno.test('isFresh: futuro è fresco, passato non lo è', () => {
  const domani = new Date(Date.now() + 86_400_000).toISOString()
  const ieri = new Date(Date.now() - 86_400_000).toISOString()

  assertEquals(isFresh(domani), true)
  assertEquals(isFresh(ieri), false)
})

Deno.test('isFresh: senza data è considerata non fresca', () => {
  // Meglio una chiamata a Jikan in piu' che mostrare dati di mesi fa come
  // se fossero aggiornati.
  assertEquals(isFresh(null), false)
  assertEquals(isFresh(undefined), false)
  assertEquals(isFresh(''), false)
  assertEquals(isFresh('non-una-data'), false)
})

// ---------------------------------------------------------------------------
// Mappatura completa
// ---------------------------------------------------------------------------
Deno.test('mapEntry: una voce Jikan completa viene mappata', () => {
  const entry = {
    mal_id: 16498,
    title: 'Attack on Titan',
    title_japanese: '進撃の巨人',
    synonyms: ['Shingeki no Kyojin'],
    synopsis: 'Un villaggio vive dietro un muro.',
    images: [{ large: 'https://img.test/large.jpg' }],
    trailers: [{ embed_url: 'https://youtube.test/embed/abc' }],
    episodes: 89,
    status: 'Finished Airing',
    year: 2013,
    duration: '24 min per ep',
    studios: [{ name: 'Wit Studio' }],
    genres: [{ name: 'Action' }, { name: 'Drama' }],
    demographics: [{ name: 'Shounen' }],
    type: 'TV',
    season: 'spring',
    aired: { from: '2013-04-07T00:00:00+00:00', to: '2023-11-04T00:00:00+00:00' },
    score: 9.1,
    scored_by: 1200000,
    members: 3000000,
  }

  const mapped = mapEntry(entry)

  assertNotEquals(mapped, null)
  if (!mapped) return

  assertEquals(mapped.external_id, '16498')
  assertEquals(mapped.external_source, 'mal')
  assertEquals(mapped.title, 'Attack on Titan')
  assertEquals(mapped.japanese_title, '進撃の巨人')
  assertEquals(mapped.synonyms, ['Shingeki no Kyojin'])
  assertEquals(mapped.genres, ['Action', 'Drama'])
  assertEquals(mapped.demographics, ['Shounen'])
  assertEquals(mapped.media_type, 'TV')
  assertEquals(mapped.season, 'spring')
  assertEquals(mapped.aired_from, '2013-04-07')
  assertEquals(mapped.aired_to, '2023-11-04')
  assertEquals(mapped.score, 9.1)
  assertEquals(mapped.studio, 'Wit Studio')
  assertEquals(mapped.image_url, 'https://img.test/large.jpg')
  assertEquals(mapped.trailer_url, 'https://youtube.test/embed/abc')
})

Deno.test('mapEntry: il record grezzo viene conservato', () => {
  // Se un campo di Jikan non e' nel mapping non deve perdersi: sta in
  // external_data e si recupera in seguito.
  const mapped = mapEntry({ mal_id: 1, title: 'X', campo_che_non_conosciamo: 'tesoro' })
  assertEquals(mapped?.external_data?.campo_che_non_conosciamo, 'tesoro')
})

Deno.test('mapEntry: una voce senza id o senza titolo viene scartata', () => {
  // Senza id la UNIQUE non distinguerebbe due righe; senza titolo il check
  // della tabella farebbe fallire l'upsert. In entrambi i casi scartare in
  // silenzio e' giusto: sono voci malformate, non un errore da segnalare.
  assertEquals(mapEntry({ title: 'Senza id' }), null)
  assertEquals(mapEntry({ mal_id: 5 }), null)
  assertEquals(mapEntry({ mal_id: 5, title: '   ' }), null)
  assertEquals(mapEntry({}), null)
})

Deno.test('mapEntry: immagini mancanti non rompono', () => {
  assertEquals(mapEntry({ mal_id: 1, title: 'X' })?.image_url, null)
  assertEquals(mapEntry({ mal_id: 1, title: 'X', images: [] })?.image_url, null)
  assertEquals(mapEntry({ mal_id: 1, title: 'X', images: [{}] })?.image_url, null)
})

Deno.test('mapEntry: fallback immagine quando manca large', () => {
  // Non tutte le voci hanno `large`: i film hanno immagini diverse.
  const mapped = mapEntry({
    mal_id: 1,
    title: 'X',
    images: [{ image_url: 'https://img.test/fallback.jpg' }],
  })
  assertEquals(mapped?.image_url, 'https://img.test/fallback.jpg')
})

Deno.test('mapEntry: studio assente dà null, non il produttore', () => {
  // Produttore e studio sono enti diversi: usare il produttore come fallback
  // metterebbe in colonna un dato sbagliato che sembra giusto.
  const mapped = mapEntry({
    mal_id: 1,
    title: 'X',
    studios: [],
    producers: [{ name: 'Produttore' }],
  })
  assertEquals(mapped?.studio, null)
})

Deno.test('mapEntry: anime in corso ha aired_to null', () => {
  // E' il caso normale, non un dato mancante.
  const mapped = mapEntry({
    mal_id: 1,
    title: 'One Piece',
    status: 'Currently Airing',
    aired: { from: '1999-10-20T00:00:00+00:00' },
  })
  assertEquals(mapped?.aired_from, '1999-10-20')
  assertEquals(mapped?.aired_to, null)
  assertEquals(mapped?.status, 'currently_airing')
})

Deno.test('mapEntry: la freshness viene calcolata con +7 giorni', () => {
  const mapped = mapEntry({ mal_id: 1, title: 'X' })
  const now = Date.parse(mapped?.external_fetched_at ?? '')
  const stale = Date.parse(mapped?.external_stale_at ?? '')

  assertEquals(isFresh(mapped?.external_stale_at), true)
  // Circa 7 giorni, con un margine per lo scorrere del test. Deve restare
  // allineato ad AppConfig.animeCacheDays: se i due divergono, il client e la
  // funzione non concordano su cosa sia "vecchio" e uno dei due rilegge Jikan a
  // ogni ricerca.
  const giorni = (stale - now) / 86_400_000
  if (giorni < 6.9 || giorni > 7.1) {
    throw new Error(`attesi ~7 giorni di freschezza, trovati ${giorni}`)
  }
})

// ---------------------------------------------------------------------------
// Rotta
// ---------------------------------------------------------------------------
// Il gateway chiama la radice della funzione: se la rotta fosse letta solo dal
// path, ogni chiamata dall'app finirebbe su "rotta sconosciuta" e la ricerca
// sarebbe rotta per sempre. Sono i due modi in cui si arriva davvero alla
// funzione, quindi vanno testati entrambi.
Deno.test('resolveRoute: la rotta arriva come parametro, non come path', () => {
  const url = new URL('https://x.supabase.co/functions/v1/jikan-proxy?route=/search&q=titan')
  assertEquals(resolveRoute(url), '/search')
})

Deno.test('resolveRoute: senza parametro la radice non e una rotta', () => {
  // La radice non e' nessuna rotta utile: rispondere "ok" qui nasconderebbe
  // una chiamata senza `route`, che e' sempre un bug lato client.
  const url = new URL('https://x.supabase.co/functions/v1/jikan-proxy')
  assertEquals(resolveRoute(url), '/functions/v1/jikan-proxy')
})

Deno.test('resolveRoute: il path diretto funziona per chi chiama a mano', () => {
  assertEquals(
    resolveRoute(new URL('https://x.supabase.co/functions/v1/jikan-proxy/search?q=x')),
    '/search',
  )
  assertEquals(resolveRoute(new URL('https://x.supabase.co/functions/v1/jikan-proxy/health')), '/health')
})

Deno.test('resolveRoute: un route inesistente non viene accettato', () => {
  // Accettare qualunque stringa farebbe cadere il controllo sui valori noti:
  // un parametro `route=/../admin` deve restare sconosciuto.
  assertEquals(
    resolveRoute(new URL('https://x.supabase.co/functions/v1/jikan-proxy?route=/admin')),
    '/functions/v1/jikan-proxy',
  )
})