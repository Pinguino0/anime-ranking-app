-- ============================================================================
-- 007 — watchlists
-- ============================================================================
-- Cinque stati + flag preferito, come da sezione 11 del prompt.
-- current_episode e limitato a episodes quando l'anime ha un numero noto
-- ("347 / ?" quando sconosciuto -> nessun limite imposto dal database).
-- ============================================================================

create type public.watchlist_status as enum (
  'planned',    -- Da iniziare
  'watching',   -- In visione
  'completed',  -- Completato
  'dropped',    -- Droppato
  'paused'      -- In pausa
);

create table public.watchlists (
  id       uuid primary key default gen_random_uuid(),

  group_id uuid not null references public.groups (id) on delete cascade,
  user_id  uuid not null references public.profiles (id) on delete cascade,
  anime_id uuid not null references public.anime   (id) on delete cascade,

  status          public.watchlist_status not null default 'planned',
  current_episode integer not null default 0,
  is_favorite     boolean not null default false,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint watchlists_unique unique (group_id, user_id, anime_id),
  constraint watchlists_episode_positive check (current_episode >= 0)
);

create index watchlists_user_status_idx  on public.watchlists (user_id, status);
create index watchlists_group_idx       on public.watchlists (group_id);
create index watchlists_favorites_idx   on public.watchlists (user_id) where is_favorite;
create index watchlists_anime_idx       on public.watchlists (anime_id);

comment on table public.watchlists is
  'Lista personale per gruppo: stato, episodio corrente, preferito.';

create trigger watchlists_set_updated_at
  before update on public.watchlists
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Coerenza episodio / totale episodi
-- ---------------------------------------------------------------------------
-- Il vincolo su episodes vive su watchlists perche l'anime potrebbe cambiare
-- numero di episodi dopo l'aggiunta alla lista (stagioni aggiuntive).
-- Se l'anime scende sotto l'episodio corrente, l'utente viene avvisato dal
-- client; non blocchiamo la modifica per non perdergli il dato.
-- ---------------------------------------------------------------------------
create or replace function public.check_watchlist_episode()
returns trigger
language plpgsql
as $$
declare
  v_total integer;
begin
  select a.episodes into v_total
    from public.anime a
   where a.id = new.anime_id;

  if new.current_episode > 0 and v_total is not null and new.current_episode > v_total then
    raise exception 'Episodio % superiore ai % episodi disponibili', new.current_episode, v_total
      using errcode = '22023';
  end if;

  return new;
end;
$$;

create trigger watchlists_check_episode
  before insert or update on public.watchlists
  for each row execute function public.check_watchlist_episode();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.watchlists enable row level security;

create policy "watchlists: lettura ai membri"
  on public.watchlists for select
  to authenticated
  using (public.is_group_member(group_id));

-- Il toggle "preferito" e personale ma condiviso: i membri vedono quali
-- anime ha messo a preferito ciascuno, perche e parte del confronto.
create policy "watchlists: inserimento proprio da membro"
  on public.watchlists for insert
  to authenticated
  with check (
    user_id = (select auth.uid())
    and public.is_group_member(group_id)
  );

create policy "watchlists: modifica propria"
  on public.watchlists for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "watchlists: eliminazione propria o da admin"
  on public.watchlists for delete
  to authenticated
  using (
    user_id = (select auth.uid())
    or public.is_group_admin(group_id)
  );
