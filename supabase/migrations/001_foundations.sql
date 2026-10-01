-- ============================================================================
-- 001 — Fondamenta: estensioni, trigger generici, funzioni helper
-- ============================================================================
-- Queste primitive vengono riusate da tutte le migration successive.
-- Le funzioni helper che leggono tabelle protette da RLS sono SECURITY DEFINER
-- per evitare ricorsione infinita tra policy (vedi documentazione in 003).
-- ============================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- updated_at automatico
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function public.set_updated_at() is
  'Trigger generico: mantiene updated_at. Applicare a ogni tabella con updated_at.';

-- ---------------------------------------------------------------------------
-- Validazione voto: 0..10 con incrementi di 0.5
-- ---------------------------------------------------------------------------
create or replace function public.is_valid_rating(v numeric)
returns boolean
language sql
immutable
parallel safe
as $$
  select v is not null
     and v between 0 and 10
     and mod(v * 2, 1) = 0;
$$;

comment on function public.is_valid_rating(numeric) is
  'True se il voto e valido: 0..10 con step 0.5 (es. 7.5 ok, 7.3 no).';

-- ---------------------------------------------------------------------------
-- Codice invito gruppo nel formato ANIME-XXXXX
-- ---------------------------------------------------------------------------
create or replace function public.generate_invite_code()
returns text
language plpgsql
volatile
as $$
declare
  v_code  text;
  v_tries int := 0;
begin
  loop
    -- 5 caratteri alfanumerici maiuscoli, evitando 0/O/1/I per leggibilita
    v_code := 'ANIME-' || upper(substr(
      translate(
        md5(gen_random_uuid()::text),
        'abcdefghijklmnopqrstuvwxyz0123456789',
        'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
      ), 1, 5));

    v_tries := v_tries + 1;
    exit when not exists (select 1 from public.groups where invite_code = v_code)
       or v_tries > 20;
  end loop;

  return v_code;
end;
$$;

comment on function public.generate_invite_code() is
  'Genera un codice invito univoco nel formato ANIME-XXXXX (es. ANIME-7X92K).';
