-- ============================================================================
-- 003 — groups, group_members, ruoli e helper di autorizzazione
-- ============================================================================
-- Punto delicato: la ricorsione RLS.
--
-- Una policy su group_members che chiede "l'utente e membro di questo gruppo?"
-- deve leggere group_members. Applicando RLS a quella stessa tabella si
-- innesca un ciclo infinito (Postgres lo rileva e blocca la query).
--
-- Soluzione: le funzioni is_group_member/is_group_admin sono SECURITY DEFINER,
-- quindi girano con i privilegi del proprietario (postgres) e leggono
-- group_members senza passare per RLS. Non sono pero' utilizzabili dall'
-- esterno per dedurre informazioni: rispondono solo se l'utente corrente
-- appartiene o meno al gruppo indicato.
-- ============================================================================

create type public.group_role as enum ('owner', 'admin', 'member');

-- ---------------------------------------------------------------------------
-- groups
-- ---------------------------------------------------------------------------
create table public.groups (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  description  text,
  image_url    text,
  invite_code  text not null default public.generate_invite_code(),
  owner_id     uuid not null references public.profiles (id) on delete cascade,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  constraint groups_name_length check (char_length(btrim(name)) between 1 and 60),
  constraint groups_description_length check (
    description is null or char_length(description) <= 500
  )
);

create unique index groups_invite_code_key on public.groups (invite_code);
create index groups_owner_idx on public.groups (owner_id);
create index groups_name_idx on public.groups (lower(name));

comment on table public.groups is
  'Gruppo privato di amici. invite_code e condiviso solo fra i membri.';

