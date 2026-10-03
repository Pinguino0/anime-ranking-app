-- ============================================================================
-- 020 — inviti singoli per gruppo
-- ============================================================================
-- Fino a qui un gruppo aveva un solo codice, groups.invite_code: rigenerarlo
-- invalidava il precedente per tutti, quindi non si poteva dare un accesso a
-- qualcuno senza chiudere la porta a chi lo aveva gia' ricevuto.
--
-- Questa migrazione aggiunge inviti singoli, ognuno con scadenza propria e con
-- traccia di chi lo ha usato. Il codice del gruppo resta e continua a
-- funzionare: join_group accetta entrambi, quindi nessuna schermata esistente
-- smette di funzionare.
--
-- Punto delicato: chi puo' vedere gli inviti. Un codice invito e una password
-- per il gruppo, quindi la lista la leggono solo gli admin, anche se il
-- members semplice puo' vedere groups.invite_code. La tabella ha la RLS
-- attiva senza policy: ogni accesso passa dalle funzioni SECURITY DEFINER,
-- che ricontrollano il ruolo. Una policy di SELECT per i membri avrebbe
-- consegnato a tutti i codici degli inviti pendenti.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- group_invites
-- ---------------------------------------------------------------------------
create table public.group_invites (
  id          uuid primary key default gen_random_uuid(),
  group_id    uuid not null references public.groups (id) on delete cascade,
  code        text not null,
  created_by  uuid not null references public.profiles (id) on delete cascade,
  expires_at  timestamptz not null default (now() + interval '7 days'),
  used_by     uuid references public.profiles (id) on delete set null,
  used_at     timestamptz,
  revoked_at  timestamptz,
  created_at  timestamptz not null default now(),

  constraint group_invites_code_length check (
    char_length(btrim(code)) between 4 and 40
  ),
  -- Un invito non puo' essere usato due volte: il vincolo e sul codice, cosi'
  -- la concorrenza e' gestita dal database. Se due utenti aprono lo stesso
  -- invito insieme, uno riceve il codice 'unique violation' invece di entrare
  -- entrambi in un posto pensato per una persona sola.
  constraint group_invites_code_unique unique (code),
  -- Un invito usato non puo' anche essere revocato, e viceversa: le due date
  -- descrivono lo stesso stato terminale e tenere entrambe vuoti direbbe
  -- "annullato per due motivi" senza dirlo.
  constraint group_invites_not_used_and_revoked check (
    used_at is null or revoked_at is null
  )
);

-- Indice solo sugli inviti ancora spendibili: la ricerca di join_group
-- filtra su usato/revocato/scadenza, e gli inviti consumati sono la maggior
-- parte della tabella. Indicizzarli tutti costerebbe spazio per niente.
create index group_invites_active_idx
  on public.group_invites (code, expires_at)
  where used_at is null and revoked_at is null;

create index group_invites_group_idx on public.group_invites (group_id, created_at desc);

comment on table public.group_invites is
  'Inviti singoli per entrare in un gruppo, con scadenza e uso tracciati.';

comment on column public.group_invites.used_by is
  'Chi ha usato l''invito. NULL se non e'' stato ancora usato.';

-- ---------------------------------------------------------------------------
-- generate_invite_code: controlla anche gli inviti singoli
-- ---------------------------------------------------------------------------
-- La funzione esiste dal 001 e finora confrontava il codice solo con
-- groups.invite_code. Da qui in poi lo stesso codice vive in due tabelle e
-- join_group le cerca entrambe: senza questo confronto un codice generato per
-- un invito puo' coincidere con il codice di un altro gruppo, e chi lo digita
-- entra nel gruppo sbagliato invece che in quello a cui era stato invitato.
--
-- Stessa firma, quindi i chiamanti esistenti (default della tabella groups e
-- regenerate_invite_code) continuano a funzionare senza modifiche.
create or replace function public.generate_invite_code()
returns text
language plpgsql
volatile
set search_path = public
as $$
declare
  v_code  text;
  v_tries int := 0;
