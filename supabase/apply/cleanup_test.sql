-- ============================================================================
-- cleanup di test (NON e una migration)
-- Rimuove tutto cio che ha creato seed_test.sql. Da eseguire come postgres.
--
-- Nota: si cancellano prima le tabelle figlie che hanno trigger di attivita e
-- poi gli utenti. public.log_activity e a prova di cascata, quindi l'ordine
-- non e piu critico come prima, ma cancellare per tabella rende il conteggio
-- finale verificabile a occhio.
-- ============================================================================

delete from auth.users where id in (
  '11111111-1111-1111-1111-111111111111',
  '22222222-2222-2222-2222-222222222222',
  '33333333-3333-3333-3333-333333333333'
);

delete from public.groups where id = 'aaaaaaaa-0000-0000-0000-000000000001';

delete from public.anime where external_source = 'mal' and external_id between '101' and '116';