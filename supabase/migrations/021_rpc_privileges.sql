-- ---------------------------------------------------------------------------
-- 021_rpc_privileges
--
-- Chiude a `anon` le RPC create dalla 019 e dalla 020.
--
-- Perche' serve una migration dedicata: la 019 e la 020 revocano gia' da
-- PUBLIC, ma non da `anon`, e non basta. Supabase imposta dei default
-- privileges sullo schema public che danno EXECUTE ad anon sulle funzioni
-- nuove come grant DIRETTO al ruolo:
--
--   alter default privileges in schema public grant execute on functions to ...
--
-- Quel grant e' indipendente da PUBLIC, quindi `revoke ... from public`
-- toglie solo la meta' del permesso e anon continua a poter eseguire tutto.
-- check_privileges.ps1 lo segnalava su 13 funzioni.
--
-- Le funzioni della 001-018 non risultavano aperte perche' sono state create
-- prima che quei default privileges venissero applicati al progetto: da li' in
-- poi il revoke da PUBLIC basta. Il bug e' quindi silenzioso e compare solo con
-- le funzioni nuove.
--
-- Perche' non e' un'emergenza: le tre RPC degli inviti chiamano is_group_admin,
-- che per un anon senza sessione(auth.uid() e' null) restituisce false, quindi
-- un anon che le invoca riceve "non autorizzato" e non vede nulla. Ma e' una
-- superficie che non serve tenere aperta, e le RPC del catalogo resterebbero
-- enumerabili da chi ha solo la chiave pubblica.
--
-- Gli helper restano senza EXECUTE per nessuno: le funzioni che li chiamano
-- sono SECURITY DEFINER e girano come postgres, che come proprietario mantiene
-- il permesso implicito. Revocare a anon/authenticated/service_role non le
-- rompe: non e' il chiamante a essere autorizzato, ma il proprietario.
-- ---------------------------------------------------------------------------

-- Chiude tutto: sia PUBLIC sia il grant diretto ad anon.
revoke all on function public.anime_search(text, text[], public.anime_type, public.anime_season,
  public.anime_status, integer, integer, numeric, integer, integer, text, integer, integer) from anon, public;
revoke all on function public.anime_search_count(text, text[], public.anime_type, public.anime_season,
  public.anime_status, integer, integer, numeric, integer, integer) from anon, public;
revoke all on function public.anime_current_season(integer, integer, text) from anon, public;
revoke all on function public.anime_genres() from anon, public;
revoke all on function public.anime_catalog_stats() from anon, public;
revoke all on function public.create_group_invite(uuid, integer) from anon, public;
revoke all on function public.list_group_invites(uuid) from anon, public;
revoke all on function public.revoke_group_invite(uuid) from anon, public;

-- Helper: nessun ruolo eseguibile. Le due funzioni in coda non erano nel revoke
-- della 019 perche' sono state create dopo quella sezione di privilegi.
revoke all on function public.anime_matches_filters(public.anime, text[], public.anime_type,
  public.anime_season, public.anime_status, integer, integer, numeric, integer, integer)
  from anon, authenticated, service_role, public;
revoke all on function public.anime_title_similarity(text, text)
  from anon, authenticated, service_role, public;
revoke all on function public.escape_like(text)
  from anon, authenticated, service_role, public;
revoke all on function public.anime_search_blob(text, text, text[], text)
  from anon, authenticated, service_role, public;
revoke all on function public.current_season(date)
  from anon, authenticated, service_role, public;

-- Le RPC che il client chiama con la sessione utente.
grant execute on function public.anime_search(text, text[], public.anime_type, public.anime_season,
  public.anime_status, integer, integer, numeric, integer, integer, text, integer, integer) to authenticated;
grant execute on function public.anime_search_count(text, text[], public.anime_type, public.anime_season,
  public.anime_status, integer, integer, numeric, integer, integer) to authenticated;
grant execute on function public.anime_current_season(integer, integer, text) to authenticated;
grant execute on function public.anime_genres() to authenticated;
grant execute on function public.anime_catalog_stats() to authenticated;
grant execute on function public.create_group_invite(uuid, integer) to authenticated;
grant execute on function public.list_group_invites(uuid) to authenticated;
grant execute on function public.revoke_group_invite(uuid) to authenticated;

-- service_role serve alla Edge Function, che legge la cache prima di andare su
-- Jikan: senza questo grant anime_search gli risponde "permission denied" e la
-- funzione brucia la quota Jikan a ogni ricerca non ancora in cache.
grant execute on function public.anime_search(text, text[], public.anime_type, public.anime_season,
  public.anime_status, integer, integer, numeric, integer, integer, text, integer, integer) to service_role;
grant execute on function public.anime_search_count(text, text[], public.anime_type, public.anime_season,
  public.anime_status, integer, integer, numeric, integer, integer) to service_role;
grant execute on function public.anime_current_season(integer, integer, text) to service_role;
grant execute on function public.anime_genres() to service_role;
grant execute on function public.anime_catalog_stats() to service_role;