begin
  loop
    -- 5 caratteri alfanumerici maiuscoli, evitando 0/O/1/I per leggibilita
    v_code := 'ANIME-' || upper(substr(
      translate(
        md5(gen_random_uuid()::text),
        'abcdefghijklmnopqrstuvwxyz0123456789',
        'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
      ), 1, 5));

    v_tries := v_tries + 1;

    exit when not exists (
      select 1 from public.groups
       where invite_code = v_code
    ) and not exists (
      select 1 from public.group_invites
       where code = v_code
    );

    -- La versione precedente usciva dal ciclo dopo 20 tentativi e restituiva
    -- lo stesso codice di prima, cioe' un codice gia' assegnato: si sarebbe
    -- sovrapposto a un gruppo esistente. Fallire e' preferibile, e con 5
    -- caratteri a 32 alfabeto la probabilita' di arrivare a 20 tentativi e'
-- trascurabile.
    if v_tries > 20 then
      raise exception 'Impossibile generare un codice invito univoco'
        using errcode = '40001';
    end if;
  end loop;

  return v_code;
end;
$$;

-- ---------------------------------------------------------------------------
-- create_group_invite: crea un invito con scadenza (solo admin/owner)
-- ---------------------------------------------------------------------------
create or replace function public.create_group_invite(
  _group_id   uuid,
  _days_valid integer default 7
)
returns public.group_invites
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_row   public.group_invites;
  v_days  integer := coalesce(_days_valid, 7);
