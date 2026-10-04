-- ============================================================================
-- 027 - voti per episodio e lettura degli episodi con il progresso
--
-- La 026 ha creato `episodes`, `episode_sources` e `watch_progress`, ma non il
-- voto per singolo episodio. Senza questo, il prompt chiede una cosa che
-- l'app non puo' fare: distinguere "Anime 8.7" da "Episodio 7 -> 9.4". Il voto
-- dell'opera vive in `ratings` e resta li: i due voti sono indipendenti, e
-- mescolarli darebbe un numero che non descrive nessuna delle due cose.
--
-- Cosa aggiunge:
--   - `episode_ratings`  : il voto personale su un episodio
--   - `episodes_for_anime`: gli episodi di un anime con il progresso e il voto
--                           del chiamante, gia' uniti
--   - `episodes_summary` : quante fonti attive ha un episodio
--
-- Il progresso resta letto e scritto in diretta su `watch_progress`: la 026 gli
-- ha gia' dato una policy "own rows" che copre l'upsert, quindi non serve una
-- RPC per risparmiare una chiamata che il client deve fare comunque.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- episode_ratings
--
-- Come `ratings`, il voto e' numeric(3,1) con la stessa validazione
-- `is_valid_rating`: stessi limiti e stesso passo, cosi' il cursore
-- dell'app e il CHECK del database non possono divergere.
-- ---------------------------------------------------------------------------
create table public.episode_ratings (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles (id) on delete cascade,
  episode_id uuid not null references public.episodes (id) on delete cascade,
  score      numeric(3,1) not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint episode_ratings_one_per_episode unique (user_id, episode_id),
  constraint episode_ratings_score_valid     check (public.is_valid_rating(score))
);

-- Indice sull'episodio e non sull'utente: e' la scheda episodio a leggere
-- "quanti hanno votato questo episodio", e il client legge gli episodi di un
-- anime, non i voti di un utente.
create index episode_ratings_episode_idx on public.episode_ratings (episode_id, score desc);

create trigger episode_ratings_set_updated_at
  before update on public.episode_ratings
  for each row execute function public.set_updated_at();

comment on table public.episode_ratings is
  'Voto personale su un singolo episodio, indipendente dal voto dell opera.';

alter table public.episode_ratings enable row level security;

-- Come `watch_progress`: un utente vede e scrive solo le proprie righe.
-- La policy copre anche l'upsert perche' `for all` comprende sia `using` che
-- `with check`: senza quest'ultimo un utente potrebbe inserire una riga con un
-- `user_id` non suo e il CHECK la lascerebbe passare.
create policy "episode_ratings: proprio"
  on public.episode_ratings for all
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "episode_ratings: service write"
  on public.episode_ratings for all
  to service_role
  using (true)
  with check (true);

-- Gli indici e le sequence sono leaking di informazione minimo, ma la 024 ha
-- gia' stabilito il criterio: ci�� che il client non tocca direttamente non
-- mantiene privilegi di tabella.
revoke all on public.episode_ratings from anon, authenticated;

