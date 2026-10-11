-- ============================================================================
-- push_webhook - dalla notifica in `notifications` al push su FCM
-- ============================================================================
-- Chiude la catena iniziata con `device_tokens` e la Edge Function `send-push`:
--
--   trigger su `notifications`  ->  net.http_post  ->  send-push  ->  FCM
--
-- Perche' pg_net e non il Database Webhook della dashboard
-- --------------------------------------------------------
-- Il webhook della dashboard va creato a mano, e non ha modo di scegliere un
-- segreto proprio: la funzione `send-push` rifiuta chi non presenta la service
-- key o il segreto condiviso. Il trigger qui sotto legge il segreto da Vault e
-- lo manda in `x-webhook-secret`, cosi' la service key non deve vivere nel
-- database.
--
-- Perche' il segreto sta in Vault
-- -------------------------------
-- Una migration e' un file di testo committato: qualunque valore scritto qui e'
-- un segreto pubblico. Il valore vero sta in Vault (`push_webhook_secret`) ed e'
-- lo stesso caricato come secret della funzione (`PUSH_WEBHOOK_SECRET`). Se
-- manca, il trigger non fa niente: nessun push, nessun errore. La notifica
-- in-app resta comunque, quindi l'app non si rompe.
--
-- Quando parte il push
-- --------------------
-- Solo se `profiles.notify_push` e' acceso: e' l'interruttore "Notifiche push"
-- ("Avvisi sul dispositivo") nelle impostazioni. Le preferenze per tipo
-- (`notify_recommendations`, `notify_votes`, ...) decidono se la riga in
-- `notifications` viene scritta affatto: se non c'e' riga, non c'e' push.
--
-- Il push e' "best effort": se l'invio fallisce, la notifica in-app resta e la
-- prossima notifica ci riprova. Non c'e' una coda di ritentativi, di proposito:
-- un push vecchio di dieci minuti non serve a nessuno.
-- ============================================================================

-- pg_net mette a disposizione `net.http_post`, che accoda la richiesta e la
-- spedisce da un worker in background (non blocca l'insert).
create extension if not exists pg_net;

create or replace function public.notify_push_webhook()
returns trigger
language plpgsql
security definer
set search_path = public, vault
as $$
declare
  push_on boolean;
  secret text;
begin
  -- Master switch "Notifiche push" del destinatario.
  select p.notify_push into push_on
    from public.profiles p
   where p.id = new.user_id;

  if push_on is not true then
    return new;
  end if;

  select s.decrypted_secret into secret
    from vault.decrypted_secrets s
   where s.name = 'push_webhook_secret'
   limit 1;

  -- Webhook non configurato (segreto assente): la notifica resta in-app.
  if secret is null or secret = '' then
    return new;
  end if;

  perform net.http_post(
    url := 'https://sjbstiexythmapxmrfyp.supabase.co/functions/v1/send-push',
    body := jsonb_build_object(
      'type', 'INSERT',
      'table', 'notifications',
      'record', to_jsonb(new)
    ),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-webhook-secret', secret
    ),
    timeout_milliseconds := 5000
  );

  return new;
end;
$$;

comment on function public.notify_push_webhook() is
  'Dopo l''insert di una notifica, chiama la Edge Function send-push via pg_net se il destinatario ha le notifiche push accese.';

-- Il trigger e' l'unico modo per eseguirla: nessun client deve poterla chiamare
-- a mano, altrimenti potrebbe fabbricare push a piacere (il segreto lo sa solo
-- il trigger).
revoke all on function public.notify_push_webhook() from public, anon, authenticated;

drop trigger if exists notifications_push_webhook on public.notifications;

create trigger notifications_push_webhook
after insert on public.notifications
for each row execute function public.notify_push_webhook();
