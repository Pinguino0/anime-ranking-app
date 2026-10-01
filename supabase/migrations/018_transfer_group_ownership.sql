-- ============================================================================
-- 018 — trasferimento della proprieta' di un gruppo
-- ============================================================================
-- Il commento di leave_group in 003 rimandava qui ("vedi transfer_group_ownership
-- in 014"), ma la funzione non era mai stata scritta: senza di essa un owner
-- che vuole uscire dal gruppo non puo' farlo in nessun modo, perche' leave_group
-- lo blocca e la cancellazione del gruppo gli farebbe perdere tutto quello che
-- c'e' dentro.
--
-- NOTA SUL DROP. Il DB remoto conteneva gia' una versione di prova di
-- transfer_group_ownership, con il secondo parametro chiamato _new_owner invece
-- di _new_owner_id. "create or replace" non puo' rinominare un parametro: Postgres
-- risponde 42P13 "cannot change name of input parameter" e chiede esattamente
-- questo DROP. Senza, la funzione non si applicherebbe e l'app chiamerebbe una
-- RPC che non esiste.
--
-- Il drop e' senza CASCADE perche' non deve portare via niente: se un oggetto
-- dipendesse dalla funzione, e' meglio fallire qui e saperlo che trovarsi un
-- gruppo senza procedura di amministrazione. Non ci sono policy che la chiamino,
-- quindi il drop e' innocuo.
--
-- Dopo il drop i grant di questa migration sono riapplicati da zero: non resta
-- nessun privilegio ereditato dalla versione precedente, che era stata applicata
-- a mano e di cui non si conoscono i permessi.
-- ---------------------------------------------------------------------------
-- Il trasferimento tocca due tabelle che devono restare d'accordo:
--   groups.owner_id   chi puo' eliminare il gruppo
--   group_members.role chi puo' amministrare
-- Se una delle due venisse aggiornata senza l'altra il gruppo si troverebbe
-- senza owner reale (il nuovo owner non potrebbe eliminarlo) oppure con due
-- owner. Percio' tutto avviene in una sola funzione SECURITY DEFINER, che
-- Postgres esegue in una transazione implicita: o va tutto, o non va niente.
-- ============================================================================

-- DROP delle due funzioni prima di ricrearle, spiegato nella nota in testa.
-- Entrambe e non solo quella che falliva: la prima era gia' stata creata
-- dalla versione di prova, e senza drop la sua firma o i suoi permessi
-- potrebbero restare quelli di allora invece di quelli decisi qui.
drop function if exists public.transfer_group_ownership(uuid, uuid);
drop function if exists public.group_members_list(uuid);

-- ---------------------------------------------------------------------------
-- Membri del gruppo con il profilo, per scegliere a chi cedere la proprieta'
-- ---------------------------------------------------------------------------
-- Il client potrebbe leggere group_members da solo (la RLS lo permette gia' ai
-- membri), ma avrebbe due richieste e dovrebbe agganciare a mano i profili.
-- Qui si restituisce gia' il join, cosi' il selettore ha subito nome e
-- avatar senza codice di collagamento lato app.
--
-- security definer perche' il join profiles->group_members, letto dall'esterno,
-- si fermerebbe alla policy di profiles: un select su profiles filtrato da
-- group_members fa girare la query dentro le RLS di entrambe le tabelle e puo'
-- restare senza righe per un membro. Qui dentro siamo postgres.
create function public.group_members_list(_group_id uuid)
returns table (
  user_id     uuid,
  username    text,
  avatar_url  text,
  role        public.group_role,
  joined_at   timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select m.user_id,
         p.username,
         p.avatar_url,
         m.role,
         m.joined_at
    from public.group_members m
    join public.profiles p on p.id = m.user_id
   where m.group_id = _group_id
     -- Solo i membri del gruppo possono vedere chi e' dentro: un elenco
     -- leggibile da tutti direbbe anche se una persona fa parte di gruppi che
     -- non le interessano.
     and public.is_group_member(_group_id)
   order by
     -- L'owner in cima, poi gli admin, poi per data di ingresso: chi cerca
     -- qualcuno guarda i primi, non uno scorrimento casuale.
     case m.role when 'owner' then 0 when 'admin' then 1 else 2 end,
     m.joined_at;
$$;

revoke all on function public.group_members_list(uuid) from public, anon;
grant execute on function public.group_members_list(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Trasferimento della proprieta'
-- ---------------------------------------------------------------------------
create function public.transfer_group_ownership(
  _group_id      uuid,
  _new_owner_id  uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_previous_role public.group_role;
begin
  -- Solo l'owner attuale puo' cedere la proprieta'. Un admin che lo potesse
  -- fare potrebbe rilevare il gruppo all'insaputa di chi lo amministra.
  if not public.is_group_owner(_group_id) then
    raise exception 'Solo il owner puo cedere la proprieta''' using errcode = '42501';
  end if;

  -- Cedere la proprieta' a se stessi lascerebbe il gruppo identico ma con
  -- l'owner degradato a admin dal passaggio di ruolo qui sotto: si perderebbero
  -- le potenze senza che nulla sembri cambiato.
  if _new_owner_id is null or _new_owner_id = v_uid then
    raise exception 'Scegli un altro membro come nuovo owner'
      using errcode = '22023';
  end if;

  -- Il nuovo owner deve essere gia' nel gruppo: aggiungerlo qui dentro
  -- aggirerebbe l'invito e il controllo del ruolo, e il gruppo si aprirebbe a
  -- chiunque conoscesse l'id di un profilo.
  select role into v_previous_role
    from public.group_members
   where group_id = _group_id and user_id = _new_owner_id;

  if v_previous_role is null then
    raise exception 'Il nuovo owner deve essere un membro del gruppo'
      using errcode = '22023';
  end if;

  update public.group_members
     set role = 'owner'
   where group_id = _group_id and user_id = _new_owner_id;

  -- Chi cede resta nel gruppo come admin: non perde l'accesso e puo' continuare
  -- ad amministrare, che e' il comportamento atteso quando si passa il
  -- "gruppo di famiglia" a un altro.
  update public.group_members
     set role = 'admin'
   where group_id = _group_id and user_id = v_uid;

  -- groups.owner_id e il riferimento usato dalla policy di cancellazione:
  -- senza questo update il nuovo owner non potrebbe eliminare il gruppo e il
  -- vecchio potrebbe ancora farlo.
  update public.groups
     set owner_id = _new_owner_id
   where id = _group_id;
end;
$$;

revoke all on function public.transfer_group_ownership(uuid, uuid) from public, anon;
grant execute on function public.transfer_group_ownership(uuid, uuid) to authenticated;

comment on function public.transfer_group_ownership(uuid, uuid) is
  'Cede la proprieta del gruppo a un membro. Chi cede diventa admin.';