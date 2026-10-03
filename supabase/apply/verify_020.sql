-- ============================================================================
-- Verifica funzionale della migration 020 (inviti singoli)
-- ============================================================================
-- Da usare DOPO che 020 e' stata applicata. Crea un gruppo con tre ruoli,
-- esercita creazione, uso, revoca, scadenza e uso singolo, poi rimuove tutto
-- in rollback. E' uno script di test, non una migration.
--
-- Come si simula l'utente collegato
-- -------------------------------
-- Le funzioni di gruppo leggono auth.uid(), che in uno script SQL e' NULL: senza
-- accorgersene ogni chiamata fallirebbe con "Autenticazione richiesta" e il
-- test passerebbe (o fallirebbe) per il motivo sbagliato. Per questo il ruolo
-- viene impostato a mano con set local request.jwt.claims prima di ogni gruppo
-- di prove.
--
-- Cosa non viene provato qui
-- -------------------------
-- I GRANT e le policy RLS. Qui si gira con i privilegi del proprietario del
-- database, quindi una funzione eseguibile solo da service_role passerebbe
-- senza problemi. Per quello c'e' check_privileges.ps1, che interroga
-- has_function_privilege e le policy sul database gia' applicato.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- La FK profiles.id -> auth.users
-- ---------------------------------------------------------------------------
-- profiles.id referenzia auth.users(id) e questo script non crea utenti in
-- auth.users: inserirebbe profili fittizi che non hanno un utente dietro e la FK
-- lo rifiuterebbe. Creare utenti veri richiederebbe toccare auth.users con una
-- decina di colonne obbligatorie, ed e' una prova sul database di produzione.
--
-- Tolgo quindi il vincolo qui dentro, dentro la transizione: il rollback in
-- fondo al file lo ripristina esattamente com'era. Il nome del constraint non e'
-- scritto per esteso perche' quello di default cambia se la tabella viene
-- recreata: lo cerco per destinazione.
do $$
declare c record;
begin
  for c in
    select conname
      from pg_constraint
     where conrelid = 'public.profiles'::regclass
       and contype = 'f'
       and confrelid = 'auth.users'::regclass
  loop
    execute format('alter table public.profiles drop constraint %I', c.conname);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Impostazione dei ruoli
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

