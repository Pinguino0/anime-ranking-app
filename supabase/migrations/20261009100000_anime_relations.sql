-- ============================================================================
-- anime_relations - sequel/prequel e altre relazioni fra anime, da AniList
-- ============================================================================
-- Le relazioni non stanno nel dump `anilist_media.jsonl` (contiene solo i campi
-- principali del media), quindi si importano con una fetch GraphQL dedicata
-- (`scraper/seed/fetch_relations.js`). Qui la tabella e la lettura.
--
-- La scrittura resta a service_role (script/Edge Function): il client legge e
-- basta, come per `anime`.
-- ============================================================================

create table public.anime_relations (
  anime_id           uuid not null references public.anime(id) on delete cascade,
  relation_type      text not null,
  related_anilist_id bigint not null,
  related_title      text,
  related_image_url  text,
  related_format     public.anime_type,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  -- Una relazione e' identificata dalla terna (opera, opera correlata, tipo):
  -- AniList puo' avere piu' archi fra le stesse due opere (SEQUEL e SIDE_STORY)
  -- e sono informazioni diverse, non duplicati.
  primary key (anime_id, related_anilist_id, relation_type)
);

comment on table public.anime_relations is
  'Relazioni fra anime (sequel, prequel, ...) importate da AniList. Scrittura solo service_role.';
comment on column public.anime_relations.related_anilist_id is
  'Id AniList dell opera correlata. Si risolve verso anime.external_id con external_source = anilist.';
comment on column public.anime_relations.related_format is
  'Formato dell opera correlata, gia mappato su public.anime_type. NULL se sconosciuto.';

-- L'RPC fa join su questa colonna per risolvere la relazione verso il catalogo.
create index anime_relations_related_idx
  on public.anime_relations (related_anilist_id);

create trigger anime_relations_set_updated_at
  before update on public.anime_relations
  for each row execute function public.set_updated_at();

-- RLS: lettura da autenticati (come `anime`), scrittura solo service_role.
alter table public.anime_relations enable row level security;

create policy "anime_relations: lettura da autenticati"
  on public.anime_relations for select
  to authenticated
  using (true);

-- ---------------------------------------------------------------------------
-- Relazioni di un anime, risolte verso il catalogo interno
-- ---------------------------------------------------------------------------
-- Restituisce la stessa forma di `anime_search` (piu' relation_type) cosi' il
-- client riusa AnimeEntry.parse senza un parser a parte. Per le opere non
-- ancora in catalogo i campi arrivano dalla riga di relazione (titolo,
-- immagine, formato) e `in_catalog` e' false: la scheda si apre comunque.
create or replace function public.anime_related(_anime_id uuid)
returns table (
  relation_type    text,
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
  popularity       bigint,
  duration         text,
  studio           text,
  in_catalog       boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    r.relation_type,
    a.id,
    coalesce(a.external_id, r.related_anilist_id::text)                       as external_id,
    coalesce(a.title, r.related_title, 'Senza titolo')                        as title,
    a.title_it,
    a.japanese_title,
    coalesce(a.image_url, r.related_image_url)                                as image_url,
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
    (a.id is not null) as in_catalog
  from public.anime_relations r
  left join public.anime a
    on a.external_source = 'anilist'
   and a.external_id = r.related_anilist_id::text
  where r.anime_id = _anime_id
  order by
    case r.relation_type
      when 'PREQUEL' then 0
      when 'SEQUEL' then 1
      when 'SIDE_STORY' then 2
      when 'PARENT' then 3
      when 'ALTERNATIVE' then 4
      when 'SPIN_OFF' then 5
      else 9
    end,
    a.aired_from asc nulls last,
    r.related_anilist_id;
$$;

comment on function public.anime_related(uuid) is
  'Relazioni di un anime (sequel, prequel, ...), risolte verso il catalogo interno quando presenti.';

-- Stessi privilegi delle altre RPC di lettura: authenticated e service_role,
-- mai anon.
revoke all on function public.anime_related(uuid) from anon, public;
grant execute on function public.anime_related(uuid) to authenticated;
grant execute on function public.anime_related(uuid) to service_role;
