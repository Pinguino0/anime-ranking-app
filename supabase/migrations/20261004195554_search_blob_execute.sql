-- ---------------------------------------------------------------------------
-- 20261004195554_search_blob_execute
--
-- Ripara l'upsert del catalogo dalla Edge Function.
--
-- Il sintomo: `jikan-proxy` rispondeva con risultati corretti ma sempre con
-- `id: null` e `in_catalog: false`, e la tabella `anime` restava con le sole
-- 16 righe del seed Jikan. Nei log della funzione:
--
--   jikan-proxy: scrittura cache fallita permission denied for function
--   anime_search_blob
--
-- La causa e' la 021, che revoca EXECUTE su `anime_search_blob` anche da
-- `service_role`. Il suo ragionamento era: "gli helper restano senza EXECUTE
-- per nessuno, le funzioni che li chiamano sono SECURITY DEFINER e girano come
-- postgres". E' vero per `anime_matches_filters`, `anime_title_similarity` ed
-- `escape_like`, che vengono chiamati dal corpo delle RPC.
--
-- Ma `anime_search_blob` e' anche il corpo della colonna generata:
--
--   search_blob text GENERATED ALWAYS AS
--     (anime_search_blob(title, japanese_title, synonyms,
--                         external_data ->> 'title')) STORED
--
-- E una colonna generata non e' una funzione: viene valutata durante
-- l'INSERT, con i permessi del ruolo che sta scrivendo, non del definer
-- della RPC che ha eventualmente aperto la transazione. Con
-- `service_role` privo di EXECUTE, ogni scrittura del catalogo finiva con
-- 403 prima ancora di arrivare ai vincoli di tabella.
--
-- Quindi la 021 aveva ragione sul principio (chi non scrive non deve
-- eseguire) e sbagliato la conclusione per questa funzione: l'unico ruolo
-- che scrive in `anime` e' `service_role`, che scavalca l'RLS di proposito
-- perche' e' la Edge Function a scrivere il catalogo. Le policy su `anime`
-- sono solo SELECT per `authenticated`: nessun utente puo' inserire.
--
-- Il grant e' a `service_role` e basta. Non a `anon`, non ad `authenticated`:
-- una funzione pura, IMMUTABLE e senza effetti collaterali che concatena
-- titoli non merita di essere eseguibile da chi non scrive la tabella.
-- ---------------------------------------------------------------------------

grant execute on function public.anime_search_blob(text, text, text[], text) to service_role;

comment on function public.anime_search_blob(text, text, text[], text) is
  'Titolo + titolo giapponese + titolo originale + sinonimi, uniti per la ricerca. Accetta NULL e restituisce testo vuoto se non c''e'' nulla. EXECUTE per service_role: e'' il corpo della colonna generata search_blob, valutata con i permessi del ruolo che scrive in anime.';