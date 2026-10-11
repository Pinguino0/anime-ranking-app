-- ============================================================================
-- device_tokens - i token FCM dei dispositivi dell'utente
-- ============================================================================
-- Un push non si manda a una persona: si manda a un dispositivo. Il server
-- conosce l'utente (`notifications.user_id`), l'Edge Function ha bisogno dei
-- token FCM di quel destinatario, e finche' non c'e' un posto dove scriverli il
-- push non parte da nessuna parte.
--
-- Un utente puo' avere piu' dispositivi (telefono + tablet): una riga per
-- token, non una per utente.
--
-- `token` e' UNIQUE e non "(user_id, token)": il token di FCM identifica il
-- dispositivo, e lo stesso telefono puo' passare da un account a un altro
-- (logout/login). Con il vincolo su (user_id, token) il vecchio account
-- resterebbe proprietario del token e il nuovo utente non riceverebbe nulla:
-- l'upsert riassegna l'unico proprietario, che e il comportamento giusto
-- (un dispositivo = un destinatario per volta).
--
-- RLS: solo il proprietario. L'Edge Function legge con la service key, che
-- scavalca la RLS, quindi non serve nessuna policy per lei.
-- ============================================================================

create table public.device_tokens (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles (id) on delete cascade,

  -- Il token FCM. E' una stringa lunga e opaca: nessun formato da validare.
  token      text not null,

  platform   text not null default 'android'
             check (platform in ('android', 'ios')),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint device_tokens_token_unique unique (token)
);

create index device_tokens_user_idx on public.device_tokens (user_id);

comment on table public.device_tokens is
  'Token FCM per dispositivo. Un token ha un solo proprietario: l upsert lo riassegna al login.';

create trigger device_tokens_set_updated_at
  before update on public.device_tokens
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- RLS: ogni utente vede e tocca solo i propri token
-- ---------------------------------------------------------------------------
alter table public.device_tokens enable row level security;

create policy "device_tokens: lettura dei propri"
  on public.device_tokens for select
  to authenticated
  using (user_id = (select auth.uid()));

create policy "device_tokens: inserimento dei propri"
  on public.device_tokens for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy "device_tokens: modifica dei propri"
  on public.device_tokens for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy "device_tokens: rimozione dei propri"
  on public.device_tokens for delete
  to authenticated
  using (user_id = (select auth.uid()));

-- Difesa in profondita: anon non tocca la tabella nemmeno se in futuro
-- comparisse una policy per sbaglio.
revoke all on public.device_tokens from anon;
