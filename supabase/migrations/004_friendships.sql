-- ============================================================================
-- 004 — friendships
-- ============================================================================
-- Coppia simmetrica: (Marco,Enea) e (Enea,Marco) sono la stessa amicizia.
-- L'indice univoco su least/greatest lo garantisce a livello di database,
-- quindi due richieste simultanee non creano duplicati.
-- ============================================================================

create type public.friendship_status as enum ('pending', 'accepted', 'rejected');

create table public.friendships (
  id           uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles (id) on delete cascade,
  receiver_id  uuid not null references public.profiles (id) on delete cascade,
  status       public.friendship_status not null default 'pending',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  constraint friendships_no_self check (requester_id <> receiver_id)
);

create unique index friendships_pair_key
  on public.friendships (least(requester_id, receiver_id), greatest(requester_id, receiver_id));

create index friendships_requester_idx on public.friendships (requester_id, status);
create index friendships_receiver_idx  on public.friendships (receiver_id,  status);

comment on table public.friendships is
  'Amicizie fra utenti. Simmetrica: esiste una sola riga per coppia.';

create trigger friendships_set_updated_at
  before update on public.friendships
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Coppia e stato sono quasi-immutabili
-- ---------------------------------------------------------------------------
-- Senza questo controllo la policy da sola non basta: WITH CHECK vede solo il
-- NUOVO valore, mai quello precedente, quindi un destinatario potrebbe
-- riscrivere requester_id e falsificare la provenienza della richiesta
-- ("Enea risulta aver chiesto amicizia a Marco" quando in realta l'ha chiesta
-- Marco). Il trigger e l'unico posto dove il valore vecchio e ancora visibile.
create or replace function public.friendships_guard_update()
returns trigger
language plpgsql
as $$
begin
  if new.requester_id is distinct from old.requester_id
     or new.receiver_id  is distinct from old.receiver_id
     or new.created_at   is distinct from old.created_at
  then
    raise exception 'Impossibile modificare gli interessati di una relazione'
      using errcode = '42501';
  end if;

  -- pending -> accepted/rejected e irreversibile: nessun secondo colpo di scena.
  if old.status <> 'pending' and new.status <> old.status then
    raise exception 'Lo stato della relazione non e piu modificabile'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger friendships_guard_update_trg
  before update on public.friendships
  for each row execute function public.friendships_guard_update();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.friendships enable row level security;

-- Solo le due parti coinvolte vedono la relazione.
create policy "friendships: lettura alle parti"
  on public.friendships for select
  to authenticated
  using (
    requester_id = (select auth.uid())
    or receiver_id = (select auth.uid())
  );

-- Solo il mittente puo creare una richiesta, e non verso se stesso.
-- (receiver_id <> requester_id e garantito anche dal CHECK della tabella.)
create policy "friendships: invio richiesta"
  on public.friendships for insert
  to authenticated
  with check (requester_id = (select auth.uid()));

-- Solo il destinatario risponde (accetta/rifiuta). L'immutabilita di
-- requester_id e receiver_id e garantita dal trigger friendships_guard_update.
create policy "friendships: risposta del destinatario"
  on public.friendships for update
  to authenticated
  using (receiver_id = (select auth.uid()))
  with check (
    receiver_id = (select auth.uid())
    and status <> 'pending'
  );

-- Rimozione: sia il mittente (annulla richiesta) sia il destinatario,
-- sia una delle due parti di un'amicizia accettata.
create policy "friendships: rimozione"
  on public.friendships for delete
  to authenticated
  using (
    requester_id = (select auth.uid())
    or receiver_id = (select auth.uid())
  );
