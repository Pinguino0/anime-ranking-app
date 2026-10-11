-- ============================================================================
-- app_update (1/2) - il tipo di notifica per gli aggiornamenti dell'app
-- ============================================================================
-- L'avviso "c'e' una versione nuova" prima lo mostrava il telefono da solo, con
-- una notifica locale programmata da WorkManager. Adesso lo manda il server con
-- la stessa catena delle altre notifiche (riga in `notifications` -> trigger
-- `notify_push_webhook` -> Edge Function `send-push` -> FCM): arriva anche a chi
-- l'app non l'ha aperta e non c'e' piu' un pezzo di logica che vive solo sul
-- dispositivo.
--
-- Questa parte va applicata PRIMA della 20261011201000: PostgreSQL non permette
-- di USARE un valore di enum appena aggiunto nella stessa transazione in cui lo
-- si aggiunge ("unsafe use of new value ... must be committed"). Il trigger che
-- cita 'app_update' sta quindi nel file successivo, quando il valore e' gia'
-- committato.
-- ============================================================================

alter type public.notification_type add value if not exists 'app_update';
