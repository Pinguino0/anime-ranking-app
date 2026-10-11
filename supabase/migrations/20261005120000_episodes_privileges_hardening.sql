-- ---------------------------------------------------------------------------
-- 20261005120000_episodes_privileges_hardening
--
-- Raccolta qui l'hardening delle tabelle del blocco episodi, che era stato
-- scritto dentro la 026 e dentro la 027 dopo che erano gia' state applicate.
--
-- Perche' una migration nuova invece di lasciare le modifiche dove erano
-- -----------------------------------------------------------------------
-- Modificare una migration gia' applicata e' la trappola classica: la
-- cronologia dice che 026 e 027 sono state eseguite, ma il loro contenuto e'
-- cambiato dopo. Sul database remoto quei revoke ci sono gia' (verificato a
-- mano il 4 ottobre 2026), quindi funziona. Su un ambiente nuovo nato da
-- `supabase db reset` funziona ugualmente, perche' il file aggiornato gira
-- per primo. Il caso che resta scoperto e' un ambiente vecchio che si aggiorna
-- con `db push`: la CLI vede 026 e 027 come gia' applicate e non le ri-esegue,
-- quindi quei revoke non arrivano mai e l'ambiente resta con i default di
-- Supabase. Il difetto non si vede, perche' non c'e' niente nella cronologia
-- che lo segnali: e' esattamente il motivo per cui la 20261004184058 esiste.
--
-- Gli statement qui sotto sono gli stessi di prima, spostati. Idempotenti:
-- riapplicarli su un database che li ha gia' non cambia niente.
-- ---------------------------------------------------------------------------

-- Supabase concede `all on tables` per default a anon, authenticated e
-- service_role, quindi le tre tabelle del blocco episodi nascevano con
-- INSERT/UPDATE/DELETE per anon. Non e' uno scrittaggio subito sfruttabile -
-- la RLS e' attiva e non ci sono policy anon - ma e' esattamente la difesa in
-- profondo che la 024 ha scritto per toglierla, quindi si applica anche alle
-- tabelle nate dopo.
--
-- Il criterio della 024: cio' che il client non tocca direttamente non
-- mantiene privilegi di tabella.
--
--   - episodes, episode_sources: il client le legge solo attraverso
--     episodes_for_anime ed episode_sources_list, entrambe SECURITY DEFINER
--     (migration 027). Si chiudono come public.anime, che si legge con
--     anime_search e si scrive solo dalla Edge Function.
--
--     Il blocco diretto e' anche cio' che rende impossibile sbagliare: una
--     query del tipo `.from('episode_sources').select()` lancia 42501 sempre,
--     il client deve passare da episode_sources_list. Senza, una schermata
--     che legge le fonti in chiaro continua a funzionare e non si sa se sta
--     scavalcando la RLS.
--
--   - watch_progress: qui il client scrive DIRETTAMENTE, con un upsert su
--     (user_id, episode_id) ogni dieci secondi. Quindi authenticated deve
--     tenere SELECT/INSERT/UPDATE/DELETE, e la policy "watch_progress: proprio"
--     e' cio' che lo tiene sulle sue righe. Solo anon si chiude.
--
-- service_role mantiene tutto: e' la Edge Function che popola il catalogo.
revoke all on public.episodes         from anon, authenticated;
revoke all on public.episode_sources  from anon, authenticated;
revoke all on public.watch_progress   from anon;

-- ---------------------------------------------------------------------------
-- Verifica
--
-- La 017 ha lasciato `assert_no_public_exec_for_anon()` come rete di sicurezza:
-- fallisce se in futuro qualcuno aggiunge una funzione public dimenticandosi
-- della revoca. Le tre RPC del blocco episodi sono esattamente quel caso, quindi
-- la si richiama: se una revoca sbaglia firma, la migration fallisce invece di
-- lasciare una RPC raggiungibile da anon.
-- ---------------------------------------------------------------------------
do $$
begin
  perform public.assert_no_public_exec_for_anon();
end $$;