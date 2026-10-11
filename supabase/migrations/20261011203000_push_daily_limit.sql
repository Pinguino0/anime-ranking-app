-- ============================================================================
-- push_daily_limit - al massimo 3 push al giorno per dispositivo
-- ============================================================================
-- Perche' per dispositivo e non per utente
-- ----------------------------------------
-- Un push non si manda a una persona: si manda a un dispositivo. Un utente con
-- telefono e tablet ha due token, e il tetto vale per ciascuno. E' anche l'unica
-- unita' su cui il server ha un dato vero (`device_tokens`), mentre "quante
-- notifiche ha visto" un umano non lo sa nessuno.
--
-- Come si conta
-- -------------
-- Due colonne su `device_tokens`:
--   * `push_date`  - il giorno (UTC) dell'ultimo invio;
--   * `push_count` - quante push sono partite verso quel token in quel giorno.
--
-- Il conteggio si azzera da solo quando cambia il giorno: non serve un job di
-- pulizia, e un token inattivo non porta con se' nessuno stato da scadenzare.
--
-- Perche' un UPDATE e non "leggi il conteggio, poi decidi"
-- -------------------------------------------------------
-- Due notifiche scritte nello stesso istante farebbero partire due Edge Function
-- in parallelo: con la lettura separata leggerebbero entrambe `push_count = 2` e
-- partirebbero entrambe, sforando il tetto. Qui la condizione sta nella `where`
-- dell'UPDATE: la riga viene bloccata, la seconda transazione rivaluta la
-- condizione dopo la prima e viene scartata. Prenotare lo slot *prima* dell'invio
-- e' voluto: conta il tentativo, non l'esito, cosi' un FCM lento non apre la
-- strada a una raffica.
--
-- Chi puo' chiamarla
-- ------------------
-- Solo la Edge Function `send-push`, che gira con la service role. Il client non
-- la vede: `revoke ... from public, anon, authenticated`. La RLS di
-- `device_tokens` resta intatta e il proprietario continua a vedere solo le
-- proprie righe.
-- ============================================================================

alter table public.device_tokens
  add column if not exists push_count integer not null default 0,
  add column if not exists push_date date;

comment on column public.device_tokens.push_count is
  'Quante push sono partite verso questo token nel giorno indicato da push_date (UTC).';

comment on column public.device_tokens.push_date is
  'Giorno (UTC) a cui si riferisce push_count. NULL finche'' il dispositivo non riceve la prima push.';

-- ---------------------------------------------------------------------------
-- reserve_push_slot - prenota uno slot se il tetto non e' ancora raggiunto
-- ---------------------------------------------------------------------------
-- Restituisce `true` se la push verso `p_token` puo' partire, `false` se il
-- limite giornaliero `p_limit` (default 3) e' gia' stato toccato o il token non
-- esiste. `security definer` perche' la chiama la service role e non deve
-- dipendere dalla RLS del chiamante.
create or replace function public.reserve_push_slot(
  p_token text,
  p_limit integer default 3
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'utc')::date;
  v_reserved boolean;
begin
  if p_token is null or p_token = '' then
    return false;
  end if;

  -- Limite 0 (o negativo) = nessun push: caso limite esplicito, non un errore.
  if p_limit is null or p_limit <= 0 then
    return false;
  end if;

  update public.device_tokens
     set push_count = case when push_date = v_today then push_count + 1 else 1 end,
         push_date  = v_today
   where token = p_token
     and (push_date is distinct from v_today or push_count < p_limit)
  returning true into v_reserved;

  return coalesce(v_reserved, false);
end;
$$;

comment on function public.reserve_push_slot(text, integer) is
  'Prenota uno slot di push per il dispositivo: true se inviabile, false se il limite giornaliero e'' raggiunto o il token non esiste.';

revoke all on function public.reserve_push_slot(text, integer) from public, anon, authenticated;
grant execute on function public.reserve_push_slot(text, integer) to service_role;
