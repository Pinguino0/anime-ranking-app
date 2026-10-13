// ============================================================================
// animerank-relay - relay per i metadati di AnimeUnity
// ============================================================================
// Perche' esiste
// --------------
// Su alcune reti mobili italiane (es. WindTre su dati mobili) `animeunity.so`
// e' bloccato dall'operatore: il telefono non lo raggiunge piu'. Il flusso
// video invece arriva da una CDN diversa (`vix-content.net`) e NON e' bloccato,
// quindi l'unica cosa che serve e' risolvere i metadati da un altro punto.
//
// Un server "normale" (datacenter) non basta: Cloudflare risponde 403 alle
// richieste che arrivano da IP di datacenter. Questo Worker gira dentro la rete
// Cloudflare, che nella pratica non subisce lo stesso challenge. Da verificare.
//
// Rotte
// -----
//   GET /                 -> test di raggiungibilita'. Dice se Cloudflare
//                            accetta l'egress del Worker e restituisce un JSON.
//   GET /?u=<url>         -> proxy della richiesta verso un host in whitelist.
//
// Il Worker e' di proposito minimale: serve prima a capire se la strada e'
// percorribile. Solo dopo lo si trasforma nel resolver vero e proprio.

const ALLOWED_HOSTS = new Set(['www.animeunity.so', 'animeunity.so']);

const USER_AGENT =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const BLOCK_SIGNALS =
  /just a moment|access denied|attention required|enable javascript and cookies|restricted access/i;

function corsHeaders() {
  return {
    'access-control-allow-origin': '*',
    'access-control-expose-headers': '*',
    'cache-control': 'no-store',
  };
}

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const target = url.searchParams.get('u');

    // Test: il Worker prova a leggere la home di AnimeUnity e racconta com'e'
    // andata. Serve a decidere se la strada e' percorribile, senza toccare l'app.
    if (!target) {
      const upstream = await fetch('https://www.animeunity.so/', {
        headers: { 'user-agent': USER_AGENT, accept: 'text/html' },
        redirect: 'manual',
      });
      const text = await upstream.text();
      const blocked = BLOCK_SIGNALS.test(text) || !/animeunity/i.test(text);
      return Response.json(
        {
          ok: upstream.ok && !blocked,
          status: upstream.status,
          bytes: text.length,
          cloudflare_challenge: blocked,
          excerpt: text.slice(0, 200).replace(/\s+/g, ' '),
        },
        { headers: corsHeaders() },
      );
    }

    let targetUrl;
    try {
      targetUrl = new URL(target);
    } catch {
      return new Response('url non valido', { status: 400, headers: corsHeaders() });
    }
    if (!ALLOWED_HOSTS.has(targetUrl.hostname)) {
      return new Response('host non consentito', { status: 403, headers: corsHeaders() });
    }

    const headers = new Headers();
    headers.set('user-agent', USER_AGENT);
    headers.set('accept', request.headers.get('accept') || '*/*');
    for (const name of ['x-xsrf-token', 'referer', 'cookie', 'x-requested-with']) {
      const value = request.headers.get(name);
      if (value) headers.set(name, value);
    }

    const upstream = await fetch(targetUrl.toString(), {
      method: request.method,
      headers,
      redirect: 'manual',
    });

    const out = new Headers(corsHeaders());
    const setCookies = upstream.headers.getSetCookie ? upstream.headers.getSetCookie() : [];
    if (setCookies.length) out.set('x-set-cookie', JSON.stringify(setCookies));
    out.set('content-type', upstream.headers.get('content-type') || 'text/plain; charset=utf-8');

    return new Response(await upstream.arrayBuffer(), { status: upstream.status, headers: out });
  },
};
