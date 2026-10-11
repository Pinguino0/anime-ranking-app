-- ---------------------------------------------------------------------------
-- 20261008120000_title_it_rpc
--
-- Espone `title_it` nelle RPC che restituiscono righe del catalogo
-- (`anime_search`, `anime_current_season`).
--
-- Le due funzioni usano la stessa tabella di ritorno: la UI continua a usarne
-- una sola struttura (AnimeEntry.parse), quindi un campo aggiunto in una sola
-- renderebbe la scheda dettaglio con il titolo italiano e la home no. Aggiunto
-- a entrambe, subito dopo `title` come nelle colonne della tabella.
--
-- La tabella di ritorno cambia, e `create or replace` non lo permette quando
-- cambia il tipo di ritorno: serve `drop function`. Il drop butta anche i
-- privilegi della 021, quindi qui si ripristinano esattamente quelli:
-- esegue solo `authenticated` e `service_role`, mai `anon`. (Chi scrive il
-- catalogo e' service_role, chi lo cerca senza login non esiste: l'app ha
-- sempre una sessione.) Lo smagliamento e' dell'ordine di un secondo.
-- ---------------------------------------------------------------------------

drop function public.anime_search(
  text, text[], public.anime_type, public.anime_season, public.anime_status,
  integer, integer, numeric, integer, integer, text, integer, integer
);
drop function public.anime_current_season(integer, integer, text);

create or replace function public.anime_search(
  _query         text default null,
  _genres        text[] default null,
  _media_type    public.anime_type default null,
  _season        public.anime_season default null,
  _status        public.anime_status default null,
  _year_from     integer default null,
  _year_to       integer default null,
  _min_score     numeric default null,
  _min_episodes  integer default null,
  _max_episodes  integer default null,
  _sort          text default 'relevance',
  _limit         integer default 24,
  _offset        integer default 0
)
returns table (
  id               uuid,
  external_id      text,
  title            text,
  title_it         text,
  japanese_title   text,
  synopsis         text,
  image_url        text,
  episodes         integer,
  status           public.anime_status,
  year             integer,
  genres           text[],
  media_type       public.anime_type,
  season           public.anime_season,
  aired_from       date,
  aired_to         date,
  score            numeric,
  scored_by        bigint,
  popularity       bigint,
  duration         text,
  studio           text,
  similarity       real,
  in_catalog       boolean
)
language sql
stable
security definer
set search_path = public
as $$
  with prepared as (
    select
      nullif(btrim(coalesce(_query, '')), '') as q,
      '%' || public.escape_like(btrim(coalesce(_query, ''))) || '%' as pattern,
      greatest(coalesce(_offset, 0), 0)        as off,
      least(greatest(coalesce(_limit, 24), 1), 60) as lim
  ),
  matched as (
    select
      a.*,
      public.anime_title_similarity(p.q, a.search_blob) as similarity
    from public.anime a, prepared p
    where
      (p.q is null
       or a.search_blob ilike p.pattern escape '\'
       or a.title = p.q)
      and public.anime_matches_filters(
        a, _genres, _media_type, _season, _status,
        _year_from, _year_to, _min_score,
        _min_episodes, _max_episodes
      )
  )
  select
    m.id,
    m.external_id,
    m.title,
    m.title_it,
    m.japanese_title,
    m.synopsis,
    m.image_url,
    m.episodes,
    m.status,
    m.year,
    m.genres,
    m.media_type,
    m.season,
    m.aired_from,
    m.aired_to,
    m.score,
    m.scored_by,
    m.popularity,
    m.duration,
    m.studio,
    m.similarity,
    true as in_catalog
  from matched m, prepared p
  order by
    case
      when p.q is not null then m.similarity
      else 0
    end desc,
    case
      when p.q is not null then m.score
      else 0
    end desc nulls last,
    m.aired_from desc nulls last,
    m.popularity  desc nulls last,
    m.id
  limit (select p.lim from prepared p)
  offset (select p.off from prepared p);
$$;

create or replace function public.anime_current_season(
  _limit    integer default 24,
  _offset   integer default 0,
  _genre    text default null
)
returns table (
  id               uuid,
  external_id      text,
  title            text,
  title_it         text,
  japanese_title   text,
  synopsis         text,
  image_url        text,
  episodes         integer,
  status           public.anime_status,
  year             integer,
  genres           text[],
  media_type       public.anime_type,
  season           public.anime_season,
  aired_from       date,
  aired_to         date,
  score            numeric,
  scored_by        bigint,
  popularity       bigint,
  duration         text,
  studio           text,
  similarity       real,
  in_catalog       boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    a.id, a.external_id, a.title, a.title_it, a.japanese_title, a.synopsis,
    a.image_url, a.episodes, a.status, a.year, a.genres, a.media_type,
    a.season, a.aired_from, a.aired_to, a.score, a.scored_by, a.popularity,
    a.duration, a.studio,
    0::real as similarity,
    true as in_catalog
  from public.anime a
  where
    (
      (a.aired_from is not null
       and a.aired_from >= current_date - 90)
      or (a.media_type in ('ONA', 'Special', 'Music')
          and a.aired_from is not null
          and a.aired_from >= current_date - 365)
      or (a.status = 'currently_airing'
          and a.aired_from is not null
          and a.aired_from >= current_date - 365)
    )
    and (_genre is null or a.genres @> array[_genre])
  order by
    case when a.status = 'currently_airing' then 0 else 1 end,
    a.aired_from desc nulls last,
    a.popularity desc nulls last,
    a.id
  limit least(greatest(coalesce(_limit, 24), 1), 60)
  offset greatest(coalesce(_offset, 0), 0);
$$;

comment on function public.anime_search(text, text[], public.anime_type, public.anime_season,
  public.anime_status, integer, integer, numeric, integer, integer, text, integer, integer) is
  'Ricerca paginata nel catalogo anime locale. Tutti i filtri sono opzionali (NULL = disattivato).';

revoke all on function public.anime_search(text, text[], public.anime_type, public.anime_season,
  public.anime_status, integer, integer, numeric, integer, integer, text, integer, integer) from anon, public;
revoke all on function public.anime_current_season(integer, integer, text) from anon, public;
grant execute on function public.anime_search(text, text[], public.anime_type, public.anime_season,
  public.anime_status, integer, integer, numeric, integer, integer, text, integer, integer) to authenticated;
grant execute on function public.anime_search(text, text[], public.anime_type, public.anime_season,
  public.anime_status, integer, integer, numeric, integer, integer, text, integer, integer) to service_role;
grant execute on function public.anime_current_season(integer, integer, text) to authenticated;
grant execute on function public.anime_current_season(integer, integer, text) to service_role;