-- ============================================================================
-- recommendations (1/2) - tipi e colonne di base
-- ============================================================================
-- Questa parte va applicata PRIMA della 20261011162000: PostgreSQL non
-- permette di USARE un valore di enum appena aggiunto nella stessa transazione
-- in cui lo si aggiunge ("unsafe use of new value ... must be committed").
-- Il trigger e `notify_user` che citano 'anime_recommended' stanno quindi nel
-- file successivo, quando il valore e' gia' committato.
-- ============================================================================

-- Interruttore profilo: "Consigli".
alter table public.profiles
  add column if not exists notify_recommendations boolean not null default true;

comment on column public.profiles.notify_recommendations is
  'true se l''utente vuole ricevere le notifiche dei consigli di visione.';

-- Nuovo tipo di notifica per i consigli.
alter type public.notification_type add value if not exists 'anime_recommended';

-- Messaggio lasciato con il consiglio: vive sulla riga di watchlist di gruppo
-- ("Consigliata da tutti") ed e' quello che si legge sotto la voce.
alter table public.watchlists
  add column if not exists message text;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'watchlists_message_length'
  ) then
    alter table public.watchlists
      add constraint watchlists_message_length
      check (message is null or char_length(message) <= 500);
  end if;
end $$;

comment on column public.watchlists.message is
  'Messaggio lasciato con il consiglio, mostrato sotto la voce nella lista di gruppo.';
