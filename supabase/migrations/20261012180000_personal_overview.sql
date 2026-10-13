-- ============================================================================
-- personal_overview - le statistiche personali del profilo
-- ============================================================================
-- `personal_stats(_group_id, _user_id)` racconta un gruppo solo. Nel profilo
-- pero' l'utente vuole il quadro d'insieme: tutto quello che ha visto e votato,
-- in qualunque gruppo e nella lista personale. Questa funzione lo aggrega.
--
-- Una differenza che non e' un dettaglio: lo stesso anime puo' stare in piu'
-- gruppi e nella lista personale, con progressi diversi. Per le statistiche
-- dell'utente vale UNA volta — altrimenti "In watchlist" conterebbe i gruppi, e
-- chi ha cinque gruppi si vedrebbe moltiplicato per cinque. Vince la riga col
-- progresso piu' avanti, che e' quella che rappresenta davvero dove e' arrivato.
--
-- La funzione non prende parametri: l'utente se lo legge da `auth.uid()`, cosi'
-- non si puo' chiedere il profilo di un altro passando un id.

create or replace function public.personal_overview()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with my_watch as (
    select distinct on (anime_id)
           anime_id, status, current_episode, is_favorite
      from (
        select w.anime_id, w.status, w.current_episode, w.is_favorite
          from public.watchlists w
         where w.user_id = auth.uid()
        union all
        select p.anime_id, p.status, p.current_episode, p.is_favorite
          from public.personal_watchlist p
         where p.user_id = auth.uid()
      ) tutte
     order by anime_id, current_episode desc
  ),
  my_ratings as (
    select r.anime_id, r.score
      from public.ratings r
     where r.user_id = auth.uid()
  )
  select jsonb_build_object(
    'rated_count',      (select count(*) from my_ratings),
    'mean_score',       round(coalesce((select avg(score) from my_ratings), 0), 2),
    'max_score',        coalesce((select max(score) from my_ratings), 0),
    'min_score',        coalesce((select min(score) from my_ratings), 0),
    'watched_count',    (select count(*) from my_watch),
    'completed',        (select count(*) from my_watch where status = 'completed'),
    'watching',         (select count(*) from my_watch where status = 'watching'),
    'dropped',          (select count(*) from my_watch where status = 'dropped'),
    'favorites',        (select count(*) from my_watch where is_favorite),
    -- Solo cio' che e' stato davvero guardato (in visione o completato):
    -- sommare anche i "da iniziare" gonfierebbe il totale di parecchio.
    'episodes_watched', (
      select coalesce(sum(current_episode), 0)
        from my_watch
       where status in ('watching', 'completed')
    ),
    'estimated_hours', round(
      -- 0.75h = 45 min a episodio, la stessa stima dichiarata di personal_stats.
      (select coalesce(sum(current_episode), 0) * 0.75
         from my_watch
        where status in ('watching', 'completed')
      ), 1),
    'top_genre', (
      -- I generi stanno su anime, non su ratings: senza il join la sottostringa
      -- di `genres` resterebbe sempre NULL.
      select g.genre
        from my_ratings r
        join public.anime a on a.id = r.anime_id
        cross join lateral unnest(a.genres) as g(genre)
       group by g.genre
       order by count(*) desc, g.genre
       limit 1
    ),
    'top_studio', (
      select a.studio
        from my_watch w
        join public.anime a on a.id = w.anime_id
       where a.studio is not null
       group by a.studio
       order by count(*) desc, a.studio
       limit 1
    ),
    'top_year', (
      select a.year::int
        from my_watch w
        join public.anime a on a.id = w.anime_id
       where a.year is not null
       group by a.year
       order by count(*) desc, a.year
       limit 1
    ),
    'score_distribution', (
      select coalesce(jsonb_object_agg(k::text, v), '{}'::jsonb)
        from (
          select floor(score)::int as k, count(*) as v
            from my_ratings
           group by 1
        ) d
    )
  );
$$;

comment on function public.personal_overview() is
  'Statistiche dell''utente collegato su tutti i gruppi e la lista personale; le opere ripetute contano una volta sola.';

revoke all on function public.personal_overview() from public, anon;
grant execute on function public.personal_overview() to authenticated;
