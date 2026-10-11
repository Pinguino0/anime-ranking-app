-- ============================================================================
-- app_update (2/2) - dal rilascio pubblicato al push
-- ============================================================================
-- Quando il maintainer pubblica una riga in `app_releases` (dal SQL Editor),
-- questo trigger crea una notifica in-app per OGNI profilo. La catena dei push
-- (vedi 20261011180000_push_webhook.sql) la consegna poi sul dispositivo, ma
-- solo a chi ha l'interruttore "Notifiche push" acceso: la notifica in-app resta
-- comunque a tutti, quindi nessuno perde l'avviso.
--
-- Perche' non c'e' antispam
-- -------------------------
-- `app_releases.version_code` e' chiave primaria: due release non possono avere
-- lo stesso codice, quindi lo stesso avviso non puo' nascere due volte. Non
-- serve la finestra temporale che usano le notifiche sui voti.
--
-- Perche' il testo non dice da quale versione
-- -------------------------------------------
-- La notifica nasce sul server, che non sa quale versione ha installata il
-- singolo telefono: il "da X a Y" della vecchia notifica locale qui non si puo'
-- scrivere. Il gate a schermo intero all'avvio resta la strada principale, e li'
-- il confronto lo fa l'app, che la propria versione la conosce.
-- ============================================================================

create or replace function public.notify_app_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.notify_user(
    p.id,
    'app_update',
    'Aggiornamento disponibile',
    'La versione ' || new.version_name || ' e'' pronta. Tocca per aggiornare.',
    jsonb_build_object(
      'version_code', new.version_code,
      'version_name', new.version_name
    ),
    false
  )
  from public.profiles p;

  return new;
end;
$$;

comment on function public.notify_app_update() is
  'All''insert di un rilascio crea una notifica per ogni profilo; la catena dei push la consegna a chi ha le notifiche accese.';

-- Il trigger e' l'unico modo per eseguirla: nessun client deve poterla chiamare
-- a mano, altrimenti potrebbe fabbricare avvisi di aggiornamento a piacere.
revoke all on function public.notify_app_update() from public, anon, authenticated;

drop trigger if exists app_releases_notify_update on public.app_releases;

create trigger app_releases_notify_update
after insert on public.app_releases
for each row execute function public.notify_app_update();
