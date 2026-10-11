-- ---------------------------------------------------------------------------
-- 20261004184058_group_members_select_restored
--
-- Ripristina la SELECT su group_members, che la 025 concede e che nel database
-- remoto non c'e'.
--
-- Come e' successo: le migration 001-025 erano state applicate a mano e la
-- cronologia e' stata riallineata con `supabase migration repair --status
-- applied`, che scrive solo nella tabella di stato. La 025 risulta applicata
-- senza che il suo `grant select` fosse mai arrivato al database.
--
-- Il sintomo e' la schermata dei gruppi vuota per tutti gli utenti: PostgREST
-- risponde 42501 "permission denied for table group_members" perche' la lista
-- dei gruppi incorpora `group_members!inner(role, user_id)`, e serve il
-- privilegio SELECT anche sulla tabella annidata, che non compare mai come
-- `from()` nel client. Il gruppo esiste, l'utente ne e' membro, e la lista
-- torna vuota: un errore che sembra "non hai gruppi" invece di "manca un
-- GRANT".
--
-- Cosa fa: ripete i due statement della 025. Idempotente.
--
-- Nota per il futuro: `migration repair` segna come applicate solo le
-- migration che sono state eseguite davvero. Riparare la cronologia senza
-- eseguire quello che manca sposta il difetto dal database alla cronologia,
-- dove non e' piu' visibile.
-- ---------------------------------------------------------------------------

grant select on public.group_members to authenticated;

revoke insert, update, delete, truncate on public.group_members from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Verifica: se questa assert fallisce la 025 non e' ancora a posto e la
-- schermata dei gruppi resta vuota. Fallire qui e' preferibile a lasciare
-- l'app con una lista vuota senza dirne il motivo.
-- ---------------------------------------------------------------------------
do $$
begin
  if not has_table_privilege('authenticated', 'public.group_members', 'select') then
    raise exception 'group_members non leggibile da authenticated: la lista dei gruppi resterebbe vuota';
  end if;
end;
$$;