begin
  if v_uid is null then
    raise exception 'Autenticazione richiesta' using errcode = '28000';
  end if;

  if not public.is_group_admin(_group_id) then
    raise exception 'Permessi insufficienti' using errcode = '42501';
  end if;

  -- Limite superiore: senza, un _days_valid enorme produrrebbe un invito che
  -- non scade mai, cioe' il gruppo del codice permanente ma senza il vantaggio
  -- di poterlo revocare dalla lista.
  if v_days < 1 or v_days > 30 then
    raise exception 'La scadenza deve essere fra 1 e 30 giorni' using errcode = '22023';
  end if;

  insert into public.group_invites (group_id, code, created_by, expires_at)
  values (
    _group_id,
    upper(public.generate_invite_code()),
    v_uid,
    now() + make_interval(days => v_days)
  )
  returning * into v_row;

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- list_group_invites: inviti del gruppo (solo admin/owner)
-- ---------------------------------------------------------------------------
-- pending: true  scadenza futura, non usato, non revocato
--         false gia' scaduto, usato o revocato
--         null  scaduto da meno di 7 giorni, quindi ancora mostrato per
--              capire che cosa e' successo invece di sparire dal nulla
create or replace function public.list_group_invites(_group_id uuid)
returns table (
  id          uuid,
  code        text,
  created_by  uuid,
  expires_at  timestamptz,
  used_by     uuid,
  used_at     timestamptz,
  revoked_at  timestamptz,
  created_at  timestamptz,
  pending     boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_group_admin(_group_id) then
    raise exception 'Permessi insufficienti' using errcode = '42501';
  end if;

  return query
    select
      i.id,
      i.code,
      i.created_by,
      i.expires_at,
      i.used_by,
      i.used_at,
      i.revoked_at,
      i.created_at,
      case
        when i.used_at is not null or i.revoked_at is not null then false
        when i.expires_at <= now()                    then false
        when now() - i.created_at < interval '7 days' then true
        else null
      end as pending
    from public.group_invites i
   where i.group_id = _group_id
     -- Finestra di 7 giorni dopo la scadenza: dopo, l'invito non dice piu'
     -- niente di utile e occuperebbe la lista per sempre.
     and (i.used_at is not null
          or i.revoked_at is not null
          or i.expires_at > now() - interval '7 days')
   order by i.created_at desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- revoke_group_invite: annulla un invito (solo admin/owner)
-- ---------------------------------------------------------------------------
create or replace function public.revoke_group_invite(_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id uuid;
  v_used_at  timestamptz;
begin
  select group_id, used_at
    into v_group_id, v_used_at
    from public.group_invites
   where id = _invite_id;

  -- Id non trovato e non admin si confondono di proposito: dire a un
  -- estraneo che quell'id esiste gli darebbe informazione sul gruppo.
  if v_group_id is null or not public.is_group_admin(v_group_id) then
    raise exception 'Permessi insufficienti' using errcode = '42501';
  end if;

  -- Revocare un invito gia' usato sembrerebbe aver annullato l'accesso concesso,
  -- mentre la persona e' dentro al gruppo. Va detto chiaramente.
  if v_used_at is not null then
    raise exception 'Questo invito e'' gia'' stato usato' using errcode = '22023';
  end if;

  update public.group_invites
     set revoked_at = now()
   where id = _invite_id
     and revoked_at is null
     and used_at is null;
end;
$$;

-- ---------------------------------------------------------------------------
-- join_group: accetta anche i codici degli inviti singoli
-- ---------------------------------------------------------------------------
-- Stessa firma e stesso codice di permessi del 003, quindi i grant di allora
-- restano validi e nessuna schermata cambia comportamento. Prima cerca il
-- codice del gruppo, poi un invito pendente.
create or replace function public.join_group(_code text)
returns public.groups
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid       uuid := (select auth.uid());
  v_code      text := upper(btrim(_code));
  v_group     public.groups;
  v_invite_id uuid;
begin
  if v_uid is null then
    raise exception 'Autenticazione richiesta' using errcode = '28000';
  end if;

  if v_code is null or v_code = '' then
    raise exception 'Codice invito non valido' using errcode = '22023';
  end if;

  -- 1) codice del gruppo (invariato)
  select * into v_group
    from public.groups
   where invite_code = v_code
   limit 1;

  -- 2) invito singolo ancora spendibile.
  -- Il for update blocca la riga finche' non si decide: due utenti che aprono
  -- lo stesso invito insieme non possono entrare entrambi, altrimenti il
  -- vincolo unique su used_by scatterebbe dopo aver gia' inserito la membership.
  if v_group.id is null then
    select id into v_invite_id
      from public.group_invites
     where code = v_code
       and used_at is null
       and revoked_at is null
       and expires_at > now()
     for update;

    if v_invite_id is null then
      raise exception 'Codice invito non valido' using errcode = '22023';
    end if;

    select * into v_group
      from public.groups
     where id = (select group_id from public.group_invites where id = v_invite_id);

    -- Un admin che entra con il proprio invito consumerebbe l'invito senza
    -- motivo, e il gruppo resterebbe con un buco nella lista. Si registra
    -- l'uso solo se l'invito porta davvero qualcuno di nuovo.
    if v_group.id is not null
       and not exists (
         select 1 from public.group_members
          where group_id = v_group.id and user_id = v_uid
       ) then
      update public.group_invites
         set used_by = v_uid, used_at = now()
       where id = v_invite_id;
    end if;
  end if;

  -- Se gia' membro: ritorna il gruppo senza errori (join idempotente).
  insert into public.group_members (group_id, user_id, role)
  values (v_group.id, v_uid, 'member')
  on conflict (group_id, user_id) do nothing;

  return v_group;
end;
$$;

-- ---------------------------------------------------------------------------
-- Privilegi
-- ---------------------------------------------------------------------------
-- Nessuna policy su group_invites: la RLS attiva senza policy nega tutto e le
-- tre funzioni ci passano sopra come SECURITY DEFINER. La tabella resta quindi
-- irraggiungibile anche a un admin, che usa le funzioni come tutti gli altri.

revoke all on function public.create_group_invite(uuid, integer) from public;
revoke all on function public.list_group_invites(uuid)             from public;
revoke all on function public.revoke_group_invite(uuid)            from public;

grant execute on function public.create_group_invite(uuid, integer) to authenticated;
grant execute on function public.list_group_invites(uuid)             to authenticated;
grant execute on function public.revoke_group_invite(uuid)            to authenticated;

alter table public.group_invites enable row level security;