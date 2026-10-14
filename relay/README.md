# animerank-relay

Relay per i **metadati** di AnimeUnity, da mettere su un **Cloudflare Worker** (gratis).

## Perché

Su alcuni operatori mobili italiani (WindTre su dati mobili) `animeunity.so` è bloccato:
il telefono non riesce più a risolvere la fonte. Il flusso video invece arriva da
`vix-content.net`, che **non è bloccato**, quindi basta far risolvere i metadati da
un altro punto e il video continua ad andare diretto dal telefono.

I server "normali" (datacenter) vengono respinti da Cloudflare con **403**. Un Cloudflare
Worker gira *dentro* la rete Cloudflare, ma **AnimeUnity lo respinge lo stesso**: la rete
Cloudflare in cui gira un Worker gratuito è su ASN di datacenter, cioè gli stessi indirizzi
che AnimeUnity banna. Verificato: la radice, `/info_api/...` e `/embed-url/...` rispondono
`403` con il challenge (`Just a moment...`) o `error code 1005`.

Quindi questa strada, da sola, **non risolve** il blocco di AnimeUnity: serve un proxy
residenziale a pagamento oppure una VPN sul telefono. La strada che l'app usa davvero è il
bypass fatto **dal telefono** (DNS-over-HTTPS + IP reale di Cloudflare): lì la richiesta
parte dall'IP residenziale dell'utente, che Cloudflare non banna. Il Worker resta nel codice
per completezza: con un provider diverso può ancora essere la terza via.

## Come si mette online (5 minuti, nessun programma da installare)

1. Vai su <https://dash.cloudflare.com> e crea un account gratuito (serve solo un'email).
2. Nel menu a sinistra: **Workers & Pages** → **Create** → **Create Worker**.
3. Dagli un nome, es. `animerank-relay`, e premi **Deploy**.
4. Premi **Edit code**, cancella tutto e incolla il contenuto di `worker.js`.
5. Premi **Deploy**.
6. Copia l'indirizzo che ti mostra, tipo
   `https://animerank-relay.<qualcosa>.workers.dev`, e passalo a chi sviluppa l'app.

## Verifica

Apri l'indirizzo nel browser (basta la radice). Risponde un JSON:

```json
{ "ok": true, "status": 200, "bytes": 123456, "cloudflare_challenge": false, "excerpt": "<!DOCTYPE html>..." }
```

- `"ok": true` → il Worker raggiunge AnimeUnity: la strada è percorribile, si passa
  a collegarlo all'app.
- `"ok": false` con `"cloudflare_challenge": true` → Cloudflare blocca anche il Worker.
  È il caso di AnimeUnity con l'account gratuito: servirà un'altra strada (proxy
  residenziale a pagamento o VPN sul telefono).

## Rotte

| Rotta | Cosa fa |
|-------|---------|
| `GET /` | Test di raggiungibilità (il JSON qui sopra). |
| `GET /?u=<url>` | Proxy della richiesta verso un host in whitelist (`animeunity.so`). |
