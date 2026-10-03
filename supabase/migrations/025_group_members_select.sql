-- ---------------------------------------------------------------------------
-- 025_group_members_select
--
-- Ripristina la SELECT su group_members per authenticated.
--
-- Cosa e' successo: la 024 revocava "all" su group_members, credendo che il
-- client non la toccasse. Il check sui `.from('group_members')` non trovava
-- niente, quindi sembrava corretto, ma la lista dei gruppi la raggiunge in
-- modo annidato:
--
--   from('groups').select('..., group_members!inner(role, user_id)')
--
-- PostgREST ha bisogno del privilegio SELECT su group_members anche se il
-- nome non compare mai come tabella principale. Revocato quello, la schermata
-- gruppi ha iniziato a rispondere "permission denied for table
-- group_members" e l'app non apriva piu' la lista.
--
-- Nota per il futuro: `revoke all` su una tabella non si puo' dedurre dal
-- grep delle tabelle usate dal client. Le tabelle annidate nelle select non
-- compaiono come argomento di from() e vanno cercate a parte.
--
-- SELECT torna, le scritture restano chiuse: il client scrive i membri solo
-- con kick_member e set_member_role. Le righe restano comunque filtrate da
-- RLS, quindi l'utente vede solo i gruppi di cui fa parte.
-- ---------------------------------------------------------------------------

grant select on public.group_members to authenticated;

revoke insert, update, delete, truncate on public.group_members from anon, authenticated;