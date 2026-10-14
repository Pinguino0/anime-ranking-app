// ============================================================================
// generic-api - test
// ============================================================================
//
// Cosa coprono
// -----------
// Il confine fra la risposta del provider esterno e l'URL che finisce nel
// player. E' il posto dove un errore si presenta come "questa fonte non
// parte" senza nessun altro sintomo: la risposta arriva, e' JSON, ma non
// nel formato che il resolver si aspetta e l'URL non viene mai estratto.
//
// Coperto:
//
//  - i formati di risposta accettati (sources, video, url piatto), perche'
//    sono il contratto vero con l'API esterna
//  - la costruzione della richiesta, perche' un {id} non sostituito o un
//    metodo diverso da quello configurato si presenta come 404 dal provider
//  - la risposta senza URL, che deve fallire in modo leggibile
//
// Il fetch viene stubbato: qui non si vuole una rete, si vuole verificare
// che la risposta venga letta bene. Il resolver reale e' provato end-to-end
// solo con una chiamata vera, perche' e' l'unico modo a sapere se il
// provider esterno ha cambiato forma.
// ============================================================================

import { genericApiResolver } from './generic-api.ts'
import type { ResolveRequest, SourceRow } from '../types.ts'

const UUID_OK = '3f8c1d2e-4a5b-4c6d-8e9f-0a1b2c3d4e5f'

const ENV_KEYS = [
  'GENERIC_PROVIDER_ENDPOINT',
  'GENERIC_PROVIDER_BASE_URL',
  'GENERIC_PROVIDER_PATH_TEMPLATE',
  'GENERIC_PROVIDER_METHOD',
  'GENERIC_PROVIDER_FORMAT',
  'GENERIC_PROVIDER_AUTH_HEADER',
] as const

function sourceFixture(overrides: Partial<SourceRow> = {}): SourceRow {
  return {
    id: UUID_OK,
    sourceUrl: null,
    canonicalUrl: 'https://animeworld.ac/watch/ep-1',
    sourceType: 'hls',
    quality: '1080p',
    language: 'sub',
    ...overrides,
  }
}

function requestFixture(source: SourceRow): ResolveRequest {
  return {
    source,
    canonicalUrl: source.canonicalUrl!,
    provider: { slug: 'mio_provider', label: 'Nome Provider', resolveEndpoint: 'generic_api' },
  }
}

/** Imposta le variabili d'ambiente del resolver, cancellandole alla fine. */
function withEnv(values: Record<string, string>, run: () => Promise<void>): Promise<void> {
  for (const key of ENV_KEYS) Deno.env.delete(key)
  for (const [key, value] of Object.entries(values)) Deno.env.set(key, value)

  return run().finally(() => {
    for (const key of ENV_KEYS) Deno.env.delete(key)
  })
}

type FetchCall = { url: string; init: RequestInit }

