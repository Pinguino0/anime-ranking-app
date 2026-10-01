-- ============================================================================
-- 014 â€” ranking, classifiche speciali, confronto, statistiche
-- ============================================================================
-- Il punto 14 del prompt e il motivo per cui questa migration esiste:
-- la media semplice non basta.
--
--   Anime A: 10.0 con 1 voto
--   Anime B:  9.4 con 20 voti
--
-- Con la media semplice A vince sempre, per sempre. Serve una prior: il
-- punteggio "pesato" (formula bayesiana usata da IMDb) tira verso la media
-- del gruppo quando i voti sono pochi, e la lascia coincidere con la media
-- vera quando sono molti.
--
--   weighted = (v / (v + m)) * R + (m / (v + m)) * C
--
--   v = numero di voti ricevuti
--   R = media reale dell'anime nel gruppo
--   C = media del gruppo (la prior)
--   m = soglia di voti (default 3): quanti voti servono per essere considerato
--       pienamente affidabile. Sotto questa soglia il risultato resta "incerto".
--
-- Il client mostra SEMPRE entrambi i numeri: la media vera (quella che le
-- persone citano parlando) e il punteggio di ranking (quello che ordina).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Snapshot giornalieri: servono per la variazione di posizione
-- ---------------------------------------------------------------------------
-- La variazione ("il tuo anime e salito di 3 posizioni") non e calcolabile
-- dalle tabelle live: servono i rank di ieri. Uno snapshot al giorno basta e
-- costa una riga per anime al giorno.
-- ---------------------------------------------------------------------------
create table public.ranking_snapshots (
  group_id      uuid not null references public.groups (id) on delete cascade,
  anime_id      uuid not null references public.anime (id) on delete cascade,
  snapshot_date date not null,
  rank_position      integer not null,
  ranking_score numeric(6,3) not null,
  mean_score    numeric(4,2) not null,
  vote_count    integer not null,

  primary key (group_id, anime_id, snapshot_date)
);

create index ranking_snapshots_lookup_idx
  on public.ranking_snapshots (group_id, snapshot_date desc);

comment on table public.ranking_snapshots is
  'Storico giornaliero del ranking, usato per calcolare la variazione di posizione.';

alter table public.ranking_snapshots enable row level security;

create policy "ranking_snapshots: lettura ai membri"
  on public.ranking_snapshots for select
  to authenticated
  using (public.is_group_member(group_id));

-- Lo snapshot lo scrive solo una Edge Function schedulata (service_role),
-- che salta la RLS. Il client non ha policy di scrittura.

