-- ============================================================================
-- provider_hentaiworld - la fonte a contenuto per adulti
-- ============================================================================
--
-- HentaiWorld e' l'unica fonte del catalogo a contenuto per adulti, quindi non
-- condivide l'adapter con AnimeUnity/AnimeWorld (`native`): ha il suo
-- (`resolve_endpoint = 'hentaiworld'`, in `providers/hentaiworld.ts`). Cosi' si
-- puo' spegnere senza toccare le altre fonti — basta `is_active = false` su
-- questa riga — e un errore del suo extractor non si confonde con un errore di
-- AnimeUnity.
--
-- Priorita' 500: piu' alto = provato dopo. Non deve mai scalzare
-- AnimeUnity/AnimeWorld quando entrambi hanno l'episodio; interviene solo dove
-- gli altri non arrivano.
--
-- Questa riga da sola NON crea nessuna fonte: `episode_sources` resta vuota per
-- questo provider finche' non gira l'harvest che la popola. Finche' non ci sono
-- righe, la migrazione non cambia niente di visibile nell'app.
--
-- L'estrazione dell'adapter e' stata verificata sul sito reale (probe
-- `scraper/probe_hentaiworld.js` + risoluzione end-to-end): lo stream e' un mp4
-- scritto nella pagina. La riga qui sotto serve solo a registrare il provider.
-- ============================================================================

insert into public.providers (slug, label, resolve_endpoint, priority, is_active)
values ('hentaiworld', 'HentaiWorld (18+)', 'hentaiworld', 500, true)
on conflict (slug) do update
  set label            = excluded.label,
      resolve_endpoint = excluded.resolve_endpoint,
      priority         = excluded.priority;
