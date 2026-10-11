-- ============================================================================
-- device_token_rpc - registrazione del token FCM senza aprire la tabella
-- ============================================================================
-- La RLS di `device_tokens` e' "solo il proprietario", e va bene. Ma un
-- telefono non ha un proprietario fisso: lo stesso dispositivo puo' passare da
-- un account a un altro (logout/login). Con le policy soltanto, l'upsert del
-- nuovo utente non potrebbe toccare la riga del vecchio (la `using` non
-- combacia) e il vecchio continuerebbe a ricevere i push.
--
-- Queste due funzioni fanno il caso specifico e niente di piu':
--
--   * `register_device_token` riassegna il token all'utente collegato (o lo
--     crea). E' l'unico modo per spostare un token da un account a un altro.
--   * `remove_device_token` cancella il proprio token al logout.
--
-- Sono `security definer` per scavalcare la RLS in modo controllato: `auth.uid()`
-- resta la fonte dell'identita', quindi nessuno puo' registrare un token per un
-- altro utente. `anon` non puo' eseguirle.
-- ============================================================================

create or replace function public.register_device_token(
  p_token text,
  p_platform text default 'android'
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.device_tokens (user_id, token, platform)
  values ((select auth.uid()), p_token, p_platform)
  on conflict (token) do update
    set user_id    = excluded.user_id,
        platform   = excluded.platform,
        updated_at = now();
$$;

comment on function public.register_device_token(text, text) is
  'Registra (o riassegna) il token FCM del dispositivo per l''utente collegato.';

create or replace function public.remove_device_token(p_token text)
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.device_tokens
   where token = p_token
     and user_id = (select auth.uid());
$$;

comment on function public.remove_device_token(text) is
  'Rimuove il token FCM del dispositivo dell''utente collegato (al logout).';

revoke all on function public.register_device_token(text, text) from public, anon;
revoke all on function public.remove_device_token(text) from public, anon;
grant execute on function public.register_device_token(text, text) to authenticated;
grant execute on function public.remove_device_token(text) to authenticated;
