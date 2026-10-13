-- ---------------------------------------------------------------------------
-- 20261013180000_recent_episodes
--
-- "Nuovi episodi" per la home.
--
-- Il catalogo non ha un modo per dire "a questo anime e' stata aggiunta una
-- puntata": le righe della home sono ordinate per voto, popolarita' o data di
-- uscita, e nessuno di questi criteri sa che un episodio e' appena arrivato.
-- La sincronizzazione degli episodi, invece, scrive `episodes.created_at`, e
-- quella e' l'unica traccia dell'evento.
--
-- La funzione restituisce gli anime che hanno avuto un episodio per ultimi, uno
-- per anime (l'ultima puntata scritta), con la stessa forma di `anime_search`:
-- la riga della home riusa `AnimeEntry.parse` senza un parser a parte.
--
-- Non e' un "watchlist" ne' un filtro per utente: e' un elenco uguale per tutti,
-- quindi sta fra le funzioni di catalogo.
-- ---------------------------------------------------------------------------

create or replace function public.recent_episodes(
  _limit integer default 20
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
  -- Una riga per anime: l'episodio piu' recente. `distinct on` vuole l'ordine
  -- che comincia con la chiave del distinct, quindi `anime_id` prima di
  -- `created_at desc`.
  with latest as (
    select distinct on (e.anime_id)
           e.anime_id, e.created_at
      from public.episodes e
     order by e.anime_id, e.created_at desc, e.episode_num desc
  )
  select
    a.id,
    a.external_id,
    a.title,
    a.title_it,
    a.japanese_title,
    a.synopsis,
    a.image_url,
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
    a.popularity,
    a.duration,
    a.studio,
    -- Nessuna ricerca testuale: il campo serve solo a riempire la forma attesa
    -- da `anime_search`. Zero dice "non pertinente", non "nessuna somiglianza".
    0::real as similarity,
    true as in_catalog
  from latest l
  join public.anime a on a.id = l.anime_id
  order by l.created_at desc, a.title
  limit least(greatest(coalesce(_limit, 20), 1), 60);
$$;

comment on function public.recent_episodes(integer) is
  'Gli anime a cui sono stati aggiunti episodi per ultimi, uno per anime, con la stessa forma di anime_search.';

revoke all on function public.recent_episodes(integer) from public, anon;
grant execute on function public.recent_episodes(integer) to authenticated, service_role;
