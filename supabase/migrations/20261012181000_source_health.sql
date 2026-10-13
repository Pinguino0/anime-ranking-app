-- ============================================================================
-- source_health - spegnere una fonte rotta, in base a chi la usa davvero
-- ============================================================================
-- Il problema: `episode_sources` ha un `is_active`, ma nessuno lo cambia mai.
-- Quando una fonte muore (il file non c'e' piu', il provider ha rimosso la
-- serie) l'app continua a provarla per prima, fallisce, e passa alla
-- successiva: uno spreco che l'utente vede come un'attesa.
--
-- Perche' il segnale arriva dal telefono: la pipeline di risoluzione tocca
-- AnimeUnity, che risponde 403 a un IP di datacenter e 200 a quello
-- residenziale. Un job che parte dal server non potrebbe nemmeno chiedere se la
-- fonte e' viva: l'unico posto dove la domanda ha una risposta e' il telefono.
--
-- Come si decide: ogni dispositivo e' *un voto*, non ogni richiesta. Un utente
-- che fallisce la stessa fonte dieci volte ha sbagliato una volta sola, perche'
-- la riga e' unica per (fonte, utente). Quando TRE utenti diversi segnalano la
-- stessa fonte, la fonte viene spenta. Un successo cancella il voto di chi
-- l'ha avuto, e se non restano voti la fonte torna attiva: cosi' un guasto
-- passeggero si ripara da solo e un abuso singolo non spegne niente.

alter table public.episode_sources
  add column if not exists disabled_at timestamptz;

comment on column public.episode_sources.disabled_at is
  'Quando la salute delle fonti l''ha spenta; NULL se non e'' stata lei.';

create table if not exists public.source_health_reports (
  source_id      uuid not null references public.episode_sources(id) on delete cascade,
  user_id        uuid not null references auth.users(id) on delete cascade,
  fail_count     integer not null default 1 check (fail_count > 0),
  last_failed_at timestamptz not null default now(),
  primary key (source_id, user_id)
);

comment on table public.source_health_reports is
  'Un voto per (fonte, utente): quanti utenti distinti segnalano una fonte rotta.';

-- Nessuna policy: la tocca solo la funzione `security definer` qui sotto. Il
-- client non deve poter leggere chi ha segnalato cosa, ne' scrivere voti.
alter table public.source_health_reports enable row level security;
revoke all on public.source_health_reports from public, anon, authenticated;

-- Quanti utenti distinti devono segnalare una fonte perche' venga spenta.
create or replace function public.source_failure_threshold()
returns integer
language sql
immutable
as $$ select 3 $$;

create or replace function public.report_source_result(
  _source_id uuid,
  _ok        boolean
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_failers integer;
  v_result  boolean;
begin
  if v_uid is null or _source_id is null then
    return null;
  end if;

  -- Id inventati non creano voti orfani: la chiave esterna li rifiuterebbe,
  -- ma un controllo esplicito risponde `null` invece di sollevare.
  if not exists (select 1 from public.episode_sources where id = _source_id) then
    return null;
  end if;

  if _ok then
    delete from public.source_health_reports
     where source_id = _source_id and user_id = v_uid;

    -- Se nessuno la segnala piu' rotta, la fonte si riaccende. E' il modo in
    -- cui un guasto passeggero si ripara senza intervento.
    if not exists (
      select 1 from public.source_health_reports where source_id = _source_id
    ) then
      update public.episode_sources
         set is_active = true, disabled_at = null
       where id = _source_id
         and not is_active;
    end if;
  else
    insert into public.source_health_reports (source_id, user_id)
    values (_source_id, v_uid)
    on conflict (source_id, user_id) do update
      set fail_count     = public.source_health_reports.fail_count + 1,
          last_failed_at = now();

    select count(*) into v_failers from public.source_health_reports
     where source_id = _source_id;

    -- `v_failers` non e' usato per il confronto diretto, ma tenerlo rende
    -- leggibile il perche' della soglia.
    if v_failers >= public.source_failure_threshold() then
      update public.episode_sources
         set is_active = false, disabled_at = now()
       where id = _source_id and is_active;
    end if;
  end if;

  select is_active into v_result from public.episode_sources where id = _source_id;
  return v_result;
end;
$$;

comment on function public.report_source_result(uuid, boolean) is
  'Registra com''e'' andata una risoluzione: un successo pulisce i voti, tre utenti diversi spengono la fonte.';

revoke all on function public.report_source_result(uuid, boolean) from public, anon;
grant execute on function public.report_source_result(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Riparazione periodica (pg_cron)
-- ---------------------------------------------------------------------------
-- Non e' il cuore della cosa — i successi riparano gia' da soli — ma stura le
-- fonti spente da tempo che nessuno riprova piu': senza, una fonte spenta male
-- per un guasto passeggero resterebbe invisibile per sempre, perche' nessuno
-- puo' piu' segnalarla funzionante se non la vede.
create or replace function public.source_health_repair()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Un voto vecchissimo non dice piu' niente di oggi.
  delete from public.source_health_reports
   where last_failed_at < now() - interval '60 days';

  update public.episode_sources es
     set is_active = true, disabled_at = null
   where es.is_active = false
     and es.disabled_at is not null
     and es.disabled_at < now() - interval '14 days'
     and not exists (
       select 1 from public.source_health_reports r
        where r.source_id = es.id
     );
end;
$$;

revoke all on function public.source_health_repair() from public, anon, authenticated;

do $$
begin
  perform cron.unschedule('source-health-repair')
    where exists (select 1 from cron.job where jobname = 'source-health-repair');
exception when others then
  null;
end $$;

select cron.schedule(
  'source-health-repair',
  '17 4 * * *',
  $$select public.source_health_repair()$$
);
