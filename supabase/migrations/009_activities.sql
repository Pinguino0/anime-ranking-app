-- ============================================================================
-- 009 — activities (activity feed)
-- ============================================================================
-- Il feed e scritto da TRIGGER, non dal client. Motivo: cosi l'attivita
-- viene registrata anche quando la scrittura arriva da una Edge Function,
-- dalla coda offline o da un client diverso, senza che ogni caller debba
-- ricordarsi di chiamare "logActivity".
--
-- Il testo della frase ("Marco ha votato X - 10") NON e memorizzato qui:
-- si compone dal type + metadata lato client. Motivo: cambio di lingua,
-- redesign e formattazione restano gratis, e la tabella resta normalizzata.
-- ============================================================================

create type public.activity_type as enum (
  'rated',              -- primo voto
  'rating_changed',     -- voto modificato
  'rating_removed',
  'watchlist_added',
  'watchlist_removed',
  'watchlist_status_changed',
  'episode_updated',
  'favorited',
  'unfavorited',
  'commented',
  'joined_group',
  'left_group',
  'achievement_unlocked',
  'tournament_created',
  'tournament_started',
  'tournament_finished',
  'tournament_vote',
  'duel_played'
);

create table public.activities (
  id        uuid primary key default gen_random_uuid(),
  group_id  uuid not null references public.groups (id) on delete cascade,
  user_id   uuid not null references public.profiles (id) on delete cascade,
  type      public.activity_type not null,
  anime_id  uuid references public.anime (id) on delete cascade,

  -- Contesto dell'evento: {score, previous_score, status, episode,
  -- achievement_code, tournament_id, ...}. Chiavi diverse per type diversi.
  metadata  jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now()
);

-- Il feed si legge "dal piu recente", quindi l'indice e in ordine inverso.
create index activities_group_created_idx on public.activities (group_id, created_at desc);
create index activities_user_created_idx  on public.activities (user_id, created_at desc);
create index activities_anime_idx        on public.activities (anime_id);

comment on table public.activities is
  'Feed attivita per gruppo. Popolato da trigger, mai scritto dal client.';

-- ---------------------------------------------------------------------------
-- Helper di scrittura, usato dai trigger
-- ---------------------------------------------------------------------------
-- SECURITY DEFINER perche il trigger gira nel contesto del table owner e i
-- trigger RLS non vengono scattati sulle scritture interne: senza questo,
-- l'attivita non verrebbe mai inserita. Il trigger e gia trusted (eseguito
-- dal database), quindi il ruolo non puo essere sfruttato dall'esterno.
--
-- A PROVA DI CASCATA, e requisito, non un extra. Cancellando un account,
-- profiles -> groups -> ratings si cancellano a cascata; quando scatta
-- activities_on_rating il gruppo e gia sparito e activities.group_id
-- (not null, on delete cascade) farebbe fallire l'intera cancellazione con
-- 23503. Lo stesso vale per activities.user_id quando l'utente e il suo
-- profilo sono in via di rimozione.
--
-- Percio qui si scrive solo se gruppo e utente esistono ancora: durante una
-- cancellazione l'attivita non viene registrata, ed e il comportamento
-- corretto (il feed di un gruppo che sta sparendo non interessa a nessuno).
create or replace function public.log_activity(
  _group_id  uuid,
  _user_id   uuid,
  _type      public.activity_type,
  _anime_id  uuid default null,
  _metadata  jsonb   default '{}'::jsonb
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.activities (group_id, user_id, type, anime_id, metadata)
  select _group_id, _user_id, _type, _anime_id, _metadata
  where exists (select 1 from public.groups g where g.id = _group_id)
    and exists (select 1 from public.profiles p where p.id = _user_id);
$$;

revoke all on function public.log_activity(uuid, uuid, public.activity_type, uuid, jsonb) from public;

-- ---------------------------------------------------------------------------
-- Trigger su ratings
-- ---------------------------------------------------------------------------
create or replace function public.activities_on_rating()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    perform public.log_activity(
      new.group_id, new.user_id, 'rated', new.anime_id,
      jsonb_build_object('score', new.score)
    );

  elsif tg_op = 'UPDATE' then
    -- Solo se il voto e davvero cambiato: un update che tocca solo
    -- updated_at (per esempio dopo una sync) non deve sporcare il feed.
    if new.score is distinct from old.score then
      perform public.log_activity(
        new.group_id, new.user_id, 'rating_changed', new.anime_id,
        jsonb_build_object(
          'score', new.score,
          'previous_score', old.score
        )
      );
    end if;

  elsif tg_op = 'DELETE' then
    perform public.log_activity(
      old.group_id, old.user_id, 'rating_removed', old.anime_id,
      jsonb_build_object('previous_score', old.score)
    );
  end if;

  return coalesce(new, old);
end;
$$;

create trigger ratings_log_activity
  after insert or update or delete on public.ratings
  for each row execute function public.activities_on_rating();

-- ---------------------------------------------------------------------------
-- Trigger su watchlists
-- ---------------------------------------------------------------------------
create or replace function public.activities_on_watchlist()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    perform public.log_activity(
      new.group_id, new.user_id, 'watchlist_added', new.anime_id,
      jsonb_build_object('status', new.status)
    );

  elsif tg_op = 'UPDATE' then
    if new.is_favorite is distinct from old.is_favorite then
      perform public.log_activity(
        new.group_id, new.user_id,
        case when new.is_favorite then 'favorited' else 'unfavorited' end,
        new.anime_id
      );
    end if;

    if new.status is distinct from old.status then
      perform public.log_activity(
        new.group_id, new.user_id, 'watchlist_status_changed', new.anime_id,
        jsonb_build_object('status', new.status, 'previous_status', old.status)
      );
    elsif new.current_episode is distinct from old.current_episode then
      perform public.log_activity(
        new.group_id, new.user_id, 'episode_updated', new.anime_id,
        jsonb_build_object('episode', new.current_episode)
      );
    end if;

  elsif tg_op = 'DELETE' then
    perform public.log_activity(
      old.group_id, old.user_id, 'watchlist_removed', old.anime_id,
      jsonb_build_object('previous_status', old.status)
    );
  end if;

  return coalesce(new, old);
end;
$$;

create trigger watchlists_log_activity
  after insert or update or delete on public.watchlists
  for each row execute function public.activities_on_watchlist();

-- ---------------------------------------------------------------------------
-- Trigger su comments
-- ---------------------------------------------------------------------------
create or replace function public.activities_on_comment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Solo i commenti radice generano attivita: altrimenti scrivere una
  -- risposta farebbe saltare l'attivita in cima al feed.
  if tg_op = 'INSERT' and new.parent_id is null then
    perform public.log_activity(
      new.group_id, new.user_id, 'commented', new.anime_id,
      jsonb_build_object('comment_id', new.id)
    );
  end if;

  return coalesce(new, old);
end;
$$;

create trigger comments_log_activity
  after insert on public.comments
  for each row execute function public.activities_on_comment();

-- ---------------------------------------------------------------------------
-- RLS: il feed e privato del gruppo
-- ---------------------------------------------------------------------------
alter table public.activities enable row level security;

create policy "activities: lettura ai membri"
  on public.activities for select
  to authenticated
  using (public.is_group_member(group_id));

-- Nessuna INSERT policy: si scrive solo tramite trigger.
-- Nessuna UPDATE/DELETE policy: il feed e append-only.
