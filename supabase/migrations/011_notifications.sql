-- ============================================================================
-- 011 — notifications
-- ============================================================================
-- Notifiche generate da TRIGGER, non dal client: cosi "Marco ha votato il
-- tuo stesso anime" scatta anche se il voto arriva dalla coda offline.
--
-- Nessuna INSERT policy: nessun client puo scrivere notifiche false.
-- L'utente puo solo leggerle e segnarle come lette.
-- ============================================================================

create type public.notification_type as enum (
  'friend_request',
  'friend_accepted',
  'same_anime_rated',
  'rating_changed',
  'rank_changed',
  'new_comment',
  'comment_reply',
  'group_invite',
  'tournament_created',
  'tournament_started',
  'tournament_finished',
  'achievement_unlocked',
  'group_member_joined'
);

create table public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles (id) on delete cascade,
  type       public.notification_type not null,
  title      text not null,
  body       text,
  -- Payload per la navigazione: {anime_id, group_id, tournament_id, ...}.
  data       jsonb not null default '{}'::jsonb,
  -- Se valorizzato, il testo va mascherato finche il dispositivo e bloccato
  -- (sezione 47: niente spoiler/privati nella notifica su lockscreen).
  sensitive  boolean not null default false,

  is_read    boolean not null default false,
  read_at    timestamptz,
  created_at timestamptz not null default now(),

  constraint notifications_read_consistent check (
    (is_read and read_at is not null) or (not is_read and read_at is null)
  )
);

create index notifications_user_created_idx on public.notifications (user_id, created_at desc);
create index notifications_unread_idx     on public.notifications (user_id) where not is_read;

comment on table public.notifications is
  'Notifiche in-app. sensitive=true viene mascherata sul lockscreen.';

-- ---------------------------------------------------------------------------
-- Helper di scrittura (solo trigger)
-- ---------------------------------------------------------------------------
create or replace function public.notify_user(
  _user_id uuid,
  _type    public.notification_type,
  _title   text,
  _body    text default null,
  _data    jsonb   default '{}'::jsonb,
  _sensitive boolean default false
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.notifications (user_id, type, title, body, data, sensitive)
  select _user_id, _type, _title, _body, _data, _sensitive
   where _user_id is not null
     -- Rispetta le preferenze dell'utente (profilo.notify_*).
     -- notify_* non filtrano il tipo singolo ma la categoria; per i voti
     -- usiamo notify_votes, per le amicizie notify_friends, ecc.
     and case
           when _type in ('same_anime_rated', 'rating_changed', 'rank_changed')
             then (select notify_votes from public.profiles where id = _user_id)
           when _type in ('friend_request', 'friend_accepted')
             then (select notify_friends from public.profiles where id = _user_id)
           when _type in ('tournament_created', 'tournament_started', 'tournament_finished')
             then (select notify_tournaments from public.profiles where id = _user_id)
           when _type = 'achievement_unlocked'
             then (select notify_push from public.profiles where id = _user_id)
           else true
         end;
$$;

revoke all on function public.notify_user(uuid, public.notification_type, text, text, jsonb, boolean) from public;

-- ---------------------------------------------------------------------------
-- "Marco ha votato il tuo stesso anime!"
-- ---------------------------------------------------------------------------
-- Notifica tutti i membri del gruppo che avevano gia votato quell'anime.
-- Antispam: massimo una notifica per (destinatario, anime) ogni 6 ore,
-- altrimenti un anime molto votato genera 50 notifiche identiche.
create or replace function public.notify_same_anime_rated()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op <> 'INSERT' then
    return new;
  end if;

  perform public.notify_user(
    p.id,
    'same_anime_rated',
    'Nuovo voto sullo stesso anime',
    p.username || ' ha votato un anime che hai votato anche tu.',
    jsonb_build_object('anime_id', new.anime_id, 'group_id', new.group_id, 'by', new.user_id),
    true  -- sensitive: non mostrare il titolo su lockscreen
  )
  from public.profiles p
  where p.id in (
          -- Membri del gruppo che hanno gia votato questo anime, meno chi ha votato ora.
          select r.user_id
            from public.ratings r
           where r.group_id = new.group_id
             and r.anime_id  = new.anime_id
             and r.user_id  <> new.user_id
        )
    and not exists (
          select 1 from public.notifications n
           where n.user_id = p.id
             and n.type = 'same_anime_rated'
             and n.data ->> 'anime_id' = new.anime_id::text
             and n.created_at > now() - interval '6 hours'
        );

  return new;
end;
$$;

create trigger ratings_notify_same_anime
  after insert on public.ratings
  for each row execute function public.notify_same_anime_rated();

-- ---------------------------------------------------------------------------
-- Richieste di amicizia
-- ---------------------------------------------------------------------------
create or replace function public.notify_friend_request()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' and new.status = 'pending' then
    perform public.notify_user(
      new.receiver_id,
      'friend_request',
      'Nuova richiesta di amicizia',
      (select username from public.profiles where id = new.requester_id)
        || ' vuole aggiungerti come amico.',
      jsonb_build_object('from_user_id', new.requester_id, 'friendship_id', new.id),
      false
    );

  elsif tg_op = 'UPDATE' and new.status = 'accepted' then
    perform public.notify_user(
      new.requester_id,
      'friend_accepted',
      'Richiesta accettata',
      (select username from public.profiles where id = new.receiver_id)
        || ' ha accettato la tua richiesta.',
      jsonb_build_object('from_user_id', new.receiver_id, 'friendship_id', new.id),
      false
    );
  end if;

  return coalesce(new, old);
end;
$$;

create trigger friendships_notify
  after insert or update on public.friendships
  for each row execute function public.notify_friend_request();

-- ---------------------------------------------------------------------------
-- Risposte ai commenti
-- ---------------------------------------------------------------------------
create or replace function public.notify_comment_reply()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_parent_author uuid;
begin
  if new.parent_id is null then
    return new;
  end if;

  select user_id into v_parent_author
    from public.comments
   where id = new.parent_id;

  if v_parent_author is not null and v_parent_author <> new.user_id then
    perform public.notify_user(
      v_parent_author,
      'comment_reply',
      'Risposta al tuo commento',
      (select username from public.profiles where id = new.user_id)
        || ' ha risposto a un tuo commento.',
      jsonb_build_object(
        'anime_id', new.anime_id,
        'group_id', new.group_id,
        'comment_id', new.id
      ),
      true
    );
  end if;

  return new;
end;
$$;

create trigger comments_notify_reply
  after insert on public.comments
  for each row execute function public.notify_comment_reply();

-- ---------------------------------------------------------------------------
-- RLS: le notifiche sono strettamente personali
-- ---------------------------------------------------------------------------
alter table public.notifications enable row level security;

create policy "notifications: lettura delle proprie"
  on public.notifications for select
  to authenticated
  using (user_id = (select auth.uid()));

create policy "notifications: segna come letta"
  on public.notifications for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- Nessuna DELETE: si tiene lo storico. Nessuna INSERT: vedi sopra.
