-- ---------------------------------------------------------------------------
-- 024_table_privileges
--
-- Revoca i privilegi di tabella che Supabase concede per default.
--
-- Il problema: Supabase imposta
--   alter default privileges in schema public grant all on tables to ...
-- quindi ogni tabella nuova nasce con INSERT/UPDATE/DELETE/TRUNCATE per anon,
-- authenticated e service_role. La 021 ha sistemato la stessa cosa sulle
-- FUNZIONI, ma sui privilegi di tabella nessuna migration interveniva.
--
-- Non e' uno scrittaggio subito sfruttabile: RLS e' attiva e su queste tabelle
-- non ci sono policy, quindi a runtime l'INSERT verrebbe respinto comunque. E'
-- difesa in profondza, che pero' regge solo finche' nessuno aggiunge una policy
-- o un GRANT in futuro. verify_020.sql lo segnalava con:
--
--   P0001: FALLITO: authenticated puo scrivere direttamente su group_invites
--
-- Cosa NON toccare: le tabelle su cui il client scrive in modo diretto, cioe'
-- duels, ratings e watchlists. Revocare li romperebbe l'app. profiles ha un
-- update diretto ma resta perche' l'app lo usa per l'avatar e le preferenze.
--
-- groups viene trattata a meta': il client la legge in diretto (per elencare i
-- gruppi dell'utente con il join su group_members), quindi SELECT resta, ma la
-- scrittura passa da create_group/join_group/leave_group/kick_member/
-- set_member_role/regenerate_invite_code, quindi le scritture si revocano.
-- ---------------------------------------------------------------------------

-- Nessun accesso diretto dal client: tutto passa da create_group_invite,
-- list_group_invites e revoke_group_invite, che sono SECURITY DEFINER.
revoke all on public.group_invites from anon, authenticated;

-- Il catalogo si legge con anime_search / anime_search_count /
-- anime_current_season e si scrive solo dalla Edge Function con service_role,
-- che mantiene il proprio grant. Il client non tocca mai la tabella.
revoke all on public.anime from anon, authenticated;

-- group_members: stessa situazione di groups, ma il client non la legge
-- direttamente, quindi basta chiudere tutto.
revoke all on public.group_members from anon, authenticated;

-- groups: SELECT resta per l'elenco dei gruppi, le scritture no.
revoke insert, update, delete, truncate on public.groups from anon, authenticated;

-- friendships: schema presente (004) ma il client social non e' ancora scritto.
-- Quando arrivera' usera' le RPC, quindi chiudere ora e' il momento giusto.
revoke all on public.friendships from anon, authenticated;