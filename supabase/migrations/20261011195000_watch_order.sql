-- ============================================================================
-- anime_watch_order - "da dove iniziare" per una saga
-- ============================================================================
-- La scheda anime mostra gia' i "correlati" (`anime_related`), ma quelli sono
-- solo i vicini diretti: chi apre la seconda stagione di un'opera non sa se
-- deve partire dalla prima, da un film o da uno special. Qui si costruisce
-- l'intera catena (la componente connessa del grafo prequel/sequel/parent) e la
-- si mette in ordine di uscita, cosi' la prima riga e' davvero quella da cui
-- cominciare.
--
-- Il grafo e' AniList: `anime_relations.anime_id` e' un'opera in catalogo,
-- `related_anilist_id` l'id AniList di un'altra. Molte relazioni esistono nei
-- due versi (A SEQUEL -> B e B PREQUEL -> A) ma non tutte, quindi il grafo si
-- tratta come non orientato: si cammina in entrambe le direzioni. Un'opera non
-- ancora in catalogo si raggiunge comunque (l'id AniList basta a nominarla) ma
-- non ha archi suoi: la catena si ferma li', che e' meglio di inventare.
--
-- Ordine: `aired_from`, poi l'anno, poi l'id AniList. La prima riga ha
-- `is_start = true`: e' l'opera da cui cominciare.
-- ============================================================================

create or replace function public.anime_watch_order(_anime_id uuid)
returns table (
  "position"       integer,
  is_start         boolean,
  id               uuid,
  external_id      text,
  title            text,
  title_it         text,
  japanese_title   text,
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
  studio           text
)
language sql
stable
as $$
  with recursive
  -- Nodo di partenza: l'anime aperto, se e' di AniList (le relazioni esistono
  -- solo per quegli anime). Il cast a bigint e' sicuro perche' e' filtrato.
  start_anime as (
    select a.external_id::bigint as alid
    from public.anime a
    where a.id = _anime_id
      and a.external_source = 'anilist'
      and a.external_id ~ '^[0-9]+$'
  ),
  -- Archi fra id AniList, solo i tipi che formano la catena principale.
  adj as (
    select a.external_id::bigint as src, r.related_anilist_id as dst
    from public.anime_relations r
    join public.anime a on a.id = r.anime_id
    where r.relation_type in ('PREQUEL', 'SEQUEL', 'PARENT')
      and a.external_source = 'anilist'
      and a.external_id ~ '^[0-9]+$'
  ),
  -- Il grafo si percorre in entrambi i versi: AniList non garantisce l'arco
  -- inverso, e senza questo la catena si spezzerebbe a meta'.
  und as (
    select src, dst from adj
    union
    select dst, src from adj
  ),
  -- Componente connessa: `union` (non `union all`) evita i cicli.
  walk(alid) as (
    select alid from start_anime
    union
    select u.dst from walk w join und u on u.src = w.alid
  ),
  -- Un rigo per opera raggiunta: titolo e poster vengono dall'anime in
  -- catalogo quando c'e', altrimenti dalla riga di relazione che l'ha nominata.
  info as (
    select
      w.alid,
      a.id,
      a.external_id,
      coalesce(a.title, r.related_title) as title,
      a.title_it,
      a.japanese_title,
      coalesce(a.image_url, r.related_image_url) as image_url,
      a.episodes,
      a.status,
      a.year,
      a.genres,
      a.media_type,
      a.season,
      a.aired_from,
      a.aired_to,
      a.score,
      a.scored_by,
      a.studio
    from walk w
    left join public.anime a
      on a.external_source = 'anilist'
     and a.external_id = w.alid::text
    left join lateral (
      select r.related_title, r.related_image_url
      from public.anime_relations r
      where r.related_anilist_id = w.alid
      order by r.created_at
      limit 1
    ) r on true
  ),
  -- L'ordine: data di uscita, poi anno, poi id AniList. Le opere senza data
  -- vanno in fondo invece di finire per errore in testa.
  ordered as (
    select
      row_number() over (
        order by
          coalesce(inf.aired_from, make_date(inf.year, 1, 1)) asc nulls last,
          inf.alid
      )::integer as "position",
      inf.*
    from info inf
  )
  select
    o."position",
    (o."position" = 1) as is_start,
    o.id,
    o.external_id,
    o.title,
    o.title_it,
    o.japanese_title,
    o.image_url,
    o.episodes,
    o.status,
    o.year,
    o.genres,
    o.media_type,
    o.season,
    o.aired_from,
    o.aired_to,
    o.score,
    o.scored_by,
    o.studio
  from ordered o
  order by o."position";
$$;

comment on function public.anime_watch_order(uuid) is
  'Ordine di visione consigliato: la catena prequel/sequel dell opera, ordinata per data di uscita. La prima riga e'' "inizia da qui".';

-- Stessi privilegi delle altre RPC di lettura: authenticated e service_role,
-- mai anon.
revoke all on function public.anime_watch_order(uuid) from anon, public;
grant execute on function public.anime_watch_order(uuid) to authenticated;
grant execute on function public.anime_watch_order(uuid) to service_role;
