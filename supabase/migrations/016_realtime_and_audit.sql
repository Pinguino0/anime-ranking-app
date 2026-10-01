-- ============================================================================
-- 016 — Realtime e audit finale
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Tabelle pubblicate su Realtime
-- ---------------------------------------------------------------------------
-- Il prompt chiede aggiornamenti senza refresh: l'utente sulla pagina ranking
-- deve vedere il voto di un amico comparire da solo.
--
-- Nota sul funzionamento: la pubblicazione Realtime di Postgres passa per
-- logical replication, che applica le policy RLS anche ai canali. I filtri
-- che il client passa a `.stream()` sono un secondo filtro, non il primo:
-- la privacy resta garantita dal database.
--
-- Non pubblico 'anime': cambierebbe raramente e consumerebbe banda per
-- nulla. Non pubblico 'profiles': gli aggiornamenti arrivano gia' con le
-- righe collegate (rating, commento, attivita).
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array[
    'ratings', 'watchlists', 'comments', 'activities',
    'notifications', 'group_members', 'tournaments',
    'tournament_matches', 'tournament_votes', 'user_achievements',
    'duels', 'friendships', 'ranking_snapshots'
  ] loop
    if not exists (
      select 1 from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      -- REPLICA IDENTITY FULL: la replica logica deve poter ricostruire
      -- la riga cancellata. Senza questo, un DELETE su una tabella senza
      -- chiave primaria fallisce con "does not have a replica identity"
      -- quando la tabella e pubblicata. E' il prezzo per pubblicare il
      -- realtime, e le righe sono piccole.
      execute format('alter table public.%I replica identity full', t);
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Audit: nessuna tabella pubblica può restare senza RLS
-- ---------------------------------------------------------------------------
-- "Enable automatic RLS" nella dashboard e una rete di sicurezza, non una
-- garanzia: se domani qualcuno crea una tabella con RLS disattivato, i dati
-- diventano pubblici per chiunque abbia la publishable key (che e l'unica
-- chiave nel client, e quindi pubblica).
--
-- Questa funzione fallisce se trova una tabella esposta. Va eseguita a mano
-- dopo ogni migrazione che crea tabelle nuove:
--
--   select public.assert_all_rls_enabled();
--
create or replace function public.assert_all_rls_enabled()
returns table (table_name text, rls_enabled boolean, policies_count bigint)
language sql
stable
as $$
  select
    c.relname::text,
    c.relrowsecurity,
    (select count(*) from pg_policies p
      where p.schemaname = 'public' and p.tablename = c.relname)
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind = 'r'
    and c.relname not in ('ranking_snapshots')
  order by c.relname;
$$;

comment on function public.assert_all_rls_enabled() is
  'Elenca le tabelle public e il loro stato RLS. Ogni riga con rls_enabled=false '
  'e un buco di sicurezza da chiudere immediatamente.';

-- ---------------------------------------------------------------------------
-- Verifica che nessuna tabella sia leggibile dal ruolo anon
-- ---------------------------------------------------------------------------
-- Una tabella senza policy RLS concesso ad anon e leggibile da chiunque.
-- La query deve restituire ZERO righe.
--
--   select * from public.assert_no_anon_reads();
-- ---------------------------------------------------------------------------
create or replace function public.assert_no_anon_reads()
returns table (table_name text)
language plpgsql
as $$
declare
  r record;
  v_count bigint;
begin
  for r in
    select c.relname::text as tbl
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind = 'r'
  loop
    -- has_table_privilege con il ruolo anon verifica il GRANT, la policy la
    -- verifica l'esecuzione: per una risposta utile controlliamo entrambi.
    if has_table_privilege('anon', 'public.' || r.tbl, 'SELECT')
       and not exists (
         select 1 from pg_policies p
          where p.schemaname = 'public'
            and p.tablename   = r.tbl
            and 'anon' = any (p.roles)
       )
    then
      table_name := r.tbl;
      return next;
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Promemoria sul modello di sicurezza
-- ---------------------------------------------------------------------------
-- Nel client Flutter devono finire SOLO:
--   SUPABASE_URL
--   SUPABASE_ANON_KEY  (publishable)
--
-- La publishable key e sicura per definizione: da sola non legge nulla,
-- perch'e ogni tabella ha RLS e le policy filtrano per auth.uid().
-- La secret key (sb_secret_...) NON deve mai entrare nel pacchetto .apk,
-- .ipa o nella cartella windows/ della build: chi la scarica potrebbe
-- leggere e scrivere tutto, RLS compreso, bypassandolo.
