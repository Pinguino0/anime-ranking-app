-- ============================================================================
-- provider_native - il provider del catalogo risolve dentro la Edge Function
-- ============================================================================
--
-- Il provider `mio_provider` puntava a `generic_api`, cioe' a un endpoint HTTP
-- esterno (un tunnel Cloudflare effimero). Il tunnel cambia URL a ogni riavvio
-- e, quando muore, ogni risoluzione risponde 500 perche' l'host non esiste piu'.
--
-- Le fonti del catalogo sono quasi tutte AnimeUnity: la loro estrazione e' pura
-- `fetch` + regex e vive ora dentro `resolve-source`
-- (`providers/native.ts`). Questa migrazione sposta il provider su quell'adapter,
-- togliendo di mezzo la dipendenza dal tunnel.
--
-- `generic_api` resta registrato nella funzione per qualunque provider futuro
-- che voglia davvero parlare con un servizio esterno, ma nessuna riga di
-- `providers` lo usa piu'.
-- ============================================================================

update public.providers
set
  label = 'AnimeUnity / AnimeWorld',
  resolve_endpoint = 'native'
where slug = 'mio_provider';