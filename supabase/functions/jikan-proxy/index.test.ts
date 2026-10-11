// Test per jikan-proxy. Girano con: deno test -A
//
// Si testano solo le funzioni pure (la mappatura da AniList e da Kitsu, lo
// status, la data, lo score, la costruzione della query). Le funzioni che
// chiamano fetch o il database non si testano qui: farebbero richieste vere, e
// un test che chiama l'API esterna a ogni run fallisce quando l'esterno e'
// lento e non dice niente del codice locale.
//
// Test del resto (rate limit, cache, upsert) serve un ambiente con rete:
// si fa una volta a mano dopo il deploy, non a ogni build.

import {
  assertEquals,
  assertNotEquals,
} from 'jsr:@std/assert@^1'

import {
  anilistPagination,
  buildMediaArgs,
  currentSeason,
  fuzzyDateToIso,
  isFresh,
  isRecentAired,
  KITSU_TEXT_SEARCH_CAP,
  mapAnilistMedia,
  mapKitsuEntry,
  mapMediaType,
  mapStatus,
  previousSeason,
  resolveRoute,
  searchKitsu,
  seasonFromMonth,
  seasonKitsu,
  isCacheableFilter,
  stripHtml,
  toDate,
  toDuration,
  toScore,
  toScoreOutOfHundred,
} from './index.ts'

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------
Deno.test('mapStatus: i tre valori attesi, nei due vocabolari', () => {
  // AniList
  assertEquals(mapStatus('FINISHED'), 'finished_airing')
  assertEquals(mapStatus('RELEASING'), 'currently_airing')
  assertEquals(mapStatus('NOT_YET_RELEASED'), 'not_yet_aired')
  // Jikan: i dati gia' in catalogo vengono da li, e il seed li usa ancora.
  assertEquals(mapStatus('Finished Airing'), 'finished_airing')
  assertEquals(mapStatus('Currently Airing'), 'currently_airing')
  assertEquals(mapStatus('Not yet aired'), 'not_yet_aired')
  // Kitsu
  assertEquals(mapStatus('finished'), 'finished_airing')
  assertEquals(mapStatus('current'), 'currently_airing')
  assertEquals(mapStatus('not yet aired'), 'not_yet_aired')
})

Deno.test('mapStatus: spaziature e casi non rompono', () => {
  assertEquals(mapStatus('finished airing'), 'finished_airing')
  assertEquals(mapStatus('FINISHED_AIRING'), 'finished_airing')
  assertEquals(mapStatus('  Currently   Airing  '), 'currently_airing')
  assertEquals(mapStatus('Not Yet Released'), 'not_yet_aired')
})

