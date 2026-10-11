-- ============================================================================
-- recommendations (2/2) - "Consiglia anime" a un gruppo o a una persona
-- ============================================================================
-- Un consiglio e' un evento con un autore, un possibile destinatario e un
-- messaggio:
--
--   - `to_user_id IS NULL`  -> consiglio "a tutti" i membri del gruppo.
--   - `to_user_id IS NOT NULL` -> consiglio "a una persona".
--
-- In entrambi i casi l'anime entra nella watchlist CONDIVISA del gruppo
-- (`public.watchlists`), cosi' compare in "Consigliata da tutti". Il messaggio
-- viaggia con la riga (`watchlists.message`) ed e' quello che si legge sotto
-- la voce.
--
-- Perche' una tabella a parte e non solo `watchlists`:
--   - `watchlists` dice "questo anime e' nella lista del gruppo", non "chi l'ha
--     consigliato a chi". Il destinatario e il messaggio del consiglio sono un
--     fatto diverso e vanno conservati anche se la riga di watchlist cambia.
--   - Tenere i consigli a parte permette l'antispam (vedi trigger) e, in
--     futuro, un "consigliati per te".
--
-- Notifiche: il consiglio "a persona" genera UNA notifica personale. Il
-- consiglio "a tutti" NON manda notifiche a raffica: l'aggiunta alla watchlist
-- di gruppo scrive gia' una voce nel feed attivita' (trigger della 009).
--
-- Richiede la 20261011160000_recommendations_setup (enum + colonne).
-- ============================================================================

create table if not exists public.anime_recommendations (
  id           uuid primary key default gen_random_uuid(),

  group_id     uuid not null references public.groups    (id) on delete cascade,
  from_user_id uuid not null references public.profiles  (id) on delete cascade,

  -- NULL = consiglio a tutto il gruppo.
  to_user_id   uuid references public.profiles (id) on delete cascade,

  anime_id     uuid not null references public.anime (id) on delete cascade,
  message      text,
  created_at   timestamptz not null default now(),

  constraint anime_recommendations_message_length
    check (message is null or char_length(message) <= 500),

  -- Non ci si consiglia un anime da soli.
  constraint anime_recommendations_not_self
    check (to_user_id is null or to_user_id <> from_user_id)
);

create index if not exists anime_recommendations_group_idx
  on public.anime_recommendations (group_id, created_at desc);
create index if not exists anime_recommendations_to_idx
  on public.anime_recommendations (to_user_id) where to_user_id is not null;
create index if not exists anime_recommendations_anime_idx
  on public.anime_recommendations (anime_id);

comment on table public.anime_recommendations is
  'Consigli di visione: a un gruppo intero (to_user_id null) o a una persona.';

-- ---------------------------------------------------------------------------
-- RLS: i membri del gruppo leggono; si inserisce solo a proprio nome
-- ---------------------------------------------------------------------------
alter table public.anime_recommendations enable row level security;

create policy "anime_recommendations: lettura ai membri"
  on public.anime_recommendations for select
  to authenticated
  using (public.is_group_member(group_id));

create policy "anime_recommendations: inserimento proprio nel gruppo"
  on public.anime_recommendations for insert
  to authenticated
  with check (
    from_user_id = (select auth.uid())
    and public.is_group_member(group_id)
    -- Il destinatario, quando c'e', deve far parte dello stesso gruppo.
    and (
      to_user_id is null
      or exists (
        select 1 from public.group_members gm
         where gm.group_id = anime_recommendations.group_id
           and gm.user_id  = anime_recommendations.to_user_id
      )
    )
  );

-- Difesa in profondita': anon non tocca la tabella.
revoke all on public.anime_recommendations from anon;

-- ---------------------------------------------------------------------------
-- Trigger: il consiglio entra nella watchlist di gruppo (con messaggio) e
-- notifica il destinatario se e' "a persona".
-- ---------------------------------------------------------------------------
create or replace function public.handle_anime_recommendation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_from_name   text;
  v_anime_title text;
begin
  -- 1. L'anime entra nella watchlist condivisa dell'autore. Se c'era gia',
  --    non ne cambia lo stato: aggiorna solo il messaggio, e solo se nuovo
  --    (un consiglio senza testo non cancella quello precedente).
  insert into public.watchlists (group_id, user_id, anime_id, status, message)
  values (new.group_id, new.from_user_id, new.anime_id, 'planned', new.message)
  on conflict (group_id, user_id, anime_id)
  do update set message = coalesce(excluded.message, public.watchlists.message);

  -- 2. Consiglio "a tutti": nessuna notifica personale. L'aggiunta alla
  --    watchlist di gruppo ha gia' scritto una voce nel feed attivita.
  if new.to_user_id is null then
    return new;
  end if;

  -- 3. Consiglio "a persona": antispam (stesso autore -> stesso destinatario
  --    -> stesso anime nelle ultime 24 ore) e poi notifica.
  if exists (
    select 1
      from public.notifications n
     where n.user_id = new.to_user_id
       and n.type    = 'anime_recommended'
       and n.data ->> 'anime_id'     = new.anime_id::text
       and n.data ->> 'from_user_id' = new.from_user_id::text
       and n.created_at > now() - interval '24 hours'
  ) then
    return new;
  end if;

  select username                  into v_from_name   from public.profiles where id = new.from_user_id;
  select coalesce(title_it, title) into v_anime_title from public.anime    where id = new.anime_id;

  perform public.notify_user(
    new.to_user_id,
    'anime_recommended',
    'Un consiglio per te',
    v_from_name || ' ti ha consigliato di vedere: ' || v_anime_title
      || case
           when new.message is not null and new.message <> ''
             then chr(10) || new.message
           else ''
         end,
    jsonb_build_object(
      'anime_id',     new.anime_id,
      'group_id',     new.group_id,
      'from_user_id', new.from_user_id
    ),
    false
  );

  return new;
end;
$$;

create trigger anime_recommendations_apply
  after insert on public.anime_recommendations
  for each row execute function public.handle_anime_recommendation();

-- ---------------------------------------------------------------------------
-- notify_user: nuovo ramo per i consigli (rispetta notify_recommendations)
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
           when _type = 'anime_recommended'
             then (select notify_recommendations from public.profiles where id = _user_id)
           when _type = 'achievement_unlocked'
             then (select notify_push from public.profiles where id = _user_id)
           else true
         end;
$$;

revoke all on function public.notify_user(uuid, public.notification_type, text, text, jsonb, boolean) from public;
