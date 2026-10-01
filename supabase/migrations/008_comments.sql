-- ============================================================================
-- 008 — comments (con risposte e spoiler)
-- ============================================================================
-- Le risposte sono righe nella stessa tabella con parent_id valorizzato:
-- un solo schema, una sola policy da mantenere.
-- parent_id ON DELETE CASCADE: se il commento radice viene eliminato sparisce
-- anche il ramo di risposte, senza lasciare orfani.
-- ============================================================================

create table public.comments (
  id         uuid primary key default gen_random_uuid(),

  group_id   uuid not null references public.groups (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  anime_id   uuid not null references public.anime   (id) on delete cascade,
  parent_id  uuid references public.comments (id) on delete cascade,

  content    text not null,
  is_spoiler boolean not null default false,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint comments_content_not_blank check (char_length(btrim(content)) > 0),
  -- 4000 caratteri: abbondante per un commento, abbastanza corto da non
  -- diventare un vettore di abusi. Validato anche lato client.
  constraint comments_content_length check (char_length(content) <= 4000),
  -- Un commento non puo essere risposta di se stesso.
  constraint comments_not_own_parent check (parent_id is null or parent_id <> id)
);

create index comments_group_anime_idx on public.comments (group_id, anime_id, created_at desc);
create index comments_user_idx        on public.comments (user_id);
create index comments_parent_idx      on public.comments (parent_id) where parent_id is not null;
create index comments_created_idx     on public.comments (created_at desc);

comment on table public.comments is
  'Commenti e risposte. Visibili solo ai membri del gruppo. is_spoiler nasconde il testo al client.';

create trigger comments_set_updated_at
  before update on public.comments
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Coerenza delle risposte
-- ---------------------------------------------------------------------------
-- Una risposta deve appartenere allo stesso gruppo e allo stesso anime del
-- commento padre. Senza questo controllo si potrebbe iniettare una risposta
-- nel thread di un anime diverso, aggirando la percezione di contesto
-- (e i filtri per gruppo che il client applica alla lista).
-- ---------------------------------------------------------------------------
create or replace function public.check_comment_parent()
returns trigger
language plpgsql
as $$
declare
  v_parent public.comments%rowtype;
begin
  if new.parent_id is null then
    return new;
  end if;

  select * into v_parent from public.comments where id = new.parent_id;

  if v_parent.id is null then
    raise exception 'Commento padre inesistente' using errcode = '23503';
  end if;

  if v_parent.group_id <> new.group_id then
    raise exception 'La risposta deve appartenere allo stesso gruppo del commento padre'
      using errcode = '42501';
  end if;

  if v_parent.anime_id <> new.anime_id then
    raise exception 'La risposta deve appartenere allo stesso anime del commento padre'
      using errcode = '42501';
  end if;

  -- Massimo due livelli: root -> risposta. Evita thread infiniti che
  -- il client non sa disegnare senza annidamenti arbitrari.
  if v_parent.parent_id is not null then
    raise exception 'Non e possibile rispondere a una risposta' using errcode = '22023';
  end if;

  return new;
end;
$$;

create trigger comments_check_parent
  before insert or update on public.comments
  for each row execute function public.check_comment_parent();

-- ---------------------------------------------------------------------------
-- RLS: commenti visibili ai soli membri del gruppo
-- ---------------------------------------------------------------------------
alter table public.comments enable row level security;

create policy "comments: lettura ai membri"
  on public.comments for select
  to authenticated
  using (public.is_group_member(group_id));

create policy "comments: inserimento proprio da membro"
  on public.comments for insert
  to authenticated
  with check (
    user_id = (select auth.uid())
    and public.is_group_member(group_id)
  );

create policy "comments: modifica propria"
  on public.comments for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- Ognuno cancella i propri commenti; l'admin pulisce quelli del gruppo.
create policy "comments: eliminazione propria o da admin"
  on public.comments for delete
  to authenticated
  using (
    user_id = (select auth.uid())
    or public.is_group_admin(group_id)
  );