-- Passa al ruolo indicato per le prove successive.
--
-- Nota: le righe di prova vanno create PRIMA di cambiare identita', altrimenti
-- l'inserimento viene valutato con le RLS del nuovo utente e il gruppo non
-- esiste piu' quando arrivano le chiamate alle funzioni.
create or replace function pg_temp.test_020_as(_uid uuid)
returns void language plpgsql as $$
begin
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', _uid::text, 'role', 'authenticated')::text,
    true
  );
  -- `sub` come claim singolo: le installazioni Supabase piu' vecchie lo
  -- leggono da request.jwt.claim.sub e non dal json, quindi vanno impostati
  -- entrambi per non dipendere dalla versione.
  perform set_config('request.jwt.claim.sub', _uid::text, true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Dati di prova
-- ---------------------------------------------------------------------------
-- Solo id e username: profiles ha anche avatar_url e bio, ma non ha
-- display_name. La colonna non e' mai esistita in nessuna migration.
insert into public.profiles (id, username)
values
  ('11111111-1111-1111-1111-111111111111', 'test_owner_020'),
  ('22222222-2222-2222-2222-222222222222', 'test_admin_020'),
  ('33333333-3333-3333-3333-333333333333', 'test_member_020')
on conflict (id) do nothing;

insert into public.groups (id, name, owner_id, invite_code)
values (
  '44444444-4444-4444-4444-444444444444',
  'Gruppo inviti 020',
  '11111111-1111-1111-1111-111111111111',
  'TEST020GROUP'
)
on conflict (id) do nothing;

insert into public.group_members (group_id, user_id, role)
values
  ('44444444-4444-4444-4444-444444444444', '11111111-1111-1111-1111-111111111111', 'owner'),
  ('44444444-4444-4444-4444-444444444444', '22222222-2222-2222-2222-222222222222', 'admin'),
  ('44444444-4444-4444-4444-444444444444', '33333333-3333-3333-3333-333333333333', 'member')
on conflict (group_id, user_id) do nothing;

-- ---------------------------------------------------------------------------
-- group_invites non e' scrivibile dal ruolo autenticato
-- ---------------------------------------------------------------------------
-- La tabella non ha policy: ogni accesso passa dalle funzioni SECURITY DEFINER.
-- Se questa assert fallisce, qualcuno ha aggiunto una policy che apre la
-- scrittura diretta e i codici invito diventano scrivibili dal client.
do $$
begin
  if has_table_privilege('authenticated', 'public.group_invites', 'INSERT') then
    raise exception 'FALLITO: authenticated puo scrivere direttamente su group_invites';
  end if;
  raise notice 'OK: group_invites non scrivibile direttamente';
end;
$$;

-- ---------------------------------------------------------------------------
-- Limiti sulla validita'
-- ---------------------------------------------------------------------------
-- Da 1 a 30 giorni. Fuori dai limiti deve fallire: senza controllo un valore
-- enorme produrrebbe un invito che non scade mai, cioe' un accesso permanente
-- che sembra scadere.
do $$
declare
  v_owner constant uuid := '11111111-1111-1111-1111-111111111111';
  v_grp   constant uuid := '44444444-4444-4444-4444-444444444444';
  v_id    uuid;
begin
  perform pg_temp.test_020_as(v_owner);

  select id into v_id from public.create_group_invite(v_grp, 7);
  if v_id is null then
    raise exception 'FALLITO: invito non creato';
  end if;
  raise notice 'OK: invito creato con 7 giorni';

  begin
    perform public.create_group_invite(v_grp, 0);
    raise exception 'FALLITO: 0 giorni accettato';
exception
  when others then
    if sqlerrm like 'FALLITO%' then raise; end if;
    raise notice 'OK: 0 giorni rifiutato';
  end;

  begin
    perform public.create_group_invite(v_grp, 365);
    raise exception 'FALLITO: 365 giorni accettato';
exception
  when others then
    if sqlerrm like 'FALLITO%' then raise; end if;
    raise notice 'OK: 365 giorni rifiutato';
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- Un codice invito non puo' coincidere con un codice gruppo
-- ---------------------------------------------------------------------------
-- join_group cerca il codice prima fra i gruppi e poi fra gli inviti: se un
-- codice di invito coincidesse con quello di un gruppo, chi lo digita entrarebbe
-- nel gruppo sbagliato. E' il motivo per cui generate_invite_code e' stata
-- riscritta per confrontare le due tabelle.
do $$
declare
  v_owner constant uuid := '11111111-1111-1111-1111-111111111111';
  v_grp   constant uuid := '44444444-4444-4444-4444-444444444444';
  v_code  text;
  v_clash integer;
begin
  perform pg_temp.test_020_as(v_owner);

  select code into v_code from public.create_group_invite(v_grp, 7);

  select count(*) into v_clash
    from public.groups where invite_code = v_code;
  if v_clash <> 0 then
    raise exception 'FALLITO: il codice dell''invito coincide con un codice gruppo';
  end if;
  raise notice 'OK: il codice dell''invito non coincide con alcun codice gruppo';
end;
$$;

-- ---------------------------------------------------------------------------
-- Solo gli admin creano inviti
-- ---------------------------------------------------------------------------
-- Regola che conta piu' di tutte: un membro semplice che riuscisse a creare
-- un invito potrebbe far entrare chiunque nel gruppo.
do $$
declare
  v_grp constant uuid := '44444444-4444-4444-4444-444444444444';
begin
  perform pg_temp.test_020_as('33333333-3333-3333-3333-333333333333');
  begin
    perform public.create_group_invite(v_grp, 7);
    raise exception 'FALLITO: un membro semplice ha creato un invito';
exception
  when others then
    if sqlerrm like 'FALLITO%' then raise; end if;
    raise notice 'OK: membro semplice non puo creare inviti';
  end;

  perform pg_temp.test_020_as('22222222-2222-2222-2222-222222222222');
  perform public.create_group_invite(v_grp, 7);
  raise notice 'OK: un admin puo creare inviti';
end;
$$;

-- ---------------------------------------------------------------------------
-- Join: il codice del gruppo non si e' rotto
-- ---------------------------------------------------------------------------
-- Regressione. La 020 ha riscritto join_group per accettare anche gli inviti:
-- se il percorso vecchio si fosse rotto, tutti i gruppi gia' esistenti
-- diventerebbero irraggiungibili dal codice che hanno gia' distribuito.
do $$
begin
  perform pg_temp.test_020_as('33333333-3333-3333-3333-333333333333');
  perform public.join_group('TEST020GROUP');
  raise notice 'OK: join col codice del gruppo funziona';
end;
$$;

-- ---------------------------------------------------------------------------
-- Lista: finestra di 7 giorni e marcatura pending
-- ---------------------------------------------------------------------------
insert into public.group_invites (group_id, code, created_by, expires_at)
values
  ('44444444-4444-4444-4444-444444444444', 'PEND020',
   '11111111-1111-1111-1111-111111111111', now() + interval '5 days'),
  ('44444444-4444-4444-4444-444444444444', 'USED020',
   '11111111-1111-1111-1111-111111111111', now() + interval '5 days'),
  ('44444444-4444-4444-4444-444444444444', 'SCAD020',
   '11111111-1111-1111-1111-111111111111', now() - interval '2 days'),
  ('44444444-4444-4444-4444-444444444444', 'OLD020',
   '11111111-1111-1111-1111-111111111111', now() - interval '30 days'),
  --FRESH020 resta spendibile fino all'ultima prova: PEND020 viene revocato
  -- prima, e riusarlo mostrerebbe solo l'errore della revoca, non quello che si
  -- vuole provare.
  ('44444444-4444-4444-4444-444444444444', 'FRESH020',
   '11111111-1111-1111-1111-111111111111', now() + interval '5 days');

update public.group_invites
   set used_by = '33333333-3333-3333-3333-333333333333',
       used_at = now() - interval '1 hour'
 where code = 'USED020';

do $$
declare
  v_grp     constant uuid := '44444444-4444-4444-4444-444444444444';
  v_listed  integer;
  v_pending boolean;
begin
  perform pg_temp.test_020_as('11111111-1111-1111-1111-111111111111');

  -- Scaduto da 30 giorni: oltre la finestra, non deve comparire piu'. Una lista
  -- che cresce per sempre e' una lista che nessuno legge piu'.
  select count(*) into v_listed
    from public.list_group_invites(v_grp) where code = 'OLD020';
  if v_listed <> 0 then
    raise exception 'FALLITO: invito vecchio ancora in lista';
  end if;
  raise notice 'OK: invito vecchio non compare in lista';

  select pending into v_pending
    from public.list_group_invites(v_grp) where code = 'PEND020';
  if v_pending is not true then
    raise exception 'FALLITO: invito pendente non marcato true';
  end if;
  raise notice 'OK: invito pendente marcato true';

  -- Scaduto da 2 giorni: ancora mostrato (finestra 7 giorni) ma non spendibile.
  select pending into v_pending
    from public.list_group_invites(v_grp) where code = 'SCAD020';
  if v_pending is not false then
    raise exception 'FALLITO: invito scaduto non marcato false';
  end if;
  raise notice 'OK: invito scaduto marcato false';

  select pending into v_pending
    from public.list_group_invites(v_grp) where code = 'USED020';
  if v_pending is not false then
    raise exception 'FALLITO: invito usato non marcato false';
  end if;
  raise notice 'OK: invito usato marcato false';
end;
$$;

-- ---------------------------------------------------------------------------
-- Solo gli admin vedono gli inviti
-- ---------------------------------------------------------------------------
-- Un codice invito e una password: se un membro semplice potesse leggere la
-- lista, tutti gli inviti pendenti del gruppo sarebbero suoi.
do $$
begin
  perform pg_temp.test_020_as('33333333-3333-3333-3333-333333333333');
  begin
    perform public.list_group_invites('44444444-4444-4444-4444-444444444444');
    raise exception 'FALLITO: un membro semplice ha letto gli inviti';
exception
  when others then
    if sqlerrm like 'FALLITO%' then raise; end if;
    raise notice 'OK: membro semplice non puo leggere gli inviti';
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- Un invito usato non si puo revocare
-- ---------------------------------------------------------------------------
-- Rispondere ok lascerebbe credere che l'accesso concesso sia stato annullato,
-- mentre la persona e' gia' dentro al gruppo.
do $$
declare
  v_used uuid;
begin
  perform pg_temp.test_020_as('11111111-1111-1111-1111-111111111111');

  select id into v_used from public.group_invites where code = 'USED020';
  begin
    perform public.revoke_group_invite(v_used);
    raise exception 'FALLITO: revoca di un invito usato accettata';
exception
  when others then
    if sqlerrm like 'FALLITO%' then raise; end if;
    raise notice 'OK: revoca di un invito usato rifiutata';
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- La revoca esclude il codice dall'ingresso
-- ---------------------------------------------------------------------------
-- E' il motivo per cui la revoca esiste. Se il codice revocato facesse ancora
-- entrare, l'unico effetto sarebbe una riga in lista con scritto "revocato".
do $$
declare
  v_id      uuid;
  v_revoked timestamptz;
begin
  perform pg_temp.test_020_as('11111111-1111-1111-1111-111111111111');

  select id into v_id from public.group_invites where code = 'PEND020';
  perform public.revoke_group_invite(v_id);

  select revoked_at into v_revoked
    from public.group_invites where code = 'PEND020';
  if v_revoked is null then
    raise exception 'FALLITO: revoca non registrata';
  end if;
  raise notice 'OK: revoca registrata';

  perform pg_temp.test_020_as('33333333-3333-3333-3333-333333333333');
  begin
    perform public.join_group('PEND020');
    raise exception 'FALLITO: join riuscito con invito revocato';
exception
  when others then
    if sqlerrm like 'FALLITO%' then raise; end if;
    raise notice 'OK: join con invito revocato rifiutato';
  end;

  begin
    perform public.join_group('SCAD020');
    raise exception 'FALLITO: join riuscito con invito scaduto';
exception
  when others then
    if sqlerrm like 'FALLITO%' then raise; end if;
    raise notice 'OK: join con invito scaduto rifiutato';
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- Un invito vale per una persona sola
-- ---------------------------------------------------------------------------
-- E' il motivo per cui gli inviti esistono invece del solo codice gruppo.
-- L'uso viene registrato e il secondo tentativo deve fallire.
do $$
declare
  v_used_by uuid;
  v_again   uuid := '55555555-5555-5555-5555-555555555555';
begin
  insert into public.profiles (id, username)
  values (v_again, 'test_secondo_020')
  on conflict (id) do nothing;

  perform pg_temp.test_020_as(v_again);
  perform public.join_group('FRESH020');

  select used_by into v_used_by
    from public.group_invites where code = 'FRESH020';
  if v_used_by is null then
    raise exception 'FALLITO: uso non registrato';
  end if;
  if v_used_by <> v_again then
    raise exception 'FALLITO: uso registrato a un utente diverso da chi ha usato il codice';
  end if;
  raise notice 'OK: uso registrato e attribuito a chi ha usato il codice';

  -- Secondo utente, stesso invito: il codice unique su used_by lo impedisce,
  -- ma deve essere un errore pulito e non una seconda membership.
  perform pg_temp.test_020_as('33333333-3333-3333-3333-333333333333');
  begin
    perform public.join_group('FRESH020');
    raise exception 'FALLITO: secondo ingresso riuscito con lo stesso invito';
exception
  when others then
    if sqlerrm like 'FALLITO%' then raise; end if;
    raise notice 'OK: secondo ingresso con lo stesso invito rifiutato';
  end;
end;
$$;

rollback;