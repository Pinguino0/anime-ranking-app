-- ============================================================================
-- seed_provider.sql - deriva mapping + episodi + fonti dall'indice provider
-- ============================================================================
--
-- Pipeline "harvest once, join forever". Idempotente: si puo' rieseguire.
-- Sostituisce la vecchia logica di seed_catalog.js basata sull'animeunity_id
-- scritto per somiglianza di titolo.
--
-- Ordine:
--   1) mapping anime <-> record provider (join per anilist_id)
--   2) vincolo di unicita' sulle fonti (anti-duplicati, una volta per sempre)
--   3) episodi 1..episodes_count per ogni mapping
--   4) rigenera le fonti AnimeUnity (hls) dalle mapping
-- ============================================================================

-- Il provider che risolve AnimeUnity/AnimeWorld.
--   da92e844-6560-4038-8431-f609f92b9a21 = mio_provider

-- 1) mapping ----------------------------------------------------------------
-- Per ogni anime (fonte anilist) si prendono i record del provider con lo
-- stesso anilist_id, uno per versione (sub/dub). DISTINCT ON sceglie in modo
-- deterministico se il provider avesse piu' record identici.
with cat as (
  select id, external_id::int as anilist_id
  from public.anime
  where external_source = 'anilist' and external_id ~ '^[0-9]+$'
)
insert into public.anime_provider_mappings
  (anime_id, provider_slug, provider_anime_id, is_dub, matched_by)
select distinct on (cat.id, i.is_dub)
  cat.id, i.provider_slug, i.provider_anime_id, i.is_dub, 'anilist_id'
from cat
join public.provider_anime_index i
  on i.provider_slug = 'mio_provider' and i.anilist_id = cat.anilist_id
order by cat.id, i.is_dub, i.provider_anime_id
on conflict do nothing;

-- 2) vincolo anti-duplicati sulle fonti --------------------------------------
create unique index if not exists episode_sources_episode_canonical_unique
  on public.episode_sources (episode_id, canonical_url)
  where canonical_url is not null;

-- 3) episodi -----------------------------------------------------------------
-- Cap a 200 episodi per anime (come il seed precedente): solo 20 anime lo
-- superano (es. One Piece 1180), e' un tetto di sicurezza per la UI.
insert into public.episodes (anime_id, episode_num)
select m.anime_id, g.n
from public.anime_provider_mappings m
join public.provider_anime_index i
  on i.provider_slug = m.provider_slug and i.provider_anime_id = m.provider_anime_id
join public.anime a on a.id = m.anime_id
cross join generate_series(1, least(
  case when coalesce(i.episodes_count, 0) > 0 then i.episodes_count
       else coalesce(a.episodes, 0) end, 200)) g(n)
where m.provider_slug = 'mio_provider'
on conflict (anime_id, episode_num) do nothing;

-- 4) fonti AnimeUnity --------------------------------------------------------
-- Si rimuovono SOLO le fonti AnimeUnity (hls) vecchie: le fonti AnimeWorld
-- (mp4) di fallback restano. Poi si ricreano dalle mapping, una per versione.
delete from public.episode_sources
where provider_id = 'da92e844-6560-4038-8431-f609f92b9a21'
  and canonical_url like 'https://www.animeunity.so/anime/%';

insert into public.episode_sources
  (episode_id, provider_id, canonical_url, source_type, quality, language, is_active)
select
  e.id,
  'da92e844-6560-4038-8431-f609f92b9a21',
  'https://www.animeunity.so/anime/' || m.provider_anime_id || '-x',
  'hls', '1080p',
  case when m.is_dub then 'ita' else 'sub' end,
  true
from public.anime_provider_mappings m
join public.provider_anime_index i
  on i.provider_slug = m.provider_slug and i.provider_anime_id = m.provider_anime_id
join public.anime a on a.id = m.anime_id
join public.episodes e
  on e.anime_id = m.anime_id
 and e.episode_num <= least(
   case when coalesce(i.episodes_count, 0) > 0 then i.episodes_count
        else coalesce(a.episodes, 0) end, 200)
where m.provider_slug = 'mio_provider'
on conflict (episode_id, canonical_url) do nothing;