Deno.test('mapStatus: un valore sconosciuto dà null, non una copia a caso', () => {
  // Il fallback silenzioso su un valore estraneo metterebbe in colonna uno
  // stato inesistente: l'enum lo rifiuterebbe e l'upsert fallirebbe.
  assertEquals(mapStatus('Hiatus'), null)
  assertEquals(mapStatus('Cancelled'), null)
  assertEquals(mapStatus('PAUSED'), null)
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

Deno.test('mapMediaType: TV_SPECIAL di AniList è Special', () => {
  // È la trappia del underscore: senza normalizzare, `TV_SPECIAL` diventava
  // `tv_special`, non trovava nessun caso e finiva in NULL. Il risultato era un
  // Special senza formato nella scheda, e il filtro per formato lo scartava.
  assertEquals(mapMediaType('TV_SPECIAL'), 'Special')
})

Deno.test('mapMediaType: minuscolo accettato, sconosciuto ignorato', () => {
  assertEquals(mapMediaType('tv'), 'TV')
  assertEquals(mapMediaType('movie'), 'Movie')
  // Un tipo nuovo non si forza in un enum che lo rifiuterebbe.
  assertEquals(mapMediaType('Documentary'), null)
  assertEquals(mapMediaType(null), null)
})

// ---------------------------------------------------------------------------
// Stagione
// ---------------------------------------------------------------------------
Deno.test('seasonFromMonth: le stagioni sono a cavallo d\'anno', () => {
  // Dicembre è inverno, non autunno: questo è il punto in cui una
  // normalizzazione ingenua sbaglia e mette la stagione sbagliata in colonna.
  assertEquals(seasonFromMonth(12), 'winter')
  assertEquals(seasonFromMonth(1), 'winter')
  assertEquals(seasonFromMonth(2), 'winter')
  assertEquals(seasonFromMonth(3), 'spring')
  assertEquals(seasonFromMonth(6), 'summer')
  assertEquals(seasonFromMonth(9), 'fall')
  assertEquals(seasonFromMonth(11), 'fall')
  assertEquals(seasonFromMonth(0), null)
  assertEquals(seasonFromMonth(13), null)
})

Deno.test('currentSeason: dicembre è l\'inverno dell\'anno dopo', () => {
  // "Winter 2027" comincia il 1 dicembre 2026, come la chiamano MyAnimeList e
  // AniList. Tornare all'anno corrente darebbe la stagione sbagliata per tre
  // mesi all'anno.
  const { season, year } = currentSeason(new Date('2026-12-15T00:00:00Z'))
  assertEquals(season, 'WINTER')
  assertEquals(year, 2027)
})

Deno.test('currentSeason: in primavera l\'anno è quello corrente', () => {
  const { season, year } = currentSeason(new Date('2026-04-02T00:00:00Z'))
  assertEquals(season, 'SPRING')
  assertEquals(year, 2026)
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

Deno.test('fuzzyDateToIso: serve anno, mese e giorno tutti e tre', () => {
  // Il punto della regola: AniList manda molte voci con il solo anno. Un
  // `2002-01-01` inventato finirebbe dentro "uscite negli ultimi 90 giorni"
  // con un falso positivo, quindi una data incompleta dà NULL.
  assertEquals(fuzzyDateToIso({ year: 2013, month: 4, day: 7 }), '2013-04-07')
  assertEquals(fuzzyDateToIso({ year: 2002 }), null)
  assertEquals(fuzzyDateToIso({ year: 2002, month: 10 }), null)
  assertEquals(fuzzyDateToIso({ year: null, month: 4, day: 7 }), null)
  assertEquals(fuzzyDateToIso(null), null)
  assertEquals(fuzzyDateToIso('2013-04-07'), null)
})

Deno.test('fuzzyDateToIso: mese e giorno fuori scala danno null', () => {
  // Un mese 13 o un giorno 45 non sono una data: passerebbero il controllo di
  // forma e finirebbero in colonna come date assurde.
  assertEquals(fuzzyDateToIso({ year: 2013, month: 13, day: 7 }), null)
  assertEquals(fuzzyDateToIso({ year: 2013, month: 4, day: 45 }), null)
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
  // I provider usano 0 per "non votato": deve diventare NULL, non 0. Uno zero
  // in colonna farebbe comparire l'anime in "voto almeno 0", che è tutti.
  assertEquals(toScore(0), null)
  assertEquals(toScore(null), null)
  assertEquals(toScore(undefined), null)
  assertEquals(toScore('nope'), null)
})

Deno.test('toScoreOutOfHundred: la scala 0-100 di AniList e Kitsu', () => {
  // averageScore 84 di AniList è un voto medio di 8.4, non di 84.
  assertEquals(toScoreOutOfHundred(84), 8.4)
  assertEquals(toScoreOutOfHundred(100), 10)
  // Kitsu manda i numeri come stringhe JSON.
  assertEquals(toScoreOutOfHundred('84.42'), 8.4)
  assertEquals(toScoreOutOfHundred(0), null)
  assertEquals(toScoreOutOfHundred(null), null)
})

// ---------------------------------------------------------------------------
// Testo e durata
// ---------------------------------------------------------------------------
Deno.test('stripHtml: le descrizioni di AniList arrivano con dentro i tag', () => {
  // `description(asHtml: false)` non ripulisce tutto: restano <br> e qualche
  // tag. La colonna è un testo che va a schermo.
  assertEquals(
    stripHtml('Un villaggio vive dietro un muro.<br><i>Meglio</i> cos&#236; &amp; co.'),
    'Un villaggio vive dietro un muro. Meglio così & co.',
  )
  assertEquals(stripHtml('   spazi   \n\n in eccesso  '), 'spazi in eccesso')
  assertEquals(stripHtml('<br>'), null)
  assertEquals(stripHtml(null), null)
})

Deno.test('stripHtml: un codice numerico assurdo non fa crashare', () => {
  // `String.fromCodePoint` lancia fuori dall'intervallo Unicode: una descrizione
  // malformata non deve far perdere tutta la pagina di risultati. Il codice
  // sparisce e gli spazi vengono normalizzati, quindi resta "testo qui".
  assertEquals(stripHtml('testo &#999999999; qui'), 'testo qui')
})

Deno.test('toDuration: i minuti diventano un testo con l\'unita\'', () => {
  // Un numero senza unità mostrato a schermo non vuol dire niente, e la
  // colonna è un text libero.
  assertEquals(toDuration(24), '24 min per ep')
  assertEquals(toDuration('24'), '24 min per ep')
  assertEquals(toDuration(0), null)
  assertEquals(toDuration(null), null)
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
  // Meglio una chiamata ai provider in più che mostrare dati di mesi fa come
  // se fossero aggiornati.
  assertEquals(isFresh(null), false)
  assertEquals(isFresh(undefined), false)
  assertEquals(isFresh(''), false)
  assertEquals(isFresh('non-una-data'), false)
})

// ---------------------------------------------------------------------------
// Costruzione della query AniList
// ---------------------------------------------------------------------------
// Il test più importante del file: protegge dalla trappia che ha fatto fallire
// la prima versione.
Deno.test('buildMediaArgs: nessun filtro non deve mandare filtri', () => {
  // AniList NON ignora una variabile null su `format` o `status`: la usa come
  // filtro e risponde zero righe senza errori. Per questo gli argomenti si
  // scrivono solo quando il filtro c'è. Se questo test comincia a fallire,
  // o la query manda `format: $format` con la variabile nulla, o AniList ha
  // cambiato comportamento.
  const args = buildMediaArgs({ filter: null })

  if (args.includes('format:')) {
    throw new Error(`la query manderebbe un filtro format senza filtro: ${args}`)
  }
  if (args.includes('status:')) {
    throw new Error(`la query manderebbe un filtro status senza filtro: ${args}`)
  }
  if (args.includes('sort:')) {
    throw new Error('la query ordinerebbe senza che nessuno lo abbia chiesto')
  }
  assertEquals(args.includes('type: ANIME'), true)
  assertEquals(args.includes('isAdult: false'), true)
  // `page` e `perPage` non devono MAI finire dentro `media(...)`: stanno su
  // `Page(...)`. Sbagliando posizione AniList risponde 400 "Unknown argument
  // \"page\" on field \"media\"" e la ricerca muore per ogni utente.
  assertEquals(args.includes('page:'), false)
  assertEquals(args.includes('perPage:'), false)
})

Deno.test('buildMediaArgs: un filtro noto diventa il suo letterale', () => {
  assertEquals(
    buildMediaArgs({ filter: 'tv' }).includes('format: TV'),
    true,
  )
  assertEquals(
    buildMediaArgs({ filter: 'special' }).includes('format: TV_SPECIAL'),
    true,
  )
  assertEquals(
    buildMediaArgs({ filter: 'airing' }).includes('status: RELEASING'),
    true,
  )
  assertEquals(
    buildMediaArgs({ filter: 'score' }).includes('sort: [SCORE_DESC]'),
    true,
  )
})

Deno.test('buildMediaArgs: la stagione viene scritta solo quando c\'è', () => {
  const conStagione = buildMediaArgs({
    filter: null,
    season: 'WINTER',
    seasonYear: 2027,
  })
  assertEquals(conStagione.includes('season: WINTER'), true)
  assertEquals(conStagione.includes('seasonYear: 2027'), true)

  // "recent" e "top" non filtrano per stagione: agganciarli alla stagione
  // corrente darebbe "le novità dell'anno scorso".
  const senza = buildMediaArgs({ filter: null, sort: 'SCORE_DESC' })
  assertEquals(senza.includes('season:'), false)
  assertEquals(senza.includes('seasonYear:'), false)
})

Deno.test('buildMediaArgs: seasonYear 0 non viene scritto', () => {
  // Il test distingue `!= null` da un controllo di verità: `0` è falsy ma
  // significherebbe "-nessun anno", non "anno zero".
  const args = buildMediaArgs({ filter: null, season: 'FALL', seasonYear: 0 })
  assertEquals(args.includes('seasonYear: 0'), true)
})

Deno.test('buildMediaArgs: startDate_greater viene scritto solo se c\'è', () => {
  const conSoglia = buildMediaArgs({ filter: null, startDateGreater: 1735689600 })
  assertEquals(conSoglia.includes('startDate_greater: 1735689600'), true)
  // Senza soglia l'argomento non deve comparire: su AniList è un filtro.
  assertEquals(buildMediaArgs({ filter: null }).includes('startDate_greater'), false)
})

// ---------------------------------------------------------------------------
// Paginazione
// ---------------------------------------------------------------------------

Deno.test('anilistPagination: il totale incoerente viene scartato', () => {
  // Sulla ricerca testuale AniList dà totali incoerenti: 4 alla pagina 1 e 5 alla
  // pagina 2 che non contiene nulla. Mostrare "4 risultati" mentre a schermo
  // ce ne sono 5 è peggio di non mostrare il totale.
  assertEquals(
    anilistPagination({ currentPage: 1, hasNextPage: true, total: 4 }, 5, 5).total,
    null,
  )
  // Un totale che non contraddice le righe mostrate viene tenuto.
  assertEquals(
    anilistPagination({ currentPage: 1, hasNextPage: true, total: 40 }, 5, 5).total,
    40,
  )
  // Oltre il tetto di 5000 il numero non è il vero totale.
  assertEquals(
    anilistPagination({ currentPage: 1, hasNextPage: true, total: 5000 }, 5, 5).total,
    null,
  )
  // `has_next` viene da hasNextPage, che è esatto, anche senza totale.
  assertEquals(anilistPagination({ currentPage: 1, hasNextPage: true }, 5, 5).has_next, true)
  assertEquals(anilistPagination({ currentPage: 2, hasNextPage: false }, 5, 5).has_next, false)
})

Deno.test('searchKitsu: oltre il tetto di 5 non si chiama proprio Kitsu', async () => {
  // `filter[text]` su Kitsu restituisce al massimo 5 voci e `page[offset]` non va
  // oltre: chiedere la seconda pagina restituirebbe le stesse cinque card e
  // l'infinite scroll girerebbe all'infinito. La seconda pagina si risponde a
  // mano, senza uscire, e la catena va oltre.
  const original = globalThis.fetch
  let calls = 0
  globalThis.fetch = (() => {
    calls++
    return Promise.reject(new Error('la seconda pagina non deve uscire'))
  }) as typeof globalThis.fetch
  try {
    const out = await searchKitsu('cowboy bebop', 5, 2, null)
    assertEquals(calls, 0)
    assertEquals(out.rows.length, 0)
    assertEquals(out.pagination?.has_next, false)
    assertEquals(out.pagination?.total, KITSU_TEXT_SEARCH_CAP)
  } finally {
    globalThis.fetch = original
  }
})

Deno.test('previousSeason: il capodanno non produce una stagione inesistente', () => {
  // L'inverno 2027 comincia a dicembre 2026. A gennaio 2027 la stagione
  // precedente è l'autunno 2026, non "inverno 2026": quell'inverno non è mai
  // esistito come stagione e AniList risponderebbe zero righe.
  assertEquals(previousSeason(new Date('2027-01-15T00:00:00Z')), { season: 'FALL', year: 2026 })
  assertEquals(previousSeason(new Date('2027-04-15T00:00:00Z')), { season: 'WINTER', year: 2027 })
  assertEquals(previousSeason(new Date('2026-10-15T00:00:00Z')), { season: 'SUMMER', year: 2026 })
  // Dicembre: la stagione corrente è già l'inverno dell'anno dopo.
  assertEquals(previousSeason(new Date('2026-12-20T00:00:00Z')), { season: 'FALL', year: 2026 })
})

Deno.test('isRecentAired: la finestra ha un limite anche in alto', () => {
  const today = new Date().toISOString().slice(0, 10)
  // Una data futura non è "uscita di recente": Kitsu mette 2029-12-31 sulle
  // schede senza data reale e quelle finivano in cima alla fascia.
  assertEquals(isRecentAired('2029-12-31'), false)
  assertEquals(isRecentAired('2030-01-01'), false)
  assertEquals(isRecentAired(today), true)
  // Niente data: la voce è finita, ma non si sa quando è uscita.
  assertEquals(isRecentAired(null), false)
  // Fuori dalla finestra in basso.
  assertEquals(isRecentAired('1999-01-01'), false)
})

Deno.test('searchKitsu: la pagina 1 chiede al massimo 5 righe', async () => {
  // Il client può chiederne 20: Kitsu sulla ricerca testuale ne dà 5, e chiederne
  // di più non aggiunge nulla ma fa sembrare che manchi qualcosa.
  const original = globalThis.fetch
  let seen = ''
  globalThis.fetch = ((input: string | URL | Request) => {
    seen = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
    return Promise.resolve(
      new Response(JSON.stringify({ data: [], meta: { count: 0 } }), {
        status: 200,
        headers: { 'content-type': 'application/vnd.api+json' },
      }),
    )
  }) as typeof globalThis.fetch
  try {
    await searchKitsu('berserk', 20, 1, null)
    assertEquals(new URL(seen).searchParams.get('page[limit]'), String(KITSU_TEXT_SEARCH_CAP))
  } finally {
    globalThis.fetch = original
  }
})

Deno.test('seasonKitsu: nessuna rotta chiede una pagina sopra il tetto di 20', async () => {
  // Il bug: per "recent" si chiedeva `page[limit] = limit * 3`, cioe' 60 righe
  // con un limite di 25. Kitsu risponde 400 "Limit exceeds maximum page size
  // of 20" e la fascia recenti cadeva del tutto.
  const original = globalThis.fetch
  const limits: (string | null)[] = []
  globalThis.fetch = ((input: string | URL | Request) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
    limits.push(new URL(url).searchParams.get('page[limit]'))
    return Promise.resolve(
      new Response(JSON.stringify({ data: [], meta: { count: 0 } }), {
        status: 200,
        headers: { 'content-type': 'application/vnd.api+json' },
      }),
    )
  }) as typeof globalThis.fetch
  try {
    for (const kind of ['now', 'top', 'recent'] as const) {
      await seasonKitsu(kind, 25)
    }
    assertEquals(limits.length, 3)
    for (const value of limits) assertEquals(Number(value), 20)
  } finally {
    globalThis.fetch = original
  }
})

Deno.test('seasonKitsu: "recent" scarta le date future e non sfoglia all\'infinito', async () => {
  // `sort=-start_date` mette in cima il futuro: le prime pagine sono tutte
  // annunci del 2027 e segnaposto al 2026-12-31, che la finestra "uscite di
  // recente" non puo' contenere. Sfogliare non aiuta (le pagine dopo sono
  // ancora piu' nel futuro) e costerebbe richieste a vuoto: si risponde giu' e
  // la fascia resta vuota, che e' la risposta onesta.
  const original = globalThis.fetch
  let calls = 0
  globalThis.fetch = (() => {
    calls += 1
    const data = Array.from({ length: 20 }, (_unused, i) => ({
      id: String(2000 + calls * 100 + i),
      type: 'anime',
      attributes: {
        canonicalTitle: `Annuncio ${i}`,
        titles: { en: `Annuncio ${i}`, en_jp: null, ja_jp: null },
        episodeCount: 12,
        status: 'not yet aired',
        season: null,
        seasonYear: null,
        // Il futuro che Kitsu mette davvero in cima all'ordinamento.
        startDate: '2027-01-15',
        endDate: null,
        synopsis: null,
        posterImage: null,
        subtype: 'TV',
        showType: 'TV',
        averageRating: null,
        popularityCount: 0,
        episodeLength: 24,
        ageRating: 'PG',
        nsfw: false,
      },
      relationships: { genres: { data: [] } },
    }))
    return Promise.resolve(
      new Response(JSON.stringify({ data, meta: { count: 22490 } }), {
        status: 200,
        headers: { 'content-type': 'application/vnd.api+json' },
      }),
    )
  }) as typeof globalThis.fetch
  try {
    const out = await seasonKitsu('recent', 20)
    assertEquals(out.rows.length, 0)
    // Una sola richiesta: niente paging a vuoto nel futuro.
    assertEquals(calls, 1)
    // Le voci sono arrivate ma nessuna e' uscita di recente: `rawCount` distingue
    // il vuoto reale dal "non ho saputo leggere", cosi' la catena puo' passare
    // al provider dopo senza dirgli che il catalogo e' vuoto.
    assertEquals(out.rawCount, 20)
  } finally {
    globalThis.fetch = original
  }
})

Deno.test('seasonKitsu: "recent" tiene le opere davvero dentro la finestra', async () => {
  const today = new Date().toISOString().slice(0, 10)
  const original = globalThis.fetch
globalThis.fetch = (() => {
    const data = [
      { id: '3001', title: 'Appena uscito', start: today, status: 'finished' },
      { id: '3002', title: 'Ancongo avanti', start: '1999-10-20', status: 'finished' },
      { id: '3003', title: 'Non ancora uscito', start: '2027-01-15', status: 'not yet aired' },
    ].map((entry) => ({
      id: entry.id,
      type: 'anime',
      attributes: {
        canonicalTitle: entry.title,
        titles: { en: entry.title, en_jp: null, ja_jp: null },
        episodeCount: 12,
        status: entry.status,
        season: null,
        seasonYear: null,
        startDate: entry.start,
        endDate: null,
        synopsis: null,
        posterImage: null,
        subtype: 'TV',
        showType: 'TV',
        averageRating: null,
        popularityCount: 0,
        episodeLength: 24,
        ageRating: 'PG',
        nsfw: false,
      },
      relationships: { genres: { data: [] } },
    }))
    return Promise.resolve(
      new Response(JSON.stringify({ data, meta: { count: 3 } }), {
        status: 200,
        headers: { 'content-type': 'application/vnd.api+json' },
      }),
    )
  }) as typeof globalThis.fetch
  try {
    const out = await seasonKitsu('recent', 5)
    assertEquals(out.rows.length, 1)
    assertEquals(out.rows[0].external_id, '3001')
    assertEquals(out.rows[0].title, 'Appena uscito')
  } finally {
    globalThis.fetch = original
  }
})

Deno.test('isCacheableFilter: i tipi si rispondono dal catalogo, gli ordinamenti no', () => {
  // tv/movie/ova/special sono anche valori dell'enum anime_type: la RPC sa
  // filtrarli e la cache puo' rispondere.
  assertEquals(isCacheableFilter(null), true)
  assertEquals(isCacheableFilter('tv'), true)
  assertEquals(isCacheableFilter('movie'), true)
  assertEquals(isCacheableFilter('ova'), true)
  assertEquals(isCacheableFilter('special'), true)
  // airing/upcoming/by_popularity/favorite/score non hanno una colonna: se la
  // cache rispondesse, "airing" mostrerebbe anche opere finite e "score"
  // risponderebbe nell'ordine di prima instead che per voto.
  assertEquals(isCacheableFilter('airing'), false)
  assertEquals(isCacheableFilter('upcoming'), false)
  assertEquals(isCacheableFilter('by_popularity'), false)
  assertEquals(isCacheableFilter('favorite'), false)
  assertEquals(isCacheableFilter('score'), false)
  // Un filtro inesistente viene gia' scartato a monte come null.
  assertEquals(isCacheableFilter('sfw'), false)
})

// ---------------------------------------------------------------------------
// Mappatura AniList
// ---------------------------------------------------------------------------
const ANILIST_TITAN = {
  id: 16498,
  idMal: 16498,
  title: { romaji: 'Shingeki no Kyojin', english: 'Attack on Titan', native: '進撃の巨人' },
  synonyms: ['Shingeki no Kyojin', 'Attack on Titan'],
  description: 'Un villaggio vive dietro un muro.<br>Finche&#039; qualcuno non fora.',
  format: 'TV',
  status: 'FINISHED',
  episodes: 89,
  duration: 24,
  season: 'SPRING',
  seasonYear: 2013,
  averageScore: 84,
  popularity: 3_000_000,
  favourites: 90_000,
  isAdult: false,
  genres: ['Action', 'Drama', 'Fantasy'],
  countryOfOrigin: 'JP',
  startDate: { year: 2013, month: 4, day: 7 },
  endDate: { year: 2023, month: 11, day: 4 },
  coverImage: {
    large: 'https://img.test/large.jpg',
    extraLarge: 'https://img.test/extra.jpg',
    color: '#000',
  },
  trailer: { site: 'youtube', id: 'abc', thumbnail: 'https://img.test/t.jpg' },
  studios: { nodes: [{ name: 'Wit Studio' }] },
}

Deno.test('mapAnilistMedia: una voce completa viene mappata', () => {
  const mapped = mapAnilistMedia(ANILIST_TITAN)

  assertNotEquals(mapped, null)
  if (!mapped) return

  assertEquals(mapped.external_id, '16498')
  assertEquals(mapped.external_source, 'anilist')
  assertEquals(mapped.title, 'Shingeki no Kyojin')
  assertEquals(mapped.japanese_title, '進撃の巨人')
  assertEquals(mapped.media_type, 'TV')
  assertEquals(mapped.status, 'finished_airing')
  assertEquals(mapped.season, 'spring')
  assertEquals(mapped.year, 2013)
  assertEquals(mapped.aired_from, '2013-04-07')
  assertEquals(mapped.aired_to, '2023-11-04')
  // 84 su 100 è un voto medio di 8.4: metterlo 84 farebbe fallire il cast
  // della colonna numeric(3,1).
  assertEquals(mapped.score, 8.4)
  assertEquals(mapped.popularity, 3_000_000)
  assertEquals(mapped.duration, '24 min per ep')
  assertEquals(mapped.studio, 'Wit Studio')
  assertEquals(mapped.genres, ['Action', 'Drama', 'Fantasy'])
  assertEquals(mapped.image_url, 'https://img.test/large.jpg')
  assertEquals(mapped.trailer_url, 'https://www.youtube.com/embed/abc')
  assertEquals(mapped.synopsis, "Un villaggio vive dietro un muro. Finche' qualcuno non fora.")
})

Deno.test('mapAnilistMedia: il titolo inglese finisce nei sinonimi', () => {
  // `search_blob` include i sinonimi: senza questo, cercare "Attack on Titan"
  // nel catalogo locale non troverebbe niente perche' il titolo e' in romaji.
  const mapped = mapAnilistMedia(ANILIST_TITAN)
  const synonyms = mapped?.synonyms ?? []

  assertEquals(synonyms.includes('Attack on Titan'), true)
  // Il titolo principale non deve ripetersi nei sinonimi.
  assertEquals(synonyms.includes('Shingeki no Kyojin'), false)
  // E non deve neppure il titolo inglese ripetersi due volte.
  assertEquals(new Set(synonyms).size, synonyms.length)
})

Deno.test('mapAnilistMedia: scored_by resta null', () => {
  // AniList non dice quanti utenti abbiano votato, dice quanti ce l'hanno in
  // lista. Riempirlo con `popularity` direbbe "votato da 3 milioni di utenti",
  // che è falso: la UI mostra quel numero come numero di voti.
  const mapped = mapAnilistMedia(ANILIST_TITAN)
  assertEquals(mapped?.scored_by, null)
  assertEquals(mapped?.popularity, 3_000_000)
})

Deno.test('mapAnilistMedia: il record grezzo viene conservato', () => {
  // Se un campo di AniList non è nel mapping non deve perdersi: sta in
  // external_data e si recupera in seguito. `idMal` in particolare è il
  // collegamento con MyAnimeList e resta disponibile per il futuro.
  const mapped = mapAnilistMedia({ id: 1, title: { romaji: 'X' }, campo_che_non_conosciamo: 'tesoro' })
  assertEquals(mapped?.external_data?.campo_che_non_conosciamo, 'tesoro')

  const withMal = mapAnilistMedia(ANILIST_TITAN)
  assertEquals(withMal?.external_data?.idMal, 16498)
  // Il collegamento con MyAnimeList resta in `external_data` e non diventa
  // `external_id`: la riga e' identificata da AniList, che è la fonte da cui
  // è stata presa.
  assertEquals(withMal?.external_id, '16498')
  assertEquals(withMal?.external_source, 'anilist')
})

Deno.test('mapAnilistMedia: una voce senza id o senza titolo viene scartata', () => {
  // Senza id la UNIQUE non distinguerebbe due righe; senza titolo il check
  // della tabella farebbe fallire l'upsert. In entrambi i casi scartare in
  // silenzio è giusto: sono voci malformate, non un errore da segnalare.
  assertEquals(mapAnilistMedia({ title: { romaji: 'Senza id' } }), null)
  assertEquals(mapAnilistMedia({ id: 5, title: {} }), null)
  assertEquals(mapAnilistMedia({ id: 5, title: { romaji: '   ' } }), null)
  assertEquals(mapAnilistMedia({}), null)
  assertEquals(mapAnilistMedia(null), null)
})

Deno.test('mapAnilistMedia: immagini mancanti non rompono', () => {
  assertEquals(mapAnilistMedia({ id: 1, title: { romaji: 'X' } })?.image_url, null)
  assertEquals(mapAnilistMedia({ id: 1, title: { romaji: 'X' }, coverImage: {} })?.image_url, null)
  assertEquals(mapAnilistMedia({ id: 1, title: { romaji: 'X' }, coverImage: null })?.image_url, null)
})

Deno.test('mapAnilistMedia: caduta su extraLarge quando large manca', () => {
  const mapped = mapAnilistMedia({
    id: 1,
    title: { romaji: 'X' },
    coverImage: { extraLarge: 'https://img.test/extra.jpg' },
  })
  assertEquals(mapped?.image_url, 'https://img.test/extra.jpg')
})

Deno.test('mapAnilistMedia: un trailer non-YouTube viene ignorato', () => {
  // L'app non sa riprodurre Dailymotion: mandare il link aprirebbe un browser
  // esterno da una scheda che dovrebbe suonare il trailer lì.
  const mapped = mapAnilistMedia({
    id: 1,
    title: { romaji: 'X' },
    trailer: { site: 'dailymotion', id: 'abc' },
  })
  assertEquals(mapped?.trailer_url, null)
  assertEquals(
    mapAnilistMedia({ id: 1, title: { romaji: 'X' }, trailer: { site: 'youtube' } })?.trailer_url,
    null,
  )
})

Deno.test('mapAnilistMedia: studio assente dà null', () => {
  // Non si usa un altro campo come ripiego: meglio nessuno studio che uno
  // sbagliato che sembra giusto.
  assertEquals(mapAnilistMedia({ id: 1, title: { romaji: 'X' }, studios: { nodes: [] } })?.studio, null)
  assertEquals(mapAnilistMedia({ id: 1, title: { romaji: 'X' } })?.studio, null)
})

Deno.test('mapAnilistMedia: la freschezza viene calcolata con +7 giorni', () => {
  const mapped = mapAnilistMedia({ id: 1, title: { romaji: 'X' } })
  const now = Date.parse(mapped?.external_fetched_at ?? '')
  const stale = Date.parse(mapped?.external_stale_at ?? '')

  assertEquals(isFresh(mapped?.external_stale_at), true)
  // Circa 7 giorni, con un margine per lo scorrere del test. Deve restare
  // allineato ad AppConfig.animeCacheDays: se i due divergono, il client e la
  // funzione non concordano su cosa sia "vecchio" e uno dei due rilegge il
  // provider a ogni ricerca.
  const giorni = (stale - now) / 86_400_000
  if (giorni < 6.9 || giorni > 7.1) {
    throw new Error(`attesi ~7 giorni di freschezza, trovati ${giorni}`)
  }
})

Deno.test('mapAnilistMedia: un anime in corso ha aired_to null', () => {
  // È il caso normale, non un dato mancante.
  const mapped = mapAnilistMedia({
    id: 21,
    title: { romaji: 'One Piece' },
    status: 'RELEASING',
    startDate: { year: 1999, month: 10, day: 20 },
  })
  assertEquals(mapped?.aired_from, '1999-10-20')
  assertEquals(mapped?.aired_to, null)
  assertEquals(mapped?.status, 'currently_airing')
})

// ---------------------------------------------------------------------------
// Mappatura Kitsu
// ---------------------------------------------------------------------------
// `included` di Kitsu: i nomi stanno separati dagli id che stanno in
// `relationships`. Questa mappa e' quello che la funzione costruisce.
const KITSU_NAMES = new Map<string, string>([
  ['1', 'Action'],
  ['4', 'Drama'],
  ['11', 'Fantasy'],
  ['23', 'Super Power'],
])

const KITSU_TITAN = {
  id: '7442',
  type: 'anime',
  attributes: {
    canonicalTitle: 'Attack on Titan',
    titles: { en: 'Attack on Titan', en_jp: 'Shingeki no Kyojin', ja_jp: '進撃の巨人' },
    episodeCount: 25,
    status: 'finished',
    // season e seasonYear vuoti su Kitsu: la stagione va derivata dalla data.
    season: null,
    seasonYear: null,
    startDate: '2013-04-07',
    endDate: null,
    synopsis: 'Un villaggio vive dietro un muro.<br>Finche&#039; qualcuno non fora.',
    posterImage: {
      small: 'https://img.test/s.jpg',
      medium: 'https://img.test/m.jpg',
      large: 'https://img.test/l.jpg',
      original: 'https://img.test/o.jpg',
    },
    subtype: 'TV',
    showType: 'TV',
    averageRating: '84.42',
    popularityCount: 250000,
    episodeLength: 24,
    ageRating: 'R',
    nsfw: false,
    youtubeVideoId: 'LHtdKWJdif4',
  },
  relationships: {
    genres: { data: [{ id: '1' }, { id: '4' }, { id: '11' }] },
  },
}

Deno.test('mapKitsuEntry: una voce completa viene mappata', () => {
  const mapped = mapKitsuEntry(KITSU_TITAN, KITSU_NAMES)

  assertNotEquals(mapped, null)
  if (!mapped) return

  assertEquals(mapped.external_id, '7442')
  assertEquals(mapped.external_source, 'kitsu')
  assertEquals(mapped.title, 'Attack on Titan')
  assertEquals(mapped.japanese_title, '進撃の巨人')
  assertEquals(mapped.episodes, 25)
  assertEquals(mapped.status, 'finished_airing')
  assertEquals(mapped.media_type, 'TV')
  assertEquals(mapped.aired_from, '2013-04-07')
  assertEquals(mapped.score, 8.4)
  assertEquals(mapped.popularity, 250000)
  assertEquals(mapped.duration, '24 min per ep')
  assertEquals(mapped.image_url, 'https://img.test/l.jpg')
  assertEquals(mapped.trailer_url, 'https://www.youtube.com/embed/LHtdKWJdif4')
  // I generi arrivano come id e vanno incrociati con `included`.
  assertEquals(mapped.genres, ['Action', 'Drama', 'Fantasy'])
  assertEquals(mapped.synopsis, "Un villaggio vive dietro un muro. Finche' qualcuno non fora.")
})

Deno.test('mapKitsuEntry: la stagione si ricava dalla data', () => {
  // Kitsu lascia season e seasonYear vuoti su quasi tutto il catalogo storico.
  // Senza ricavarli dalla data, `season` resterebbe NULL e il filtro per
  // stagione scarterebbe l'intero catalogo vecchio.
  const mapped = mapKitsuEntry(KITSU_TITAN, KITSU_NAMES)
  assertEquals(mapped?.season, 'spring')
  assertEquals(mapped?.year, 2013)
})

Deno.test('mapKitsuEntry: dicembre deriva winter, non fall', () => {
  const mapped = mapKitsuEntry(
    { id: '1', attributes: { canonicalTitle: 'X', startDate: '2021-12-01' } },
    KITSU_NAMES,
  )
  assertEquals(mapped?.season, 'winter')
})

Deno.test('mapKitsuEntry: senza data la stagione resta null', () => {
  // Meglio nessuna stagione che una sbagliata: il filtro la scarterebbe
  // comunque, ma la scheda mostrerebbe un dato inventato.
  const mapped = mapKitsuEntry({ id: '1', attributes: { canonicalTitle: 'X' } }, KITSU_NAMES)
  assertEquals(mapped?.season, null)
  assertEquals(mapped?.year, null)
})

Deno.test('mapKitsuEntry: i titoli alternativi finiscono nei sinonimi', () => {
  const mapped = mapKitsuEntry(KITSU_TITAN, KITSU_NAMES)
  const synonyms = mapped?.synonyms ?? []

  assertEquals(synonyms.includes('Shingeki no Kyojin'), true)
  assertEquals(synonyms.includes('Attack on Titan'), false)
  assertEquals(new Set(synonyms).size, synonyms.length)
})

Deno.test('mapKitsuEntry: lo studio resta null', () => {
  // Kitsu non espone gli studi come relazione dell'anime e i produttori sono
  // un ente diverso: metterli sarebbe un dato sbagliato che sembra giusto.
  const mapped = mapKitsuEntry(KITSU_TITAN, KITSU_NAMES)
  assertEquals(mapped?.studio, null)
})

Deno.test('mapKitsuEntry: una voce senza id o senza titolo viene scartata', () => {
  assertEquals(mapKitsuEntry({ attributes: { canonicalTitle: 'Senza id' } }, KITSU_NAMES), null)
  assertEquals(mapKitsuEntry({ id: '1', attributes: {} }, KITSU_NAMES), null)
  assertEquals(mapKitsuEntry(null, KITSU_NAMES), null)
})

Deno.test('mapKitsuEntry: immagini mancanti non rompono', () => {
  const mapped = mapKitsuEntry(
    { id: '1', attributes: { canonicalTitle: 'X', posterImage: {} } },
    KITSU_NAMES,
  )
  assertEquals(mapped?.image_url, null)
  assertEquals(mapKitsuEntry({ id: '1', attributes: { canonicalTitle: 'X' } }, KITSU_NAMES)?.image_url, null)
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