/** Sostituisce il fetch globale e restituisce le chiamate ricevute. */
function stubFetch(
  body: unknown,
  status = 200,
): { calls: FetchCall[]; restore: () => void } {
  const original = globalThis.fetch
  const calls: FetchCall[] = []

  globalThis.fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
    calls.push({ url: String(input), init: init ?? {} })
    return Promise.resolve(
      new Response(typeof body === 'string' ? body : JSON.stringify(body), {
        status,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
  }) as typeof fetch

  return { calls, restore: () => { globalThis.fetch = original } }
}

// ---------------------------------------------------------------------------
// Formati di risposta accettati
// ---------------------------------------------------------------------------

Deno.test('estrae l\'URL da { sources: [...] } e marca l\'m3u8 come hls', async () => {
  await withEnv({ GENERIC_PROVIDER_BASE_URL: 'https://api.example.com' }, async () => {
    const stub = stubFetch({
      sources: [
        { url: 'https://cdn.example.com/video.m3u8', isM3U8: true, headers: { Referer: 'https://animeworld.ac/' } },
        { url: 'https://cdn.example.com/fallback.mp4' },
      ],
    })

    try {
      const result = await genericApiResolver.resolve(requestFixture(sourceFixture()))

      // Prende la prima sorgente utilizzabile: e' la convenzione di Consumet
      // e di quasi tutti gli aggregator, dove la prima e' quella preferita.
      assertEquals(result.resolvedUrl, 'https://cdn.example.com/video.m3u8')
      assertEquals(result.sourceType, 'hls')
      assertEquals(result.headers['Referer'], 'https://animeworld.ac/')
    } finally {
      stub.restore()
    }
  })
})

Deno.test('estrae l\'URL da { video: { url } }', async () => {
  await withEnv({ GENERIC_PROVIDER_BASE_URL: 'https://api.example.com' }, async () => {
    const stub = stubFetch({ video: { url: 'https://cdn.example.com/ep1.mp4' } })

    try {
      const result = await genericApiResolver.resolve(
        requestFixture(sourceFixture({ sourceType: 'mp4' })),
      )

      assertEquals(result.resolvedUrl, 'https://cdn.example.com/ep1.mp4')
      assertEquals(result.sourceType, 'mp4')
    } finally {
      stub.restore()
    }
  })
})

Deno.test('estrae l\'URL da un campo piatto con sourceType ed expiresAt', async () => {
  await withEnv({ GENERIC_PROVIDER_BASE_URL: 'https://api.example.com' }, async () => {
    const stub = stubFetch({
      url: 'https://cdn.example.com/ep1.mp4',
      headers: { Referer: 'https://animeworld.ac/' },
      sourceType: 'mp4',
      expiresAt: '2026-10-06T16:00:00Z',
    })

    try {
      const result = await genericApiResolver.resolve(requestFixture(sourceFixture()))

      assertEquals(result.resolvedUrl, 'https://cdn.example.com/ep1.mp4')
      assertEquals(result.sourceType, 'mp4')
      assertEquals(result.expiresAt, '2026-10-06T16:00:00Z')
      assertEquals(result.headers['Referer'], 'https://animeworld.ac/')
    } finally {
      stub.restore()
    }
  })
})

Deno.test('una risposta senza URL nessuno fallisce con un errore leggibile', async () => {
  await withEnv({ GENERIC_PROVIDER_BASE_URL: 'https://api.example.com' }, async () => {
    const stub = stubFetch({ sources: [], message: 'nessun video' })

    try {
      let message = ''
      try {
        await genericApiResolver.resolve(requestFixture(sourceFixture()))
      } catch (error) {
        message = error instanceof Error ? error.message : String(error)
      }

      // Un JSON valido ma senza URL non deve diventare una 200 con
      // resolvedUrl vuoto: il client la rifiuterebbe lo stesso, ma senza
      // dire qual'e' stato il formato ricevuto.
      assert(message.includes('URL valido'), `messaggio inatteso: ${message}`)
    } finally {
      stub.restore()
    }
  })
})

Deno.test('una risposta che non e\' JSON fallisce', async () => {
  await withEnv({ GENERIC_PROVIDER_BASE_URL: 'https://api.example.com' }, async () => {
    const stub = stubFetch('<html>403 forbidden</html>')

    try {
      let message = ''
      try {
        await genericApiResolver.resolve(requestFixture(sourceFixture()))
      } catch (error) {
        message = error instanceof Error ? error.message : String(error)
      }

      assert(message.includes('non valida'), `messaggio inatteso: ${message}`)
    } finally {
      stub.restore()
    }
  })
})

Deno.test('una risposta 500 del provider non viene trattata come successo', async () => {
  await withEnv({ GENERIC_PROVIDER_BASE_URL: 'https://api.example.com' }, async () => {
    const stub = stubFetch({ error: 'boom' }, 500)

    try {
      let message = ''
      try {
        await genericApiResolver.resolve(requestFixture(sourceFixture()))
      } catch (error) {
        message = error instanceof Error ? error.message : String(error)
      }

      assert(message.includes('rifiutato'), `messaggio inatteso: ${message}`)
    } finally {
      stub.restore()
    }
  })
})

// ---------------------------------------------------------------------------
// Costruzione della richiesta
// ---------------------------------------------------------------------------

Deno.test('GET: il path template riceve l\'id estratto dal canonico', async () => {
  await withEnv(
    {
      GENERIC_PROVIDER_BASE_URL: 'https://api.example.com',
      GENERIC_PROVIDER_PATH_TEMPLATE: '/watch/{id}',
      GENERIC_PROVIDER_METHOD: 'GET',
    },
    async () => {
      const stub = stubFetch({ url: 'https://cdn.example.com/ep1.m3u8' })

      try {
        await genericApiResolver.resolve(
          requestFixture(sourceFixture({ canonicalUrl: 'https://animeworld.ac/watch/ep-1' })),
        )

        assertEquals(stub.calls.length, 1)
        const url = new URL(stub.calls[0].url)
        assertEquals(url.origin + url.pathname, 'https://api.example.com/watch/ep-1')
      } finally {
        stub.restore()
      }
    },
  )
})

Deno.test('GET: la richiesta e\' application/json e porta l\'id della fonte', async () => {
  await withEnv(
    {
      GENERIC_PROVIDER_BASE_URL: 'https://api.example.com',
      GENERIC_PROVIDER_PATH_TEMPLATE: '/watch/{id}',
      GENERIC_PROVIDER_METHOD: 'GET',
    },
    async () => {
      const stub = stubFetch({ url: 'https://cdn.example.com/ep1.m3u8' })

      try {
        await genericApiResolver.resolve(requestFixture(sourceFixture()))

        const headers = stub.calls[0].init.headers as Record<string, string>
        assertEquals(headers['Accept'], 'application/json')
        assertEquals(headers['X-Provider-Source'], UUID_OK)
        assertEquals(stub.calls[0].init.method, 'GET')
      } finally {
        stub.restore()
      }
    },
  )
})

Deno.test('POST: il body porta il canonico e i metadati della fonte', async () => {
  await withEnv(
    {
      GENERIC_PROVIDER_BASE_URL: 'https://api.example.com',
      GENERIC_PROVIDER_PATH_TEMPLATE: '/resolve',
      GENERIC_PROVIDER_METHOD: 'POST',
    },
    async () => {
      const stub = stubFetch({ url: 'https://cdn.example.com/ep1.mp4' })

      try {
        await genericApiResolver.resolve(requestFixture(sourceFixture()))

        const init = stub.calls[0].init
        assertEquals(init.method, 'POST')

        const payload = JSON.parse(String(init.body)) as Record<string, unknown>
        assertEquals(payload['sourceId'], UUID_OK)
        assertEquals(payload['canonicalUrl'], 'https://animeworld.ac/watch/ep-1')
        assertEquals(payload['sourceType'], 'hls')
        assertEquals(payload['quality'], '1080p')
        assertEquals(payload['language'], 'sub')
      } finally {
        stub.restore()
      }
    },
  )
})

Deno.test('POST: senza metadati anime il body non li porta', async () => {
  await withEnv(
    {
      GENERIC_PROVIDER_BASE_URL: 'https://api.example.com',
      GENERIC_PROVIDER_PATH_TEMPLATE: '/resolve',
      GENERIC_PROVIDER_METHOD: 'POST',
    },
    async () => {
      const stub = stubFetch({ url: 'https://cdn.example.com/ep1.mp4' })

      try {
        await genericApiResolver.resolve(requestFixture(sourceFixture()))

        const init = stub.calls[0].init
        const payload = JSON.parse(String(init.body)) as Record<string, unknown>
        assertEquals(payload['anime'], undefined)
      } finally {
        stub.restore()
      }
    },
  )
})

Deno.test('POST: il body porta i metadati anime per i provider di backup', async () => {
  await withEnv(
    {
      GENERIC_PROVIDER_BASE_URL: 'https://api.example.com',
      GENERIC_PROVIDER_PATH_TEMPLATE: '/resolve',
      GENERIC_PROVIDER_METHOD: 'POST',
    },
    async () => {
      const stub = stubFetch({ url: 'https://cdn.example.com/ep1.mp4' })

      try {
        const request = requestFixture(sourceFixture())
        request.anime = {
          episodeNumber: 1,
          title: 'Shingeki no Kyojin',
          japaneseTitle: '進撃の巨人',
          synonyms: ['Attack on Titan', "L'attacco dei Giganti"],
          malId: 16498,
          anilistId: 16498,
          titles: ['Shingeki no Kyojin', '進撃の巨人', 'Attack on Titan'],
          year: 2013,
        }
        await genericApiResolver.resolve(request)

        const init = stub.calls[0].init
        const payload = JSON.parse(String(init.body)) as Record<string, unknown>
        assertEquals(
          payload['anime'],
          {
            episodeNumber: 1,
            title: 'Shingeki no Kyojin',
            japaneseTitle: '進撃の巨人',
            synonyms: ['Attack on Titan', "L'attacco dei Giganti"],
            malId: 16498,
          },
        )
      } finally {
        stub.restore()
      }
    },
  )
})

Deno.test('GET: l\'URL porta numero episodio, titolo e mal_id', async () => {
  await withEnv(
    {
      GENERIC_PROVIDER_BASE_URL: 'https://api.example.com',
      GENERIC_PROVIDER_PATH_TEMPLATE: '/watch/{id}',
      GENERIC_PROVIDER_METHOD: 'GET',
    },
    async () => {
      const stub = stubFetch({ url: 'https://cdn.example.com/ep1.m3u8' })

      try {
        const request = requestFixture(sourceFixture())
        request.anime = {
          episodeNumber: 1,
          title: 'Shingeki no Kyojin',
          japaneseTitle: null,
          synonyms: ['Attack on Titan'],
          malId: 16498,
          anilistId: 16498,
          titles: ['Shingeki no Kyojin', 'Attack on Titan'],
          year: 2013,
        }
        await genericApiResolver.resolve(request)

        const url = new URL(stub.calls[0].url)
        assertEquals(url.searchParams.get('episode_number'), '1')
        assertEquals(url.searchParams.get('title'), 'Shingeki no Kyojin')
        assertEquals(url.searchParams.get('mal_id'), '16498')
      } finally {
        stub.restore()
      }
    },
  )
})

Deno.test('GENERIC_PROVIDER_ENDPOINT ha la precedenza su BASE_URL', async () => {
  await withEnv(
    {
      GENERIC_PROVIDER_ENDPOINT: 'https://direct.example.com/resolve?ep=7',
      GENERIC_PROVIDER_BASE_URL: 'https://api.example.com',
      GENERIC_PROVIDER_PATH_TEMPLATE: '/watch/{id}',
      GENERIC_PROVIDER_METHOD: 'GET',
    },
    async () => {
      const stub = stubFetch({ url: 'https://cdn.example.com/ep7.m3u8' })

      try {
        await genericApiResolver.resolve(requestFixture(sourceFixture()))

        // E' il caso che tiene in piedi il Passo 3: se questo env resta
        // impostato, BASE_URL e PATH_TEMPLATE vengono ignorati e il test
        // qui sotto e' l'unico posto che lo fa notare prima del telefono.
        assertEquals(new URL(stub.calls[0].url).origin, 'https://direct.example.com')
      } finally {
        stub.restore()
      }
    },
  )
})

Deno.test('senza nessuna configurazione il resolver dice cosa manca', async () => {
  await withEnv({}, async () => {
    let message = ''
    try {
      await genericApiResolver.resolve(requestFixture(sourceFixture()))
    } catch (error) {
      message = error instanceof Error ? error.message : String(error)
    }

    assert(message.includes('GENERIC_PROVIDER'), `messaggio inatteso: ${message}`)
  })
})

// ---------------------------------------------------------------------------
// Assert duplicati da `index.test.ts`: stesso motivo, nessun file condiviso.
// ---------------------------------------------------------------------------

function assert(condition: boolean, message = 'condizione non vera'): asserts condition {
  if (!condition) throw new Error(message)
}

function assertEquals<T>(actual: T, expected: T, message?: string): void {
  const a = JSON.stringify(actual)
  const b = JSON.stringify(expected)
  if (a === b) return

  throw new Error(message ?? `atteso ${b}, trovato ${a}`)
}
