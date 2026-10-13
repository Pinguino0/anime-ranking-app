-- ============================================================================
-- watch_history - "Continua da dove hai lasciato" e Cronologia
-- ============================================================================
-- `watch_progress` tiene gia' la posizione per episodio. Mancavano due letture:
-- la riga "Continua" in home e la pagina Cronologia. Nessuna tabella nuova:
-- due funzioni, cosi' l'ordinamento e il "un episodio per anime" restano nel
-- database invece di essere replicati nel client.
--
-- "Continua" e' per ANIME, non per episodio: se ho iniziato la S1 E3 e poi la
-- S1 E4 lasciandola a meta', deve comparire una riga sola — la E4. Il DISTINCT
-- ON sceglie l'episodio aggiornato piu' di recente per ogni anime. Gli episodi
-- completati non entrano qui: quelli stanno in Cronologia.
--
-- Entrambe filtrano su `auth.uid()` e girano come `security invoker`: l'RLS di
-- `watch_progress` resta in vigore, quindi non si leggono i dati di un altro.

create or replace function public.continue_watching(_limit integer default 12)
returns table (
  anime_id uuid,
  anime_title text,
  image_url text,
  episode_id uuid,
  episode_num integer,
  current_seconds integer,
  updated_at timestamptz
)
language sql
stable
security invoker
set search_path = public
as $$
  with latest as (
    select distinct on (e.anime_id)
           e.anime_id, e.id as episode_id, e.episode_num,
           wp.current_seconds, wp.updated_at
      from public.watch_progress wp
      join public.episodes e on e.id = wp.episode_id
     where wp.user_id = auth.uid()
       and wp.completed = false
       and wp.current_seconds > 0
     order by e.anime_id, wp.updated_at desc
  )
  select a.id, a.title, a.image_url,
         l.episode_id, l.episode_num, l.current_seconds, l.updated_at
    from latest l
    join public.anime a on a.id = l.anime_id
   order by l.updated_at desc
   limit greatest(_limit, 1);
$$;

comment on function public.continue_watching(integer) is
  'Righe "Continua da dove hai lasciato": un episodio per anime, il piu'' recente lasciato a meta''.';

create or replace function public.watch_history(_limit integer default 60, _offset integer default 0)
returns table (
  anime_id uuid,
  anime_title text,
  image_url text,
  episode_id uuid,
  episode_num integer,
  current_seconds integer,
  completed boolean,
  updated_at timestamptz
)
language sql
stable
security invoker
set search_path = public
as $$
  select a.id, a.title, a.image_url,
         e.id, e.episode_num, wp.current_seconds, wp.completed, wp.updated_at
    from public.watch_progress wp
    join public.episodes e on e.id = wp.episode_id
    join public.anime a on a.id = e.anime_id
   where wp.user_id = auth.uid()
   order by wp.updated_at desc
   limit greatest(_limit, 1) offset greatest(_offset, 0);
$$;

comment on function public.watch_history(integer, integer) is
  'Cronologia dell''utente collegato: ogni episodio guardato, dal piu'' recente.';

revoke all on function public.continue_watching(integer) from public, anon;
revoke all on function public.watch_history(integer, integer) from public, anon;
grant execute on function public.continue_watching(integer) to authenticated;
grant execute on function public.watch_history(integer, integer) to authenticated;
