-- ===========================================================================
-- title_it nelle RPC di classifica, duelli e tornei
-- ===========================================================================
-- Aggiunge la colonna title_it all'output delle funzioni che restituiscono
-- titoli di anime, cosi' la UI puo' mostrare il titolo italiano anche in
-- classifica, duelli e tornei (fallback italiano -> titolo del catalogo).
--
-- Le funzioni con "returns table" cambiano il tipo di ritorno, quindi vanno
-- droppate e ricreate: CREATE OR REPLACE non puo' cambiare la firma. Dopo il
-- drop i permessi vanno riassegnati (revoke from public, grant to authenticated).
-- I corpi sono identici alle migration 012/014/015: cambia solo l'aggiunta di
-- title_it. group_stats restituisce jsonb: solo la chiave in piu', nessun drop.

-- ---------------------------------------------------------------------------
-- Classifica del gruppo
-- ---------------------------------------------------------------------------
drop function if exists public.group_ranking(uuid, integer, integer, numeric);
create or replace function public.group_ranking(
  _group_id uuid,
  _limit    integer default 50,
  _offset   integer default 0,
  _m        numeric default 3
)
returns table (
  rank_position        integer,
  anime_id        uuid,
  title           text,
  title_it        text,
  japanese_title  text,
  image_url       text,
  episodes        integer,
  year            integer,
  genres          text[],
  mean_score      numeric,
  vote_count      bigint,
  ranking_score   numeric,
  my_score        numeric,
  position_delta  integer
)
language sql
stable
security definer
set search_path = public
as $$
  with scores as (
    select
      r.anime_id,
      count(*)::bigint                       as vote_count,
      avg(r.score)::numeric(5,2)            as mean_score,
      -- C: media del gruppo, calcolata una volta sola e riutilizzata.
      (select avg(score) from public.ratings where group_id = _group_id) as prior,
      avg(r.score)::numeric(5,2)            as r_avg
    from public.ratings r
    where r.group_id = _group_id
    group by r.anime_id
  ),
  weighted as (
    select
      s.*,
      -- Se il gruppo non ha ancora voti, prior e NULL: il coalesce porta a 0
      -- e il ranking risulta 0 finche il primo voto non arriva.
      round(
        (s.vote_count / (s.vote_count + _m)) * s.r_avg
        + (_m / (s.vote_count + _m)) * coalesce(s.prior, 0)
      , 3) as ranking_score
    from scores s
  ),
  -- Prima la posizione, poi il delta. Sono due passi separati perche' il delta
  -- deve confrontare la posizione appena calcolata con quella dello snapshot:
  -- una CTE non puo' referenziare se stessa nella stessa SELECT.
  numbered as (
    select
      row_number() over (order by w.ranking_score desc, w.mean_score desc, w.vote_count desc) as rank_position,
      w.*
    from weighted w
  ),
  ranked as (
    select
      n.*,
      -- Posizione nello snapshot piu recente di oggi: la differenza e la
      -- variazione. Se non esiste ancora nessuno snapshot, delta = 0.
      coalesce((
        select sn.rank_position - n.rank_position
          from public.ranking_snapshots sn
         where sn.group_id = _group_id
           and sn.anime_id  = n.anime_id
           and sn.snapshot_date = (
                 select max(snapshot_date) from public.ranking_snapshots s2
                  where s2.group_id = _group_id and s2.snapshot_date < current_date
               )
      ), 0) as position_delta
    from numbered n
  )
  select
    r.rank_position,
    r.anime_id,
    a.title,
    a.title_it,
    a.japanese_title,
    a.image_url,
    a.episodes,
    a.year,
    a.genres,
    r.mean_score,
    r.vote_count,
    r.ranking_score,
    mine.score as my_score,
    r.position_delta
  from ranked r
  join public.anime a on a.id = r.anime_id
  left join public.ratings mine
         on mine.anime_id = r.anime_id
        and mine.group_id = _group_id
        and mine.user_id  = (select auth.uid())
 where public.is_group_member(_group_id)
 order by r.ranking_score desc, r.mean_score desc, r.vote_count desc
 limit least(greatest(_limit, 1), 200)
 offset greatest(_offset, 0);
