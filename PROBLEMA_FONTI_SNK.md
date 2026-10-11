Problema: tutte le fonti per episodio 1 di Attack on Titan (external_id 16498) sono is_active=false. Manca la fonte canonica Gogoanime via generic_api.

## Soluzione
Apri Supabase SQL Editor e esegui questa query:

```sql
INSERT INTO episode_sources (episode_id, canonical_url, provider_id, source_type, quality, language)
SELECT e.id, 'https://www1.gogoanime.bid/watch/shingeki-no-kyojin-episode-1', (SELECT id FROM providers WHERE slug='gogoanime'), 'hls', '1080p', 'sub'
FROM episodes e JOIN anime a ON a.id=e.anime_id
WHERE a.external_id::int=16498 AND e.episode_num=1
AND NOT EXISTS (
  SELECT 1 FROM episode_sources s
  WHERE s.episode_id=e.id
    AND s.canonical_url='https://www1.gogoanime.bid/watch/shingeki-no-kyojin-episode-1'
    AND s.provider_id=(SELECT id FROM providers WHERE slug='gogoanime')
);
```

## Verifica
```sql
SELECT s.is_active, p.slug, s.canonical_url, s.source_url FROM episode_sources s
LEFT JOIN providers p ON p.id=s.provider_id
JOIN episodes e ON e.id=s.episode_id
JOIN anime a ON a.id=e.anime_id
WHERE a.external_id::int=16498 AND e.episode_num=1;
```

## Test
1. Riavvia app Windows (animerank_debug/animerank.exe)
2. Apri ep.1 di Attack on Titan
3. Dovrebbe usare Gogoanime (generic_api) → resolve-source → Consumet → video reale
