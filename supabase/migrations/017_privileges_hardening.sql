-- ============================================================================
-- 017 — privileges hardening
-- ============================================================================
-- PostgreSQL concede EXECUTE su ogni funzione a TUTTI i ruoli, incluso anon.
-- Le nostre RPC controllano l'appartenenza al gruppo dentro il corpo, quindi
-- una chiamata anon non restituisce dati di altri gruppi. Ma e' una difesa in
-- profondo revocare l'esecuzione ai ruoli che non devono poterle chiamare:
-- cosi' anche un errore in una policy non diventa una fuga di dati.
--
-- Distinzione:
--   - trigger di tabella: li invoca il database, nessun ruolo deve poterli
--     chiamare a mano. Non sono protetti da RLS, quindi vanno chiusi.
--   - RPC di lettura: leggono gia' i permessi con is_group_member(), ma le
--     concediamo solo ad authenticated. Concedere l'esecuzione NON significa
--     concedere la lettura: il controllo interno resta obbligatorio.
--
-- service_role mantiene tutto: e' il ruolo delle Edge Function.
--
-- NB: le firme sono prese da pg_proc invece che scritte a mano, perche' una
-- firma sbagliata (parametri diversi) fa fallire l'intero blocco.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Trigger e handler interni: eseguibili solo dal database, non dai ruoli.
-- ---------------------------------------------------------------------------
do $$
declare
  v_rec record;
begin
  for v_rec in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = any (array[
             'handle_new_user',
             'set_updated_at',
             'check_username_lock',
             'comments_check_parent',
             'watchlists_check_episode',
             'friendships_guard_update',
             'log_activity',
             'notify_user',
             'notify_same_anime_rated',
             'notify_friend_request',
             'notify_comment_reply',
             'evaluate_achievements',
             'activities_on_rating',
             'activities_on_watchlist',
             'activities_on_comment',
'trg_evaluate_achievements',
              'check_watchlist_episode',
             'check_comment_parent',
             'rls_auto_enable',
             'generate_invite_code'
           ])
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', v_rec.sig);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- RPC di lettura e scrittura: solo authenticated.
-- ---------------------------------------------------------------------------
do $$
declare
  v_rec record;
begin
  for v_rec in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = any (array[
             'create_group',
             'join_group',
             'leave_group',
             'kick_member',
             'set_member_role',
             'transfer_group_ownership',
             'regenerate_invite_code',
             'group_ranking',
             'group_stats',
             'my_ranking',
             'special_rankings',
             'rating_distribution',
             'personal_stats',
             'compare_users',
             'compare_summary',
             'take_ranking_snapshot',
             'next_duel_pair',
             'duel_elo',
             'create_tournament',
             'delete_tournament',
             'cast_tournament_vote',
             'resolve_tournament_match',
             'tournament_standings',
             'delete_own_account',
             'is_group_member',
             'is_group_admin',
             'is_group_owner'
           ])
  loop
    execute format('revoke execute on function %s from public, anon', v_rec.sig);
    execute format('grant  execute on function %s to authenticated', v_rec.sig);
  end loop;
end $$;

-- take_ranking_snapshot scrive in ranking_snapshots: la esegue il servizio
-- schedulato, non il client. La tabella non ha policy di scrittura, quindi
-- anche aperta non scriverebbe nulla, ma si chiude comunque.
do $$
declare
  v_sig text;
begin
  select p.oid::regprocedure::text into v_sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'take_ranking_snapshot';
  if v_sig is not null then
    execute format('revoke execute on function %s from anon, authenticated', v_sig);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Due funzioni sono un caso particolare: non sono trigger che il database
-- invoca da solo, ma espressioni che PostgreSQL valuta con i privilegi di
-- CHI SCRIVE la riga. Revocarne EXECUTE a authenticated non "chiude" nulla,
-- rompe la scrittura.
--
--   - public.is_valid_rating(numeric): usata nei CHECK di public.ratings,
--     che vengono valutati con i privilegi di chi inserisce il voto.
--   - public.text_array_to_search(text[]): usata dalla colonna generata
--     public.anime.search_text, ricalcolata a ogni INSERT/UPDATE.
--
-- Entrambe restano quindi eseguibili da authenticated. Non e' un problema per
-- la sicurezza: sono funzioni pure, immutable, che non leggono ne scrivono
-- nulla e dipendono solo dai valori passati come argomento.
-- ---------------------------------------------------------------------------
revoke execute on function public.is_valid_rating(numeric) from public, anon;
grant  execute on function public.is_valid_rating(numeric) to authenticated;

revoke execute on function public.text_array_to_search(text[]) from public, anon;
grant  execute on function public.text_array_to_search(text[]) to authenticated;

-- ---------------------------------------------------------------------------
-- Verifica: nessuna funzione public deve restare eseguibile da anon.
-- Fallisce se in futuro qualcuno aggiunge una funzione dimenticandosi
-- della revoca, invece di accorgersene quando espone dati.
-- ---------------------------------------------------------------------------
create or replace function public.assert_no_public_exec_for_anon()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prokind = 'f'
       and has_function_privilege('anon', p.oid, 'execute')
  ) then
    raise exception 'Esistono ancora funzioni public eseguibili da anon: %',
      (select string_agg(p.proname, ', ')
         from pg_proc p
         join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.prokind = 'f'
          and has_function_privilege('anon', p.oid, 'execute'));
  end if;
end;
$$;

revoke execute on function public.assert_no_public_exec_for_anon() from public, anon, authenticated;

-- Le funzioni di audit di 016 verificano RLS e leggibilita anon: servono al
-- team in sviluppo, non al client. Nessun ruolo pubblico le deve poter
-- chiamare, nemmeno authenticated: un utente non deve poter sapere quale
-- policy esistono, solo godere del loro effetto.
do $$
declare
  v_rec record;
begin
  for v_rec in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = any (array[
             'assert_all_rls_enabled',
             'assert_no_anon_reads'
           ])
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', v_rec.sig);
  end loop;
end $$;

do $$
begin
  perform public.assert_no_public_exec_for_anon();
end $$;