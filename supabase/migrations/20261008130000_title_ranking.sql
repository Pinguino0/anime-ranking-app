-- ---------------------------------------------------------------------------
-- 20261008130000_title_ranking
--
-- Migliora l'ordinamento di `anime_search` quando la query e' una frase.
--
-- Problema: con l'arrivo dei titoli italiani e del romaji nei sinonimi, molte
-- righe ottengono similarity = 1.0 (la frase compare per intero in search_blob),
-- e l'ordine fra loro finiva deciso da `score`/`aired_from`. Per
-- 'attacco dei giganti' la serie principale (16498) finiva DOPO le stagioni
-- ("Stagione 3 Parte 2" prima): l'utente vede il derivato prima dell'opera.
--
-- Soluzione, in cascata:
--   0. match esatto (case-insensitive) su title / title_it / japanese_title;
--   1. tutto il resto. Il WHERE pretende gia' la sottostringa, quindi
--      anime_title_similarity restituisce 1.0 per ogni riga ammessa e non
--      ordina nulla: il discriminante vero e' la lunghezza del titolo primario
--      piu' corto (la radice batte la stagione, che porta testo in piu').
--
-- Un tier "titolo che inizia con la query" e' stato provato e RIMOSSO: mandava
-- avanti i derivati con il titolo romaji in testa ("Shingeki no Kyojin: Chimi
-- Kyara...") rispetto alla serie radice, che ha il titolo in inglese. Fra due
-- match di sottostringa la lunghezza sceglie meglio del prefisso.
--
-- Il tipo di ritorno NON cambia: `create or replace` basta e conserva i
-- privilegi della 20261008120000 (authenticated + service_role).
-- ---------------------------------------------------------------------------

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
    -- Tier: 0 = titolo esatto, 1 = titolo che inizia con la query, 2 = resto.
    -- Con query vuota tutti a 0 e decide la similarita' (che sara' 0): resta
    -- valido l'ordinamento per score/aired_from della 019.
    case
      when p.q is null then 0
      when lower(m.title) = lower(p.q)
        or lower(coalesce(m.title_it, '')) = lower(p.q)
        or lower(coalesce(m.japanese_title, '')) = lower(p.q)
      then 0
      else 1
    end asc,
    -- `desc` sta FUORI dal case: la direzione fa parte dell ORDER BY, non
    -- dell'espressione calcolata (vedi nota in 019).
    case
      when p.q is not null then m.similarity
      else 0
    end desc,
    -- A parita' di tier e similarita', il titolo primario piu' corto e' quasi
    -- sempre l'opera radice: "Attack on Titan" batte "Attack on Titan Stagione 3".
    -- `least` (non `length(title_it)`) perche' l'italiano spesso ha l'articolo
    -- in piu' ("L'attacco dei Giganti") e non deve penalizzare la radice.
    case
      when p.q is not null
      then least(length(m.title), coalesce(length(m.title_it), length(m.title)))
      else 0
    end asc,
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

comment on function public.anime_search(text, text[], public.anime_type, public.anime_season,
  public.anime_status, integer, integer, numeric, integer, integer, text, integer, integer) is
  'Ricerca paginata nel catalogo anime locale. Tutti i filtri sono opzionali (NULL = disattivato).';