$$;

-- ---------------------------------------------------------------------------
-- Classifiche speciali
-- ---------------------------------------------------------------------------
drop function if exists public.special_rankings(uuid, text, integer, numeric);
create or replace function public.special_rankings(
  _group_id uuid,
  _kind     text,
  _limit    integer default 20,
  _m        numeric default 3
)
returns table (
  rank_position      integer,
  anime_id      uuid,
  title         text,
  title_it      text,
  image_url     text,
  value         numeric,
  secondary     numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with agg as (
    select
      r.anime_id,
      count(*)::bigint                    as vote_count,
      avg(r.score)::numeric(5,2)         as mean_score,
      -- "Piu divisivo": quanto i voti si disperdono. Lo spread (max - min)
      -- e' l'intuizione giusta, ma con 2 voti e' rumore: si divide per la
      -- deviazione standard, che con 2 valori coincide con lo spread/2.
      -- Il risultato si espone in secondi decimali per non sembrare preciso.
      stddev_pop(r.score)::numeric(5,2)  as spread,
      (select avg(score) from public.ratings where group_id = _group_id) as prior
    from public.ratings r
    where r.group_id = _group_id
    group by r.anime_id
  ),
  scored as (
    select
      a.*,
      round(
        (a.vote_count / (a.vote_count + _m)) * a.mean_score
        + (_m / (a.vote_count + _m)) * coalesce(a.prior, 0)
      , 3) as weighted
    from agg a
  )
  select
    row_number() over (order by x.value desc, x.anime_id) as rank_position,
    x.anime_id, x.title, x.title_it, x.image_url, x.value, x.secondary
  from (
    select s.anime_id, a.title, a.title_it, a.image_url,
           case _kind
             when 'top'      then s.weighted
             when 'most_voted' then s.vote_count::numeric
             when 'divisive' then coalesce(s.spread, 0)
             else 0
           end as value,
           case _kind
             when 'top'      then s.mean_score
             when 'most_voted' then s.weighted
             when 'divisive' then s.vote_count::numeric
             else 0
           end as secondary
    from scored s
    join public.anime a on a.id = s.anime_id
    where _kind in ('top', 'most_voted', 'divisive')
      -- "Piu divisivo" ha senso solo con almeno 3 voti: sotto questa soglia
      -- e rumore, non unanimeita' di opinioni.
      and (_kind <> 'divisive' or s.vote_count >= 3)
      and public.is_group_member(_group_id)
    order by value desc
    limit least(greatest(_limit, 1), 100)
  ) x;
$$;

-- ---------------------------------------------------------------------------
-- Statistiche di gruppo: title_it nei tre highlight
-- ---------------------------------------------------------------------------
create or replace function public.group_stats(_group_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with agg as (
    select
      r.anime_id,
      count(*)::int as votes,
      avg(r.score) as mean_score,
      stddev_pop(r.score) as spread
    from public.ratings r
    where r.group_id = _group_id
    group by r.anime_id
  )
  select jsonb_build_object(
    'member_count',   (select count(*) from public.group_members where group_id = _group_id),
    'anime_rated',    (select count(*) from agg),
    'total_votes',    (select count(*) from public.ratings where group_id = _group_id),
    'group_mean',     round(coalesce((select avg(score) from public.ratings where group_id = _group_id), 0), 2),
    'top_anime', (
      select jsonb_build_object('anime_id', a.id, 'title', a.title, 'title_it', a.title_it, 'image_url', a.image_url, 'mean', round(g.mean_score, 2))
        from agg g join public.anime a on a.id = g.anime_id
       order by g.mean_score desc, g.votes desc limit 1
    ),
    'most_voted_anime', (
      select jsonb_build_object('anime_id', a.id, 'title', a.title, 'title_it', a.title_it, 'image_url', a.image_url, 'votes', g.votes)
        from agg g join public.anime a on a.id = g.anime_id
       order by g.votes desc limit 1
    ),
    'most_divisive', (
      select jsonb_build_object('anime_id', a.id, 'title', a.title, 'title_it', a.title_it, 'image_url', a.image_url,
                                'spread', round(g.spread, 2), 'votes', g.votes)
        from agg g join public.anime a on a.id = g.anime_id
       where g.votes >= 3
       order by g.spread desc limit 1
    ),
    'top_genre', (
      select g.genre from public.anime a
        cross join lateral unnest(a.genres) as g(genre)
        join public.ratings r on r.anime_id = a.id
       where r.group_id = _group_id
       group by g.genre order by count(*) desc, g.genre limit 1
    ),
    'score_distribution', (
      select coalesce(jsonb_object_agg(k::text, v), '{}'::jsonb)
        from (select floor(score)::int as k, count(*) as v
                from public.ratings where group_id = _group_id group by 1) d
    )
  )
  from (select 1) as _d
  where public.is_group_member(_group_id);
$$;

-- ---------------------------------------------------------------------------
-- Classifica Elo dei duelli
-- ---------------------------------------------------------------------------
drop function if exists public.duel_elo(uuid);
create or replace function public.duel_elo(_group_id uuid)
returns table (
  anime_id   uuid,
  title      text,
  title_it   text,
  image_url  text,
  elo        numeric,
  duel_count bigint
)
language sql
stable
security definer
set search_path = public
as $$
  with recursive
    ord as (
      select
        row_number() over (order by d.created_at, d.id) as n,
        d.anime_a_id, d.anime_b_id, d.selected_anime_id
      from public.duels d
      where d.group_id = _group_id
    ),
    -- Lo stato e' una mappa anime_id -> Elo di TUTTI gli anime gia' incontrati.
    walk (n, state) as (
      -- Caso base: n = 0, nessun duello ancora giocato, stato vuoto.
      select 0::bigint, '{}'::jsonb

      union all

      select
        o.n,
        w.state || jsonb_build_object(
          -- L'attesa di a si calcola con l'Elo di b e viceversa.
          o.anime_a_id::text,
            cur.ea + 32 * (
              (case when o.anime_a_id = o.selected_anime_id then 1 else 0 end)
              - 1 / (1 + power(10, (cur.eb - cur.ea) / 400.0))
            ),
          o.anime_b_id::text,
            cur.eb + 32 * (
              (case when o.anime_b_id = o.selected_anime_id then 1 else 0 end)
              - 1 / (1 + power(10, (cur.ea - cur.eb) / 400.0))
            )
        )
      from walk w
      join ord o on o.n = w.n + 1
      cross join lateral (
        -- Elo corrente dei due contendenti: se non sono mai apparsi valgono 1000.
        select
          coalesce((w.state ->> o.anime_a_id::text)::numeric, 1000) as ea,
          coalesce((w.state ->> o.anime_b_id::text)::numeric, 1000) as eb
      ) cur
    ),
    last_state as (
      -- Lo stato finale e' quello dell'ultimo passo: contiene gia' gli Elo.
      select state from walk order by n desc limit 1
    ),
    final_state as (
      select (e.key)::uuid as anime_id, (e.value)::numeric as elo
        from last_state ls
        cross join lateral jsonb_each_text(ls.state) e
    ),
    participation as (
      select anime_id, count(*)::bigint as cnt
      from (
        select anime_a_id as anime_id from public.duels where group_id = _group_id
        union all
        select anime_b_id from public.duels where group_id = _group_id
      ) c
      group by anime_id
    )
  select
    f.anime_id,
    a.title,
    a.title_it,
    a.image_url,
    round(f.elo, 0) as elo,
    p.cnt
  from final_state f
  join public.anime a on a.id = f.anime_id
  join participation p on p.anime_id = f.anime_id
 where public.is_group_member(_group_id)
 order by f.elo desc, f.anime_id
 limit 100;
$$;

-- ---------------------------------------------------------------------------
-- Prossima coppia di duello
-- ---------------------------------------------------------------------------
drop function if exists public.next_duel_pair(uuid);
create or replace function public.next_duel_pair(_group_id uuid)
returns table (anime_a_id uuid, anime_b_id uuid, title_a text, title_b text, title_it_a text, title_it_b text, image_a text, image_b text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_a    uuid;
  v_b    uuid;
  v_pair uuid[];
begin
  if not public.is_group_member(_group_id) then
    raise exception 'Permessi insufficienti' using errcode = '42501';
  end if;

  select a.id, b.id into v_a, v_b
  from (
    select distinct r.anime_id as id
      from public.ratings r
     where r.group_id = _group_id
     limit 60
  ) a
  cross join lateral (
    -- NB: niente "distinct" qui. Con DISTINCT l'ORDER BY deve comparire
    -- nella select list, quindi "order by random()" fallirebbe con 42P10.
    -- I duplicati sono innocui: "limit 1" restituisce comunque una riga sola.
    select r.anime_id as id
      from public.ratings r
     where r.group_id = _group_id
       and r.anime_id <> a.id
       and not exists (
         select 1 from public.duels d
          where d.group_id = _group_id
            and d.user_id  = v_uid
            and (d.anime_a_id, d.anime_b_id) in ((a.id, r.anime_id), (r.anime_id, a.id))
       )
     order by random()
     limit 1
  ) b
  limit 1;

  if v_a is null then
    -- Fallback: non c'e nessuna coppia nuova, prendi i due piu' votati.
    select array_agg(id) into v_pair
    from (
      select r.anime_id as id
        from public.ratings r
       where r.group_id = _group_id
       group by r.anime_id
       order by count(*) desc
       limit 2
    ) t;
    v_a := v_pair[1];
    v_b := v_pair[2];
  end if;

  return query
  select a.id, b.id, a.title, b.title, a.title_it, b.title_it, a.image_url, b.image_url
    from public.anime a, public.anime b
   where a.id = v_a and b.id = v_b;
end;
$$;

-- ---------------------------------------------------------------------------
-- Classifica dei tornei
-- ---------------------------------------------------------------------------
drop function if exists public.tournament_standings(uuid);
create or replace function public.tournament_standings(_tournament_id uuid)
returns table (
  anime_id      uuid,
  title         text,
  title_it      text,
  image_url     text,
  is_out        boolean,
  matches_won   bigint,
  votes_received bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.anime_id,
    a.title,
    a.title_it,
    a.image_url,
    p.is_out,
    (select count(*) from public.tournament_matches m
      where m.winner_anime_id = p.anime_id) as matches_won,
    (select count(*) from public.tournament_votes v
       join public.tournament_matches m2 on m2.id = v.match_id
      where m2.tournament_id = p.tournament_id and v.anime_id = p.anime_id) as votes_received
  from public.tournament_participants p
  join public.anime a on a.id = p.anime_id
 where p.tournament_id = _tournament_id
   and exists (
     select 1 from public.tournaments t
      where t.id = p.tournament_id and public.is_group_member(t.group_id)
   )
 order by p.is_out, matches_won desc, votes_received desc, a.title;
$$;

-- ---------------------------------------------------------------------------
-- Permessi (dopo il drop vanno riassegnati)
-- ---------------------------------------------------------------------------
revoke all on function public.group_ranking(uuid, integer, integer, numeric)   from public;
revoke all on function public.special_rankings(uuid, text, integer, numeric)   from public;
revoke all on function public.duel_elo(uuid)                                    from public;
revoke all on function public.next_duel_pair(uuid)                              from public;
revoke all on function public.tournament_standings(uuid)                        from public;

-- Dopo il DROP i nuovi oggetti ereditano i default privileges del progetto, che
-- concedono EXECUTE anche ad anon: le altre RPC del gruppo sono solo per
-- authenticated, quindi si allinea anche qui.
revoke execute on function public.group_ranking(uuid, integer, integer, numeric)  from anon;
revoke execute on function public.special_rankings(uuid, text, integer, numeric)  from anon;
revoke execute on function public.duel_elo(uuid)                                   from anon;
revoke execute on function public.next_duel_pair(uuid)                             from anon;
revoke execute on function public.tournament_standings(uuid)                       from anon;

grant execute on function public.group_ranking(uuid, integer, integer, numeric) to authenticated;
grant execute on function public.special_rankings(uuid, text, integer, numeric) to authenticated;
grant execute on function public.duel_elo(uuid)                                 to authenticated;
grant execute on function public.next_duel_pair(uuid)                           to authenticated;
grant execute on function public.tournament_standings(uuid)                     to authenticated;