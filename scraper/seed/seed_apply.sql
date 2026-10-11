-- derive episodi: un riga per numero (generate_series)
insert into public.episodes (anime_id, episode_num)
select a.id, g.n
from public.anime a
cross join generate_series(1, (a.external_data->>'animeunity_eps')::int) g(n)
where a.external_data ? 'animeunity_id'
  and (a.external_data->>'animeunity_eps')::int > 0
on conflict (anime_id, episode_num) do nothing;

-- derive fonti: una per episodio, canonical = pagina anime (risoluzione dinamica)
-- La lingua segue external_data.animeunity_dub: i titoli senza la versione
-- sottotitolata (solo doppiaggio, es. Rocky Joe) si segnano 'ita', gli altri
-- 'sub'.
insert into public.episode_sources
  (episode_id, provider_id, canonical_url, source_type, quality, language, is_active)
select e.id, 'da92e844-6560-4038-8431-f609f92b9a21',
       'https://www.animeunity.so/anime/' || (a.external_data->>'animeunity_id') || '-x',
       'hls', '1080p',
       case when (a.external_data->>'animeunity_dub')::boolean then 'ita' else 'sub' end,
       true
from public.episodes e
join public.anime a on a.id = e.anime_id
where a.external_data ? 'animeunity_id'
on conflict (episode_id, canonical_url) do nothing;