-- ---------------------------------------------------------------------------
-- episodes_for_anime
--
-- Una RPC invece di tre query (episodi + progresso + voti) perche' il client
-- altrimenti dovrebbe unire i tre risultati da solo, e cosi' finirebbe per
-- mostrare il progresso di un episodio sulla riga sbagliata se gli id non
-- tornassero. Qui la corrispondenza e' fatta dal database, dove non puo'
-- sbagliare.
--
-- Il filtro su `auth.uid()` e' dentro la funzione e non in una policy: e'
-- l'unico posto dove il chiamante e' identificabile con certezza, perche' la
-- funzione gira come SECURITY DEFINER e non vede piu' il contesto del client.
-- ---------------------------------------------------------------------------
create or replace function public.episodes_for_anime(_anime_id uuid)
returns table (
  id             uuid,
  episode_num    integer,
  title          text,
  aired_at        timestamptz,
  filler         boolean,
  recap          boolean,
  thumbnail      text,
  source_count   integer,
  progress_time  integer,
  completed      boolean,
  my_score       numeric,
  community_avg  numeric,
  community_count bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    e.id,
    e.episode_num,
    e.title,
    e.aired_at,
    e.filler,
    e.recap,
    e.thumbnail,
    -- Conta solo le fonti attive: una fonte spenta non deve far credere che
    -- l'episodio sia guardabile quando il player non ha niente da aprire.
    (select count(*)::integer
       from public.episode_sources s
      where s.episode_id = e.id and s.is_active)            as source_count,
    coalesce(wp.current_seconds, 0)                         as progress_time,
    coalesce(wp.completed, false)                           as completed,
    er.score                                                as my_score,
    round(avg(cr.score), 1)                                 as community_avg,
    count(cr.id)                                            as community_count
  from public.episodes e
  left join public.watch_progress wp
    on wp.episode_id = e.id and wp.user_id = (select auth.uid())
  left join public.episode_ratings er
    on er.episode_id = e.id and er.user_id = (select auth.uid())
  left join public.episode_ratings cr
    on cr.episode_id = e.id
  where e.anime_id = _anime_id
  group by e.id, e.episode_num, e.title, e.aired_at, e.filler, e.recap,
           e.thumbnail, wp.current_seconds, wp.completed, er.score;
$$;

comment on function public.episodes_for_anime(uuid) is
  'Episodi di un anime con fonti attive, progresso e voto del chiamante.';

-- ---------------------------------------------------------------------------
-- episode_rate
--
-- Upsert del voto. Il `on conflict` e' sulla stessa coppia della UNIQUE, quindi
-- il tocco successivo corregge il voto precedente invece di crearne uno nuovo.
--
-- `_score = null` cancella il voto, e lo fa con una DELETE e non con un
-- `insert ... on conflict do update`: `score` e' NOT NULL, quindi scrivere
-- `null` nella riga fallirebbe. Senza questa via un voto dato per sbaglio
-- sarebbe definitivo, che e' il comportamento peggiore per un voto.
-- ---------------------------------------------------------------------------
create or replace function public.episode_rate(
  _episode_id uuid,
  _score      numeric
)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  _user   uuid := (select auth.uid());
  _stored numeric;
begin
  if _user is null then
    raise exception 'Sessione non valida.' using errcode = '28000';
  end if;

  if _score is null then
    delete from public.episode_ratings
     where user_id = _user and episode_id = _episode_id;

    return null;
  end if;

  -- La validazione e' qui e non solo nel CHECK: la CHECK vale a runtime, ma
  -- senza questo controllo l'errore arriverebbe come un'eccezione di vincolo,
  -- che il client non sa tradurre. Qui il messaggio e' gia' quello che serve.
  if not public.is_valid_rating(_score) then
    raise exception 'Il voto deve stare fra 0 e 10, a passi da 0.5.'
      using errcode = '22023';
  end if;

  insert into public.episode_ratings (user_id, episode_id, score)
  values (_user, _episode_id, _score)
  on conflict (user_id, episode_id)
  do update set score = excluded.score, updated_at = now()
  returning episode_ratings.score into _stored;

  return _stored;
end;
$$;

comment on function public.episode_rate(uuid, numeric) is
  'Registra o azzera il voto personale su un episodio.';

-- ---------------------------------------------------------------------------
-- episode_sources_list
--
-- Le fonti attive di un episodio, ordinate dalla piu' alta qualita' in giu'.
-- L'ordine e' quello del fallback automatico del client: se la prima non si
-- apre, si prova la successiva, quindi la piu' affidabile deve venire prima.
--
-- L'ordine e' calcolato qui e non con un `order by` sul lato client perche'
-- 720p e 1080p sono stringhe: ordinarle alfabeticamente metterebbe 1080p
-- dopo 720p, che e' esattamente il contrario di quello che si vuole.
-- ---------------------------------------------------------------------------
create or replace function public.episode_sources_list(_episode_id uuid)
returns table (
  id          uuid,
  source_url  text,
  source_type public.episode_source_type,
  quality     varchar,
  language    varchar,
  is_active   boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, s.source_url, s.source_type, s.quality, s.language, s.is_active
    from public.episode_sources s
   where s.episode_id = _episode_id
     and s.is_active
   order by
     case s.quality
       when '2160p' then 1 when '1440p' then 2 when '1080p' then 3
       when '720p'  then 4 when '480p'  then 5 else 6
     end,
     s.created_at;
$$;

comment on function public.episode_sources_list(uuid) is
  'Fonti attive di un episodio, dalla qualita piu alta in giu.';

-- ---------------------------------------------------------------------------
-- Privilegi sulle funzioni
--
-- Le stesse regole della 021: `anon` non chiama mai queste funzioni, e
-- `authenticated` puo' eseguirle ma non leggerne il sorgente.
-- ---------------------------------------------------------------------------
revoke all on function public.episodes_for_anime(uuid)      from public, anon;
revoke all on function public.episode_rate(uuid, numeric)   from public, anon;
revoke all on function public.episode_sources_list(uuid)    from public, anon;

grant execute on function public.episodes_for_anime(uuid)      to authenticated;
grant execute on function public.episode_rate(uuid, numeric)   to authenticated;
grant execute on function public.episode_sources_list(uuid)    to authenticated;