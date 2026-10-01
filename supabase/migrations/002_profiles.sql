-- ============================================================================
-- 002 — profiles
-- ============================================================================
-- Riga 1:1 con auth.users. L'id e la stessa chiave primaria di auth.users,
-- quindi non c'e una foreign key separata da mantenere allineata a mano.
-- La password NON e mai in questa tabella: vive solo in auth.users, gestita
-- da Supabase Auth (bcrypt/argon2 lato server, mai dal client).
-- ============================================================================

create table public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,

  username     text not null,
  avatar_url   text,
  bio          text,

  -- Preferenze (sezione 35/27/53: tema e notifiche disattivabili)
  theme                text not null default 'dark'
                             check (theme in ('dark', 'light', 'system')),
  notify_push          boolean not null default true,
  notify_votes         boolean not null default true,
  notify_friends       boolean not null default true,
  notify_tournaments   boolean not null default true,
  notify_rank_changes  boolean not null default true,

  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  -- Username: 3-24 caratteri alfanumerici/underscore.
  -- Unicita case-insensitive: "Marco" ed "marco" non possono coesistere.
  constraint profiles_username_format check (
    username ~ '^[A-Za-z0-9_]{3,24}$'
  ),
  constraint profiles_bio_length check (bio is null or char_length(bio) <= 280)
);

create unique index profiles_username_key on public.profiles (lower(username));
create index profiles_username_trgm on public.profiles (username text_pattern_ops);

comment on table public.profiles is
  'Profilo pubblico di un utente. Nessuna password o segreto va memorizzato qui.';

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Creazione profilo alla registrazione
-- ---------------------------------------------------------------------------
-- Se il client passa username in raw_user_meta_data lo usiamo, altrimenti
-- genero 'anon_<8 char id>'. Se lo username richiesto e gia preso, la
-- registrazione NON deve fallire: l'utente resta col suo username generato
-- e potra cambiarlo dalle impostazioni.
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_requested text;
  v_final    text;
  v_nick     text;
begin
  v_requested := nullif(trim(coalesce(new.raw_user_meta_data ->> 'username', '')), '');
  v_nick := regexp_replace(
             coalesce(nullif(split_part(new.email, '@', 1), ''), 'user'),
             '[^A-Za-z0-9_]', '_', 'g');

  -- Il formato ammette 3-24 caratteri: dal prefisso email si tiene un
  -- massimo di 16 cosi' il suffisso numerico entra sempre nel limite.
  v_nick := left(v_nick, 16);

  -- username di fallback derivato dall'id: univoco per costruzione e
  -- sempre conforme al formato 3-24.
  v_final := 'anon_' || substr(replace(new.id::text, '-', ''), 1, 8);

  if v_requested is not null
     and v_requested ~ '^[A-Za-z0-9_]{3,24}$'
     and not exists (select 1 from public.profiles where lower(username) = lower(v_requested))
  then
    v_final := v_requested;
  end if;

  -- Se la richiesta era valida ma lo username e' gia preso, si preferisce
  -- il nickname dall'email e solo in extremis 'anon_...'.
  if v_final = 'anon_' || substr(replace(new.id::text, '-', ''), 1, 8)
     and v_nick ~ '^[A-Za-z0-9_]{3,24}$'
     and not exists (select 1 from public.profiles where lower(username) = lower(v_nick))
  then
    v_final := v_nick;
  end if;

  -- username e' NOT NULL: va deciso PRIMA dell'insert, altrimenti il trigger
  -- fallirebbe e la registrazione non andrebbe a buon fine.
  insert into public.profiles (id, username, avatar_url)
  values (new.id, v_final, new.raw_user_meta_data ->> 'avatar_url')
  on conflict (id) do nothing;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Username non piu modificabile dopo la prima settimana: evita che un utente
-- accumuli "reputazione" e poi venda/ceda l'account.
-- ---------------------------------------------------------------------------
create or replace function public.check_username_lock()
returns trigger
language plpgsql
as $$
begin
  if old.username is distinct from new.username
     and old.created_at < now() - interval '7 days'
  then
    raise exception 'Username modificabile solo entro 7 giorni dalla registrazione'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger profiles_username_lock
  before update on public.profiles
  for each row execute function public.check_username_lock();

-- ---------------------------------------------------------------------------
-- RLS: il profilo e visibile a tutti gli autenticati (serve per mostrare
-- avatar/nome nei voti e nei commenti di altri membri), ma scrivibile
-- solo dal proprio utente.
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;

create policy "profiles: lettura da autenticati"
  on public.profiles for select
  to authenticated
  using (true);

create policy "profiles: inserimento proprio"
  on public.profiles for insert
  to authenticated
  with check (id = (select auth.uid()));

create policy "profiles: modifica propria"
  on public.profiles for update
  to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- Nessuna policy DELETE: la cancellazione avviene tramite
-- "delete account" che elimina l'utente su auth.users (vedi 014).