create trigger groups_set_updated_at
  before update on public.groups
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- group_members
-- ---------------------------------------------------------------------------
create table public.group_members (
  id         uuid primary key default gen_random_uuid(),
  group_id   uuid not null references public.groups (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  role       public.group_role not null default 'member',
  joined_at  timestamptz not null default now(),

  constraint group_members_unique unique (group_id, user_id)
);

create index group_members_group_idx on public.group_members (group_id);
create index group_members_user_idx  on public.group_members (user_id);
create index group_members_role_idx  on public.group_members (group_id, role);

-- ---------------------------------------------------------------------------
-- Funzioni di autorizzazione (vedi nota sulla ricorsione in testa al file)
-- ---------------------------------------------------------------------------
create or replace function public.is_group_member(_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.group_members
     where group_id = _group_id
       and user_id  = (select auth.uid())
  );
$$;

create or replace function public.is_group_admin(_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.group_members
     where group_id = _group_id
       and user_id  = (select auth.uid())
       and role in ('owner', 'admin')
  );
$$;

create or replace function public.is_group_owner(_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.group_members
     where group_id = _group_id
       and user_id  = (select auth.uid())
       and role = 'owner'
  );
$$;

-- Le tre funzioni rispondono solo su auth.uid(): esporle non permette di
-- sondare i dati di altri. Revoke da PUBLIC, grant esplicito ad authenticated.
revoke all on function public.is_group_member(uuid)  from public;
revoke all on function public.is_group_admin(uuid)   from public;
revoke all on function public.is_group_owner(uuid)   from public;
grant execute on function public.is_group_member(uuid) to authenticated;
grant execute on function public.is_group_admin(uuid)  to authenticated;
grant execute on function public.is_group_owner(uuid)  to authenticated;

-- ---------------------------------------------------------------------------
-- Operazioni di gruppo eseguite come RPC atomici
-- ---------------------------------------------------------------------------
-- Sono SECURITY DEFINER perche devono scrivere sia in groups sia in
-- group_members dentro la stessa transazione. Ogni funzione riesegue i
-- controlli di autorizzazione: la RLS non viene ereditata da chi la esegue.

-- crea gruppo + inserisce il creatore come 'owner' in un colpo solo
create or replace function public.create_group(
  _name        text,
  _description text default null,
  _image_url   text default null
)
returns public.groups
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_group public.groups;
begin
  if v_uid is null then
    raise exception 'Autenticazione richiesta' using errcode = '28000';
  end if;

  if char_length(btrim(coalesce(_name, ''))) not between 1 and 60 then
    raise exception 'Nome gruppo non valido (1-60 caratteri)' using errcode = '22023';
  end if;

  insert into public.groups (name, description, image_url, owner_id)
  values (btrim(_name), _description, _image_url, v_uid)
  returning * into v_group;

  insert into public.group_members (group_id, user_id, role)
  values (v_group.id, v_uid, 'owner');

  return v_group;
end;
$$;

-- entra in un gruppo tramite codice invito
create or replace function public.join_group(_code text)
returns public.groups
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_group public.groups;
begin
  if v_uid is null then
    raise exception 'Autenticazione richiesta' using errcode = '28000';
  end if;

  select * into v_group
    from public.groups
   where invite_code = upper(btrim(_code))
   limit 1;

  if v_group.id is null then
    raise exception 'Codice invito non valido' using errcode = '22023';
  end if;

  -- Se gia membro: ritorna il gruppo senza errori (join idempotente).
  insert into public.group_members (group_id, user_id, role)
  values (v_group.id, v_uid, 'member')
  on conflict (group_id, user_id) do nothing;

  return v_group;
end;
$$;

-- uscita dal gruppo. L'owner non puo uscire: deve prima eliminare il gruppo
-- o trasferire la proprieta (vedi transfer_group_ownership in 018).
create or replace function public.leave_group(_group_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  -- Il guard era invertito: "if not is_group_owner" consentiva l'uscita solo
  -- all'owner e la vietava a tutti gli altri, cioe' esattamente il contrario di
  -- quello che dice il commento. L'owner deve prima trasferire la proprieta'
  -- o eliminare il gruppo; gli altri membri escono liberamente.
  if public.is_group_owner(_group_id) then
    raise exception 'Il owner non puo lasciare il gruppo. Trasferisci la proprieta'' o elimina il gruppo.'
      using errcode = '42501';
  end if;

  delete from public.group_members
   where group_id = _group_id and user_id = v_uid;
end;
$$;

-- espulsione di un membro (solo admin/owner). L'owner non e espellibile.
create or replace function public.kick_member(_group_id uuid, _user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_group_admin(_group_id) then
    raise exception 'Permessi insufficienti' using errcode = '42501';
  end if;

  if exists (
    select 1 from public.group_members
     where group_id = _group_id and user_id = _user_id and role = 'owner'
  ) then
    raise exception 'Il owner del gruppo non puo essere espulso' using errcode = '42501';
  end if;

  delete from public.group_members
   where group_id = _group_id and user_id = _user_id;
end;
$$;

-- rigenera il codice invito (solo admin/owner)
create or replace function public.regenerate_invite_code(_group_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
begin
  if not public.is_group_admin(_group_id) then
    raise exception 'Permessi insufficienti' using errcode = '42501';
  end if;

  v_code := public.generate_invite_code();

  update public.groups
     set invite_code = v_code
   where id = _group_id;

  return v_code;
end;
$$;

-- promuove/declassa un membro (solo owner)
create or replace function public.set_member_role(
  _group_id uuid,
  _user_id  uuid,
  _role     public.group_role
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_group_owner(_group_id) then
    raise exception 'Solo il owner puo cambiare i ruoli' using errcode = '42501';
  end if;

  if _role = 'owner' then
    raise exception 'Usa transfer_group_ownership per cedere la proprieta'
      using errcode = '42501';
  end if;

  update public.group_members
     set role = _role
   where group_id = _group_id and user_id = _user_id;
end;
$$;

revoke all on function public.create_group(text, text, text)           from public;
revoke all on function public.join_group(text)                        from public;
revoke all on function public.leave_group(uuid)                        from public;
revoke all on function public.kick_member(uuid, uuid)                  from public;
revoke all on function public.regenerate_invite_code(uuid)            from public;
revoke all on function public.set_member_role(uuid, uuid, public.group_role) from public;

grant execute on function public.create_group(text, text, text)  to authenticated;
grant execute on function public.join_group(text)                 to authenticated;
grant execute on function public.leave_group(uuid)                 to authenticated;
grant execute on function public.kick_member(uuid, uuid)           to authenticated;
grant execute on function public.regenerate_invite_code(uuid)     to authenticated;
grant execute on function public.set_member_role(uuid, uuid, public.group_role) to authenticated;

-- ---------------------------------------------------------------------------
-- RLS groups / group_members
-- ---------------------------------------------------------------------------
alter table public.groups         enable row level security;
alter table public.group_members enable row level security;

-- Un gruppo e leggibile solo dai suoi membri.
-- NB: per existence-check di "cancellazione gruppo" il policy DELETE usa
-- is_group_owner, che e gia filtrato per auth.uid().
create policy "groups: lettura ai membri"
  on public.groups for select
  to authenticated
  using (public.is_group_member(id));

create policy "groups: creazione da autenticati"
  on public.groups for insert
  to authenticated
  with check (owner_id = (select auth.uid()));

create policy "groups: modifica da admin"
  on public.groups for update
  to authenticated
  using (public.is_group_admin(id))
  with check (public.is_group_admin(id));

create policy "groups: eliminazione da owner"
  on public.groups for delete
  to authenticated
  using (public.is_group_owner(id));

-- group_members: lettura ai membri dello stesso gruppo
create policy "group_members: lettura ai membri"
  on public.group_members for select
  to authenticated
  using (public.is_group_member(group_id));

-- Inserimento: o l'utente inserisce se stesso (join), o e admin (promozione
-- da parte dell'owner). NOTA: il percorso normale passa da join_group().
create policy "group_members: inserimento se stesso o admin"
  on public.group_members for insert
  to authenticated
  with check (
    user_id = (select auth.uid())
    or public.is_group_admin(group_id)
  );

-- Modifica ruolo: solo admin. Ma nessuno puo auto-promuoversi a owner:
-- il check sul nuovo valore vieta che il chiamante sia owner senza esserlo
-- gia, e is_group_owner impedisce il self-escalation.
create policy "group_members: modifica ruolo da admin"
  on public.group_members for update
  to authenticated
  using (public.is_group_admin(group_id))
  with check (
    role <> 'owner'
    or user_id <> (select auth.uid())
    or public.is_group_owner(group_id)
  );

-- Uscita volontaria o espulsione. L'owner non puo uscire ne essere espulso.
create policy "group_members: uscita o espulsione"
  on public.group_members for delete
  to authenticated
  using (
    user_id = (select auth.uid()) and not public.is_group_owner(group_id)
    or public.is_group_admin(group_id)
  );
