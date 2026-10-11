-- ============================================================================
-- provider_route_tunnel - il provider torna a risolvere via extractor
-- ============================================================================
--
-- Contesto: la migration 20261008150000 ha spostato `mio_provider` sull'adapter
-- `native`, cioe' l'estrazione AnimeUnity/AnimeWorld dentro la Edge Function.
-- Il codice e' corretto e funziona da una connessione residenziale, ma
-- AnimeUnity (dietro Cloudflare) risponde 403 agli IP dei datacenter come quelli
-- di Supabase: le richieste della Edge Function vengono bloccate prima di
-- arrivare al contenuto.
--
-- Finche' non c'e' un egress con IP non datacenter (proxy residenziale) davanti
-- alla Edge Function, il provider usa `generic_api`, che inoltra all'extractor
-- in esecuzione sulla macchina dell'utente dietro un tunnel Cloudflare. Da li'
-- l'estrazione parte con l'IP di casa, che AnimeUnity accetta.
--
-- L'adapter `native` resta registrato nella funzione: quando ci sara' un
-- egress non bloccato bastera' rimettere `resolve_endpoint = 'native'`.
-- ============================================================================

update public.providers
set
  label = 'AnimeUnity / AnimeWorld (extractor)',
  resolve_endpoint = 'generic_api'
where slug = 'mio_provider';