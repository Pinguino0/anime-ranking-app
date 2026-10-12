-- ============================================================================
-- new_episode - il tipo di notifica "e' uscito un episodio nuovo"
-- ============================================================================
-- Il refresh degli episodi non passa piu' da un job sul server: e' il telefono,
-- quando apre l'app, a chiedere al provider quante puntate ci sono adesso (vedi
-- 20261012161356_episode_sync.sql). Le notifiche restano comunque del database,
-- perche' e' l'insert degli episodi nuovi a far nascere la riga in
-- `notifications`, e da li' la catena dei push.
--
-- Perche' questo file e' separato dal successivo
-- ----------------------------------------------
-- PostgreSQL non permette di USARE un valore di enum appena aggiunto nella
-- stessa transazione in cui lo si aggiunge ("unsafe use of new value ... must
-- be committed"). La funzione che cita 'new_episode' sta quindi in un file a
-- parte, quando il valore e' gia' committato. E' lo stesso schema di
-- `app_update`.
-- ============================================================================

alter type public.notification_type add value if not exists 'new_episode';