-- ---------------------------------------------------------------------------
-- Classifica del gruppo
-- ---------------------------------------------------------------------------
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
-- Classifiche speciali (punto 13 del prompt)
-- ---------------------------------------------------------------------------
-- Una sola funzione con un _kind testuale: quattro query molto simili
-- diventano una, e il client ottiene sempre le stesse colonne.
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
    x.anime_id, x.title, x.image_url, x.value, x.secondary
  from (
    select s.anime_id, a.title, a.image_url,
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
-- Classifica personale (punto 15)
-- ---------------------------------------------------------------------------
-- Nota sul WHERE nullo: le funzioni che filtrano sull'appartenenza al gruppo
-- con "where is_group_member(...)" senza FROM non sono SQL valido
-- ("syntax error near WHERE"). Il "(select 1) as _d" e' una riga dummy che
-- rende la clausola leggibile e, se l'utente non e' membro, produce zero righe
-- invece di un errore.
create or replace function public.my_ranking(
  _group_id uuid,
  _sort     text default 'score',
  _desc     boolean default true,
  _limit    integer default 100,
  _offset   integer default 0
)
returns table (
  anime_id        uuid,
  title           text,
  japanese_title  text,
  image_url       text,
  episodes        integer,
  year            integer,
  genres          text[],
  score           numeric,
  watch_status    public.watchlist_status,
  current_episode integer,
  is_favorite     boolean,
  updated_at      timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    a.id, a.title, a.japanese_title, a.image_url, a.episodes, a.year, a.genres,
    r.score, w.status, w.current_episode, coalesce(w.is_favorite, false),
    greatest(r.updated_at, w.updated_at)
  from public.ratings r
  join public.anime a on a.id = r.anime_id
  left join public.watchlists w
         on w.anime_id = r.anime_id
        and w.group_id = r.group_id
        and w.user_id  = r.user_id
 where r.group_id = _group_id
   and r.user_id  = (select auth.uid())
   and public.is_group_member(_group_id)
 order by
   -- Whitelist: il nome della colonna viene dal client, non puo finire in
   -- un ORDER BY grezzo. Ogni riga produce NULL tranne il criterio scelto,
   -- cosi i NULL si accodano in fondo e l'ordinamento di cui sopra e unico.
   case when _sort = 'title' and _desc then a.title end desc,
   case when _sort = 'title' and not _desc then a.title end asc,
   case when _sort = 'episodes' and _desc then a.episodes end desc,
   case when _sort = 'episodes' and not _desc then a.episodes end asc,
   case when _sort = 'year' and _desc then a.year end desc,
   case when _sort = 'year' and not _desc then a.year end asc,
   case when _sort = 'updated' and _desc then r.updated_at end desc,
   case when _sort = 'updated' and not _desc then r.updated_at end asc,
   case when _sort = 'score' and _desc then r.score end desc,
   case when _sort = 'score' and not _desc then r.score end asc
 limit least(greatest(_limit, 1), 300)
 offset greatest(_offset, 0);
$$;

-- ---------------------------------------------------------------------------
-- Confronto fra due utenti (punto 17)
-- ---------------------------------------------------------------------------
-- La percentuale di somiglianza e una statistica matematica pura:
--   somiglianza = 100 * (1 - scarto_medio / 10)
-- Vale 100 quando i due utenti hanno dato esattamente gli stessi voti agli
-- stessi anime, 0 quando divergono sempre di 10 punti.
-- Non e un giudizio sulla persona: e la distanza fra due serie di numeri.
-- ---------------------------------------------------------------------------
create or replace function public.compare_users(
  _group_id uuid,
  _user_a   uuid,
  _user_b   uuid
)
returns table (
  anime_id       uuid,
  title          text,
  image_url      text,
  score_a        numeric,
  score_b        numeric,
  diff           numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with pair as (
    select
      ra.anime_id,
      ra.score as score_a,
      rb.score as score_b,
      abs(ra.score - rb.score) as diff
    from public.ratings ra
    join public.ratings rb
      on rb.anime_id = ra.anime_id
     and rb.group_id = ra.group_id
     and rb.user_id  = _user_b
    where ra.group_id = _group_id
      and ra.user_id  = _user_a
  )
  select p.anime_id, a.title, a.image_url, p.score_a, p.score_b, p.diff
    from pair p
    join public.anime a on a.id = p.anime_id
   where public.is_group_member(_group_id)
     -- Confrontarsi con se stessi non ha senso.
     and _user_a <> _user_b
   order by p.diff desc, a.title
   limit 500;
$$;

create or replace function public.compare_summary(
  _group_id uuid,
  _user_a   uuid,
  _user_b   uuid
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with pair as (
    select
      ra.anime_id,
      ra.score as score_a,
      rb.score as score_b,
      abs(ra.score - rb.score) as diff
    from public.ratings ra
    join public.ratings rb
      on rb.anime_id = ra.anime_id
     and rb.group_id = ra.group_id
     and rb.user_id  = _user_b
    where ra.group_id = _group_id and ra.user_id = _user_a
  )
  select jsonb_build_object(
    'common',        (select count(*) from pair),
    'mean_diff',     round(coalesce((select avg(diff) from pair), 0), 2),
    'similarity',    round(
      -- 100 * (1 - scarto medio / 10). Nessun anime in comune: 0.
      100 * (1 - coalesce((select avg(diff) from pair), 10) / 10)
    , 0),
    'agreed',        (select count(*) from pair where diff <= 0.5),
    'disagreed',     (select count(*) from pair where diff >= 3.0),
    'only_a',        (select count(*) from public.ratings
                       where group_id = _group_id and user_id = _user_a
                         and not exists (select 1 from pair p where p.anime_id = ratings.anime_id)),
    'only_b',        (select count(*) from public.ratings
                       where group_id = _group_id and user_id = _user_b
                         and not exists (select 1 from pair p where p.anime_id = ratings.anime_id))
  )
  from (select 1) as _d
  where public.is_group_member(_group_id);
$$;

-- ---------------------------------------------------------------------------
-- Statistiche individuali (punto 22)
-- ---------------------------------------------------------------------------
create or replace function public.personal_stats(
  _group_id uuid,
  _user_id  uuid
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with my_ratings as (
    select * from public.ratings
     where group_id = _group_id and user_id = _user_id
  ),
  my_watch as (
    select * from public.watchlists
     where group_id = _group_id and user_id = _user_id
  )
  select jsonb_build_object(
    'rated_count',     (select count(*) from my_ratings),
    'mean_score',      round(coalesce((select avg(score) from my_ratings), 0), 2),
    'max_score',       coalesce((select max(score) from my_ratings), 0),
    'min_score',       coalesce((select min(score) from my_ratings), 0),
    'watched_count',   (select count(*) from my_watch),
    'completed',       (select count(*) from my_watch where status = 'completed'),
    'watching',        (select count(*) from my_watch where status = 'watching'),
    'dropped',         (select count(*) from my_watch where status = 'dropped'),
    'favorites',       (select count(*) from my_watch where is_favorite),
    'episodes_watched',(select coalesce(sum(w.current_episode), 0) from my_watch w
                         join public.anime a on a.id = w.anime_id
                        -- Stime in ore solo su episodi realmente guardati:
                        -- contare gli episodi "in visione" come se fossero
                        -- tutti visti gonfierebbe il dato di parecchio.
                        where w.status in ('watching', 'completed')),
    'estimated_hours', round(
                        -- 0.75h = 45 min per episodio, la durata tipica di un
                        -- episodio anime. E' una stima dichiarata: la durata
                        -- reale varia, ma introdurre qui la duration di MAL
                        -- cambierebbe il risultato a ogni sync del catalogo.
                        (select coalesce(sum(w.current_episode), 0) * 0.75
                           from my_watch w
                          where w.status in ('watching', 'completed')
                        ), 1),
    'top_genre', (
      -- I generi stanno su anime, non su ratings: senza il join la
      -- sottostringa resterebbe sempre NULL.
      select g.genre
        from my_ratings r
        join public.anime a on a.id = r.anime_id
        cross join lateral unnest(a.genres) as g(genre)
       group by g.genre order by count(*) desc, g.genre limit 1
    ),
    'top_studio', (
      select a.studio from my_watch w
        join public.anime a on a.id = w.anime_id
       where a.studio is not null
       group by a.studio order by count(*) desc, a.studio limit 1
    ),
    'top_year', (
      select a.year::int from my_watch w
        join public.anime a on a.id = w.anime_id
       where a.year is not null
       group by a.year order by count(*) desc, a.year limit 1
    ),
    'score_distribution', (
      select coalesce(jsonb_object_agg(k::text, v), '{}'::jsonb)
        from (
          select floor(r.score)::int as k, count(*) as v
            from my_ratings r group by 1
        ) d
    )
  )
  from (select 1) as _d
  where public.is_group_member(_group_id);
$$;

-- ---------------------------------------------------------------------------
-- Statistiche di gruppo (punto 23)
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
      select jsonb_build_object('anime_id', a.id, 'title', a.title, 'image_url', a.image_url, 'mean', round(g.mean_score, 2))
        from agg g join public.anime a on a.id = g.anime_id
       order by g.mean_score desc, g.votes desc limit 1
    ),
    'most_voted_anime', (
      select jsonb_build_object('anime_id', a.id, 'title', a.title, 'image_url', a.image_url, 'votes', g.votes)
        from agg g join public.anime a on a.id = g.anime_id
       order by g.votes desc limit 1
    ),
    'most_divisive', (
      select jsonb_build_object('anime_id', a.id, 'title', a.title, 'image_url', a.image_url,
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
-- Distribuzione dei voti di un singolo anime (grafico della pagina anime)
-- ---------------------------------------------------------------------------
create or replace function public.rating_distribution(
  _group_id uuid,
  _anime_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'mean', round(coalesce(avg(r.score), 0), 2),
    'count', count(*),
    'buckets', coalesce((
      select jsonb_object_agg(k::text, v)
        from (
          -- Bucket da 1 punto: con incrementi di 0.5 i bucket pari
          -- contengono solo voto .0 e i dispari solo voto .5, il grafico
          -- resta leggibile.
          select floor(r2.score)::int as k, count(*) as v
            from public.ratings r2
           where r2.group_id = _group_id and r2.anime_id = _anime_id
           group by 1
        ) d
    ), '{}'::jsonb),
    'secondary', (
      select round(avg(r3.story_score), 2)      from public.ratings r3 where r3.group_id = _group_id and r3.anime_id = _anime_id and r3.story_score      is not null
    ),
    'secondary_characters', (
      select round(avg(r4.character_score), 2)  from public.ratings r4 where r4.group_id = _group_id and r4.anime_id = _anime_id and r4.character_score  is not null
    ),
    'secondary_animation', (
      select round(avg(r5.animation_score), 2)  from public.ratings r5 where r5.group_id = _group_id and r5.anime_id = _anime_id and r5.animation_score  is not null
    ),
    'secondary_fights', (
      select round(avg(r6.fights_score), 2)     from public.ratings r6 where r6.group_id = _group_id and r6.anime_id = _anime_id and r6.fights_score     is not null
    ),
    'secondary_soundtrack', (
      select round(avg(r7.soundtrack_score), 2) from public.ratings r7 where r7.group_id = _group_id and r7.anime_id = _anime_id and r7.soundtrack_score is not null
    ),
    'secondary_fun', (
      select round(avg(r8.fun_score), 2)        from public.ratings r8 where r8.group_id = _group_id and r8.anime_id = _anime_id and r8.fun_score        is not null
    )
  )
  from public.ratings r
  where r.group_id = _group_id and r.anime_id = _anime_id
    and public.is_group_member(_group_id)
  group by r.anime_id
  having count(*) > 0;
$$;

-- ---------------------------------------------------------------------------
-- Pubblicazione dei permessi
-- ---------------------------------------------------------------------------
revoke all on function public.group_ranking(uuid, integer, integer, numeric)          from public;
revoke all on function public.special_rankings(uuid, text, integer, numeric)            from public;
revoke all on function public.my_ranking(uuid, text, boolean, integer, integer)        from public;
revoke all on function public.compare_users(uuid, uuid, uuid)                           from public;
revoke all on function public.compare_summary(uuid, uuid, uuid)                         from public;
revoke all on function public.personal_stats(uuid, uuid)                                from public;
revoke all on function public.group_stats(uuid)                                          from public;
revoke all on function public.rating_distribution(uuid, uuid)                           from public;

grant execute on function public.group_ranking(uuid, integer, integer, numeric)   to authenticated;
grant execute on function public.special_rankings(uuid, text, integer, numeric)   to authenticated;
grant execute on function public.my_ranking(uuid, text, boolean, integer, integer) to authenticated;
grant execute on function public.compare_users(uuid, uuid, uuid)                  to authenticated;
grant execute on function public.compare_summary(uuid, uuid, uuid)                to authenticated;
grant execute on function public.personal_stats(uuid, uuid)                       to authenticated;
grant execute on function public.group_stats(uuid)                                 to authenticated;
grant execute on function public.rating_distribution(uuid, uuid)                  to authenticated;
