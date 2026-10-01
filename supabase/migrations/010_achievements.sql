-- ============================================================================
-- 010 — achievements
-- ============================================================================
-- Definizioni statiche (seed) + sblocco valutato da trigger.
--
-- La valutazione gira nel database e non nel client perche deve valere anche
-- per azioni che arrivano dalla coda offline o da una Edge Function: se la
-- valutazione stesse nel client, un utente con la app chiusa non accumulerebbe
-- nulla e il risultato dipenderebbe da quale dispositivo ha fatto l'azione.
-- ============================================================================

create table public.achievements (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  name        text not null,
  description text not null,
  icon        text not null default '🏆',
  -- Regola in forma leggibile/dicografica, mostrata nelle impostazioni.
  requirement text not null,
  -- Soglia numerica usata dalla valutazione (NULL se non numerica).
  threshold   numeric,
  hidden      boolean not null default false,
  created_at  timestamptz not null default now()
);

comment on table public.achievements is
  'Catalogo achievement. Le regole sono valutate da evaluate_achievements().';

create table public.user_achievements (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references public.profiles (id) on delete cascade,
  achievement_id uuid not null references public.achievements (id) on delete cascade,
  unlocked_at    timestamptz not null default now(),

  constraint user_achievements_unique unique (user_id, achievement_id)
);

create index user_achievements_user_idx on public.user_achievements (user_id, unlocked_at desc);

comment on table public.user_achievements is
  'Achievement sbloccati. Unici per utente: la constraint impedisce i duplicati.';

-- ---------------------------------------------------------------------------
-- Seed del catalogo
-- ---------------------------------------------------------------------------
insert into public.achievements (code, name, description, icon, requirement, threshold) values
  ('first_vote',        'Primo voto',              'Dai il tuo primo voto a un anime.',                  '🏆', 'Vota 1 anime',                    1),
  ('ten_votes',         'Dieci voti',              'Vota 10 anime diversi.',                             '⭐', 'Vota 10 anime',                   10),
  ('critic',            'Critico',                 'Vota 100 anime. Nessuno legge piu di te.',          '🔥', 'Vota 100 anime',                  100),
  ('completionist',     'Completista',             'Completa 50 anime.',                                '🎌', 'Completa 50 anime',               50),
  ('the_dropper',       'Il Droppatore',           'Droppa 10 anime. A volte e giusto.',                '💀', 'Droppa 10 anime',                 10),
  ('top_10',            'Top 10',                  'Metti 10 anime tra i preferiti.',                   '👑', 'Aggiungi 10 preferiti',           10),
  ('binge_watcher',     'Binge watcher',           'Porta un anime oltre l''episodio 100.',             '📺', 'Aggiorna 1 anime oltre l''ep. 100', 100),
  ('twins',             'Gemelli',                 'Somiglianza voti >= 80% con un amico, su 20 anime in comune.', '🤝', 'Somiglianza >= 80% con un amico', 80),
  ('unpopular_opinion', 'Opinione impopolare',     'Dai un voto ad almeno 3.0 dalla media del gruppo.', '⚔️', 'Voto >= 3.0 di scarto dalla media del gruppo', 3.0),
  ('social_butterfly',  'Social butterfly',        'Aggiungi 5 amici.',                                 '🦋', 'Aggiungi 5 amici',                5),
  ('tournament_champ',  'Veterano del torneo',   'Vota in un torneo che si conclude.',                '🎖️', 'Partecipa a 1 torneo concluso',    1),
  ('first_comment',     'Primo commento',          'Scrivi il primo commento.',                         '💬', 'Scrivi 1 commento',               1);

