-- ============================================================================
-- 026 – episodi, fonti episodi e progresso visione
-- ============================================================================

create type public.episode_source_type as enum (
  'iframe',
  'hls',
  'mp4'
);

create table public.episodes (
  id          uuid primary key default gen_random_uuid(),
  anime_id    uuid not null references public.anime (id) on delete cascade,
  mal_id      integer,
  episode_num integer not null,
  title       text,
  aired_at    timestamptz,
  filler      boolean default false,
  recap       boolean default false,
  thumbnail   text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint episodes_unique unique (anime_id, episode_num),
  constraint episodes_mal_unique unique (anime_id, mal_id),
  constraint episodes_num_positive check (episode_num > 0)
);

create index episodes_anime_idx on public.episodes (anime_id);
create index episodes_mal_idx on public.episodes (mal_id);

create trigger episodes_set_updated_at
  before update on public.episodes
  for each row execute function public.set_updated_at();

comment on table public.episodes is 'Episodi anime per gestione voti e progresso per gruppo.';

create table public.episode_sources (
  id          uuid primary key default gen_random_uuid(),
  episode_id  uuid not null references public.episodes (id) on delete cascade,
  source_url  text not null,
  source_type public.episode_source_type not null,
  quality     varchar(10),
  language    varchar(10),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create index episode_sources_episode_idx on public.episode_sources (episode_id);
create index episode_sources_active_idx on public.episode_sources (is_active);

comment on table public.episode_sources is 'Fonti di visione disponibili per un episodio (iframe/hls/mp4).';

create table public.watch_progress (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references public.profiles (id) on delete cascade,
  episode_id       uuid not null references public.episodes (id) on delete cascade,
  -- Non puo' chiamarsi `current_time`: e' una funzione built-in di Postgres e
  -- come colonna va tra apici, il che costringerebbe a scrivere
  -- `select("current_time")` in ogni client. Il nome dice gia' l'unita'.
  current_seconds  integer not null default 0,
  completed        boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint watch_progress_unique unique (user_id, episode_id),
  constraint watch_progress_time_nonneg check (current_seconds >= 0)
);

create index watch_progress_user_idx on public.watch_progress (user_id);
create index watch_progress_episode_idx on public.watch_progress (episode_id);

create trigger watch_progress_set_updated_at
  before update on public.watch_progress
  for each row execute function public.set_updated_at();

comment on table public.watch_progress is 'Progresso di visione per episodio (secondi guardati e completamento).';

alter table public.episodes enable row level security;
alter table public.episode_sources enable row level security;
alter table public.watch_progress enable row level security;

create policy "episodes: lettura autenticati"
  on public.episodes for select
  to authenticated
  using (true);

create policy "episode_sources: lettura autenticati attivi"
  on public.episode_sources for select
  to authenticated
  using (is_active = true);

create policy "watch_progress: proprio"
  on public.watch_progress for all
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "episodes: service write"
  on public.episodes for all
  to service_role
  using (true)
  with check (true);

create policy "episode_sources: service write"
  on public.episode_sources for all
  to service_role
  using (true)
  with check (true);