-- ---------------------------------------------------------------------------
-- Valutazione
-- ---------------------------------------------------------------------------
-- Restituisce il numero di achievement sbloccati da questa chiamata, cosi i
-- trigger possono generare l'attivita solo quando c'e qualcosa di nuovo.
--
-- SECURITY DEFINER perche deve leggere anche le righe di altri utenti
-- (per "Gemelli" e per la media del gruppo). La riga "twins" e volutamente
-- limitata ai gruppi in cui l'utente e membro: anche con i privilegi del
-- proprietario la funzione non puo sfiorare voti di gruppi estranei.
-- ---------------------------------------------------------------------------
create or replace function public.evaluate_achievements(_user_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_unlocked integer := 0;
  v_row      record;
begin
  if _user_id is null then
    return 0;
  end if;

  for v_row in
    select a.code, a.threshold
      from public.achievements a
     where not exists (
             select 1 from public.user_achievements ua
              where ua.user_id = _user_id and ua.achievement_id = a.id
           )
  loop
    declare
      v_ok boolean := false;
    begin
      -- CASE e' un'espressione SQL: ogni ramo deve valere a uno scalare
      -- booleano. I rami che contano righe sono quindi racchiusi in una
      -- sub-select "(select ...)", non scritti come SELECT a se' stante.
      select case v_row.code

        when 'first_vote' then
          exists (select 1 from public.ratings r where r.user_id = _user_id)

        when 'ten_votes' then
          (select count(*) >= 10 from public.ratings where user_id = _user_id)

        when 'critic' then
          (select count(*) >= 100 from public.ratings where user_id = _user_id)

        when 'completionist' then
          (select count(*) >= 50 from public.watchlists
            where user_id = _user_id and status = 'completed')

        when 'the_dropper' then
          (select count(*) >= 10 from public.watchlists
            where user_id = _user_id and status = 'dropped')

        when 'top_10' then
          (select count(*) >= 10 from public.watchlists
            where user_id = _user_id and is_favorite)

        when 'binge_watcher' then
          exists (
            select 1 from public.watchlists
             where user_id = _user_id and current_episode >= 100
          )

        when 'first_comment' then
          exists (
            select 1 from public.comments where user_id = _user_id
          )

        when 'social_butterfly' then
          (select count(*) >= 5 from (
            select case when requester_id = _user_id then receiver_id
                        else requester_id end as other
              from public.friendships
             where status = 'accepted'
               and (requester_id = _user_id or receiver_id = _user_id)
          ) f)

        when 'unpopular_opinion' then
          -- Almeno un voto con scarto >= soglia dalla media del gruppo,
          -- su un gruppo di cui l'utente e membro.
          exists (
            select 1
              from public.ratings mine
              join public.ratings others on others.group_id = mine.group_id
                                     and others.anime_id  = mine.anime_id
             where mine.user_id = _user_id
               and others.user_id <> _user_id
               and abs(mine.score - others.score) >= v_row.threshold
          )

        when 'twins' then
          -- Somiglianza = 100 * (1 - scarto medio / 10).
          -- Solo amici che condividono almeno un gruppo con l'utente.
          exists (
            select 1 from (
              select
                coalesce(avg(abs(mine.score - theirs.score)), 0) as mean_diff,
                count(*) as common
                from public.ratings mine
                join public.ratings theirs on theirs.anime_id = mine.anime_id
                                         and theirs.group_id = mine.group_id
                                         and theirs.user_id <> mine.user_id
                join (
                  select case when requester_id = _user_id then receiver_id
                              else requester_id end as other
                    from public.friendships
                   where status = 'accepted'
                     and (requester_id = _user_id or receiver_id = _user_id)
                ) fr on fr.other = theirs.user_id
               where mine.user_id = _user_id
                 and mine.group_id in (
                       select group_id from public.group_members where user_id = _user_id
                     )
               group by mine.user_id
            ) sim
            where sim.common >= 20
              and (100 * (1 - sim.mean_diff / 10)) >= v_row.threshold
          )

        when 'tournament_champ' then
          -- Ha votato almeno uno scontro in un torneo arrivato alla finale.
          exists (
            select 1
              from public.tournament_votes tv
              join public.tournament_matches m on m.id = tv.match_id
              join public.tournaments t on t.id = m.tournament_id
             where tv.user_id = _user_id
               and t.status = 'completed'
          )

        else false
      end
      into v_ok;

      if v_ok then
        insert into public.user_achievements (user_id, achievement_id)
        select _user_id, a.id from public.achievements a where a.code = v_row.code
        on conflict (user_id, achievement_id) do nothing;

        if found then
          v_unlocked := v_unlocked + 1;

          perform public.log_activity(
            gm.group_id, _user_id, 'achievement_unlocked', null,
            jsonb_build_object('achievement_code', v_row.code)
          ) from (
            select group_id from public.group_members
             where user_id = _user_id order by joined_at limit 1
          ) gm;
        end if;
      end if;
    end;
  end loop;

  return v_unlocked;
end;
$$;

revoke all on function public.evaluate_achievements(uuid) from public;
grant  execute on function public.evaluate_achievements(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Trigger: rivaluta dopo ogni azione rilevante
-- ---------------------------------------------------------------------------
-- NB: le tabelle non hanno tutte le stesse colonne dell'attore.
--   - ratings, watchlists, comments -> user_id
--   - friendships                     -> requester_id / receiver_id
-- Due errori da evitare, entrambi incontrati:
--   1) usare sempre new.user_id faceva fallire ogni richiesta di amicizia con
--      'record "old" has no field "user_id"';
--   2) mettere old/new in una variabile "record" generica NON funziona:
--      l'accesso a v_row.requester_id su una tabella che non ha quel campo
--      fallisce a runtime con 'record "v_row" has no field "requester_id"'.
-- Si decide quindi su TG_TABLE_NAME e si leggono i campi direttamente da
-- old/new, che PL/pgSQL tipizza con il rowtype della tabella effettiva.
--
-- Su friendships vanno rivalutati ENTRAMBI gli utenti: anche il destinatario ha
-- compiuto un'azione, quindi e' lui che puo sbloccare gli achievement sociali.
create or replace function public.trg_evaluate_achievements()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_table_name = 'friendships' then
    if tg_op = 'DELETE' then
      perform public.evaluate_achievements(old.requester_id);
      perform public.evaluate_achievements(old.receiver_id);
    else
      perform public.evaluate_achievements(new.requester_id);
      perform public.evaluate_achievements(new.receiver_id);
    end if;
  else
    perform public.evaluate_achievements(
      case when tg_op = 'DELETE' then old.user_id else new.user_id end
    );
  end if;

  -- Trigger AFTER: il valore restituito viene ignorato. Restituire
  -- coalesce(new, old) non funziona su DELETE, dove "new" non e' assegnato.
  return null;
end;
$$;

create trigger ratings_eval_achievements
  after insert or update or delete on public.ratings
  for each row execute function public.trg_evaluate_achievements();

create trigger watchlists_eval_achievements
  after insert or update or delete on public.watchlists
  for each row execute function public.trg_evaluate_achievements();

create trigger comments_eval_achievements
  after insert on public.comments
  for each row execute function public.trg_evaluate_achievements();

create trigger friendships_eval_achievements
  after insert or update on public.friendships
  for each row execute function public.trg_evaluate_achievements();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
-- Il catalogo e pubblico agli autenticati (lo si mostra nelle impostazioni).
alter table public.achievements enable row level security;

create policy "achievements: lettura da autenticati"
  on public.achievements for select
  to authenticated
  using (true);

alter table public.user_achievements enable row level security;

-- Un utente vede solo i propri achievement sbloccati.
create policy "user_achievements: lettura dei propri"
  on public.user_achievements for select
  to authenticated
  using (user_id = (select auth.uid()));

-- Nessuna INSERT: si scrive solo tramite evaluate_achievements().
