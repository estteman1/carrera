-- =====================================================================
-- Carrera de Observación — Hacienda Fontanar
-- Esquema Supabase (PostgreSQL). Ejecutar completo en SQL Editor.
-- Modelo: log inmutable de acciones (event sourcing). El estado se deriva
-- en el cliente con el mismo motor probado; el servidor:
--   * autentica por PIN/código (hash bcrypt, nunca expuestos),
--   * verifica permisos por rol,
--   * asigna hora del servidor y orden (seq),
--   * deduplica por id (reintentos sin conexión no suman dos veces).
-- El público solo puede LEER acciones de eventos públicos. Nadie escribe
-- directamente: toda escritura pasa por submit_action().
-- =====================================================================

create extension if not exists pgcrypto;

create table if not exists race_events (
  id          text primary key,
  public      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists race_actions (
  id          uuid primary key,
  event_id    text not null references race_events(id) on delete cascade,
  seq         bigserial unique,
  type        text not null,
  payload     jsonb not null default '{}'::jsonb,
  role        text not null,
  at          timestamptz not null,
  server_at   timestamptz not null default now(),
  offline     boolean not null default false,
  demo        boolean not null default false
);
create index if not exists race_actions_event_seq on race_actions(event_id, seq);

-- Datos privados: PINs (hash), códigos de equipo (hash), teléfono de
-- Mamá Comodín, instrucciones y pistas de las pruebas.
create table if not exists race_secrets (
  event_id            text primary key references race_events(id) on delete cascade,
  pin_admin           text not null,
  pin_juez            text not null,
  pin_mama            text not null,
  team_codes          jsonb not null default '{}'::jsonb,   -- {"E1": "<hash>"}
  team_codes_plain    jsonb not null default '{}'::jsonb,   -- solo visible al admin vía RPC (para generar enlaces/QR)
  mama_phone          text not null default '',
  mama_phone_shared   boolean not null default false,
  tests_private       jsonb not null default '{}'::jsonb    -- {"1": {"instructions": "...", "hints": ["..."]}}
);

alter table race_events  enable row level security;
alter table race_actions enable row level security;
alter table race_secrets enable row level security;

drop policy if exists "lectura publica eventos" on race_events;
create policy "lectura publica eventos" on race_events for select using (public);

drop policy if exists "lectura publica acciones" on race_actions;
create policy "lectura publica acciones" on race_actions for select
  using (exists (select 1 from race_events e where e.id = event_id and e.public));
-- Sin políticas de insert/update/delete: solo las funciones security definer escriben.
-- Permisos explícitos (los proyectos Supabase recientes no exponen tablas nuevas por defecto).
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant usage on schema public to anon, authenticated;
    grant select on race_events, race_actions to anon, authenticated;
    revoke insert, update, delete, truncate on race_events, race_actions, race_secrets from anon, authenticated;
    revoke all on race_secrets from anon, authenticated;
  end if;
end $$;
-- race_secrets no tiene políticas: ilegible desde el cliente.

-- ---------------------------------------------------------------------
-- Autenticación por PIN o código de equipo
-- ---------------------------------------------------------------------
create or replace function race_resolve_role(p_event text, p_secret text, out role text, out team_id text)
language plpgsql security definer set search_path = public, extensions as $$
declare s race_secrets; k text; v text;
begin
  role := 'publico'; team_id := null;
  select * into s from race_secrets where event_id = p_event;
  if not found or p_secret is null or length(p_secret) = 0 then return; end if;
  if s.pin_admin = crypt(p_secret, s.pin_admin) then role := 'admin'; return; end if;
  if s.pin_mama  = crypt(p_secret, s.pin_mama)  then role := 'mama';  return; end if;
  if s.pin_juez  = crypt(p_secret, s.pin_juez)  then role := 'juez';  return; end if;
  for k, v in select * from jsonb_each_text(s.team_codes) loop
    if v = crypt(upper(p_secret), v) then role := 'equipo'; team_id := k; return; end if;
  end loop;
end $$;

create or replace function race_login(p_event text, p_secret text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r record;
begin
  perform pg_sleep(0.3); -- freno básico a fuerza bruta
  select * into r from race_resolve_role(p_event, p_secret);
  return jsonb_build_object('role', r.role, 'teamId', r.team_id);
end $$;

create or replace function race_server_time() returns bigint
language sql stable as $$ select (extract(epoch from now()) * 1000)::bigint $$;

-- Configuración vigente (último CONFIG_SET) para validar permisos por prueba
create or replace function race_test_validator(p_event text, p_seq int) returns text
language plpgsql stable security definer set search_path = public as $$
declare cfg jsonb; t jsonb;
begin
  select payload->'config' into cfg from race_actions
   where event_id = p_event and type = 'CONFIG_SET' and role = 'admin'
   order by seq desc limit 1;
  if cfg is null then
    return case when p_seq = 3 then 'mama' else 'admin' end;
  end if;
  select x into t from jsonb_array_elements(cfg->'tests') x where (x->>'seq')::int = p_seq limit 1;
  return coalesce(t->>'validator', 'admin');
end $$;

-- ---------------------------------------------------------------------
-- Escritura única: submit_action
-- ---------------------------------------------------------------------
create or replace function race_submit_action(p_event text, p_secret text, p_action jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  r record; v_type text := p_action->>'type'; v_payload jsonb := coalesce(p_action->'payload', '{}'::jsonb);
  v_at timestamptz := now(); v_client timestamptz; v_row race_actions; v_validator text;
begin
  if not exists (select 1 from race_events where id = p_event) then
    raise exception 'evento inexistente';
  end if;
  select * into r from race_resolve_role(p_event, p_secret);
  if r.role = 'publico' then raise exception 'no autorizado'; end if;

  -- Permisos (el motor del cliente aplica las mismas reglas: defensa en profundidad)
  if v_type in ('CONFIG_SET','DICE_ROUND','DICE_RESET','TEAM_START','ADJUST_POINTS','PAUSE','RESUME',
                'VOID','RACE_FINISH','RACE_REOPEN','FINAL_TIEBREAK','RESET') then
    if r.role <> 'admin' then raise exception 'solo el administrador'; end if;
  elsif v_type = 'TEAM_ARRIVED' then
    if r.role not in ('admin','juez','equipo') then raise exception 'no autorizado'; end if;
  elsif v_type = 'VALIDATION_REQUEST' then
    null;
  elsif v_type = 'VALIDATION_DECISION' then
    v_validator := race_test_validator(p_event, (v_payload->>'testSeq')::int);
    if not (r.role = 'admin' or r.role = v_validator) then raise exception 'no autorizado para esta prueba'; end if;
  elsif v_type = 'HINT_REQUEST' then
    if r.role not in ('equipo','admin','mama') then raise exception 'no autorizado'; end if;
  elsif v_type = 'HINT_RESOLVE' then
    if r.role not in ('mama','admin') then raise exception 'no autorizado'; end if;
  else
    raise exception 'tipo de acción desconocido';
  end if;
  -- Un equipo solo actúa sobre sí mismo
  if r.role = 'equipo' and coalesce(v_payload->>'teamId','') <> r.team_id then
    raise exception 'un equipo solo puede actuar sobre sí mismo';
  end if;

  -- Hora oficial: servidor. Si se registró sin conexión se acepta la hora
  -- corregida del dispositivo, solo dentro de las últimas 12 h.
  if coalesce((p_action->>'offline')::boolean, false) and p_action ? 'at' then
    v_client := to_timestamp((p_action->>'at')::double precision / 1000);
    if v_client between now() - interval '12 hours' and now() then v_at := v_client; end if;
  end if;

  insert into race_actions(id, event_id, type, payload, role, at, offline, demo)
  values ((p_action->>'id')::uuid, p_event, v_type, v_payload, r.role, v_at,
          coalesce((p_action->>'offline')::boolean,false), coalesce((p_action->>'demo')::boolean,false))
  on conflict (id) do nothing
  returning * into v_row;
  if v_row.id is null then select * into v_row from race_actions where id = (p_action->>'id')::uuid; end if;
  return to_jsonb(v_row);
end $$;

-- Lectura para el admin aunque el evento no sea público
create or replace function race_admin_fetch(p_event text, p_secret text, p_after bigint default 0)
returns setof race_actions language plpgsql security definer set search_path = public, extensions as $$
declare r record;
begin
  select * into r from race_resolve_role(p_event, p_secret);
  if r.role not in ('admin','juez','mama') then raise exception 'no autorizado'; end if;
  return query select * from race_actions where event_id = p_event and seq > p_after order by seq;
end $$;

-- ---------------------------------------------------------------------
-- Secretos
-- ---------------------------------------------------------------------
create or replace function race_get_secrets(p_event text, p_secret text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r record; s race_secrets;
begin
  select * into r from race_resolve_role(p_event, p_secret);
  if r.role not in ('admin','mama') then raise exception 'no autorizado'; end if;
  select * into s from race_secrets where event_id = p_event;
  if r.role = 'mama' then
    return jsonb_build_object('mamaPhone', s.mama_phone, 'mamaPhoneShared', s.mama_phone_shared, 'testsPrivate', s.tests_private);
  end if;
  return jsonb_build_object('mamaPhone', s.mama_phone, 'mamaPhoneShared', s.mama_phone_shared,
    'testsPrivate', s.tests_private, 'teamCodes', s.team_codes_plain,
    'public', (select public from race_events where id = p_event));
end $$;

create or replace function race_set_secrets(p_event text, p_secret text, p_data jsonb)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare r record; k text; v text; hashed jsonb := '{}'::jsonb;
begin
  select * into r from race_resolve_role(p_event, p_secret);
  if r.role <> 'admin' then raise exception 'solo el administrador'; end if;
  update race_secrets set
    mama_phone        = coalesce(p_data->>'mamaPhone', mama_phone),
    mama_phone_shared = coalesce((p_data->>'mamaPhoneShared')::boolean, mama_phone_shared),
    tests_private     = coalesce(p_data->'testsPrivate', tests_private),
    pin_admin = case when coalesce(p_data->>'pinAdmin','') <> '' then crypt(p_data->>'pinAdmin', gen_salt('bf')) else pin_admin end,
    pin_juez  = case when coalesce(p_data->>'pinJuez','')  <> '' then crypt(p_data->>'pinJuez',  gen_salt('bf')) else pin_juez end,
    pin_mama  = case when coalesce(p_data->>'pinMama','')  <> '' then crypt(p_data->>'pinMama',  gen_salt('bf')) else pin_mama end
  where event_id = p_event;
  if p_data ? 'teamCodes' then
    for k, v in select * from jsonb_each_text(p_data->'teamCodes') loop
      hashed := hashed || jsonb_build_object(k, crypt(upper(v), gen_salt('bf')));
    end loop;
    update race_secrets set team_codes = hashed, team_codes_plain = p_data->'teamCodes' where event_id = p_event;
  end if;
  if p_data ? 'public' then
    update race_events set public = (p_data->>'public')::boolean where id = p_event;
  end if;
end $$;

-- Vista del equipo: instrucciones solo de pruebas desbloqueadas
create or replace function race_team_view(p_event text, p_code text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r record; s race_secrets; v_reset bigint; v_current int; v_out jsonb := '{}'::jsonb; k text; v jsonb;
begin
  select * into r from race_resolve_role(p_event, p_code);
  if r.role <> 'equipo' then raise exception 'código inválido'; end if;
  select * into s from race_secrets where event_id = p_event;
  select coalesce(max(seq), 0) into v_reset from race_actions where event_id = p_event and type = 'RESET' and role = 'admin';
  v_current := 1;
  while exists (
    select 1 from race_actions a
     where a.event_id = p_event and a.seq >= v_reset and a.type = 'VALIDATION_DECISION'
       and (a.payload->>'approved')::boolean and a.payload->>'teamId' = r.team_id
       and (a.payload->>'testSeq')::int = v_current
       and not exists (select 1 from race_actions x where x.event_id = p_event and x.type = 'VOID' and x.role = 'admin' and x.payload->>'targetId' = a.id::text)
  ) loop
    v_current := v_current + 1;
  end loop;
  for k, v in select * from jsonb_each(s.tests_private) loop
    if k::int <= v_current then v_out := v_out || jsonb_build_object(k, jsonb_build_object('instructions', v->'instructions')); end if;
  end loop;
  return jsonb_build_object('teamId', r.team_id, 'currentSeq', v_current, 'tests', v_out,
    'mamaPhone', case when s.mama_phone_shared then s.mama_phone else '' end);
end $$;

-- Pistas escritas: solo para Mamá Comodín / admin (vía race_get_secrets)

-- ---------------------------------------------------------------------
-- Alta del evento (ejecutar una vez, cambiando los PINs provisionales)
-- ---------------------------------------------------------------------
create or replace function race_bootstrap(p_event text, p_pin_admin text, p_pin_juez text, p_pin_mama text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  insert into race_events(id) values (p_event) on conflict do nothing;
  insert into race_secrets(event_id, pin_admin, pin_juez, pin_mama)
  values (p_event, crypt(p_pin_admin, gen_salt('bf')), crypt(p_pin_juez, gen_salt('bf')), crypt(p_pin_mama, gen_salt('bf')))
  on conflict (event_id) do nothing;
end $$;
revoke execute on function race_bootstrap(text,text,text,text) from public;
revoke execute on function race_resolve_role(text,text) from public;
revoke execute on function race_test_validator(text,int) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on function race_bootstrap(text,text,text,text) from anon, authenticated;
    revoke execute on function race_resolve_role(text,text) from anon, authenticated;
    revoke execute on function race_test_validator(text,int) from anon, authenticated;
  end if;
end $$;

grant execute on function race_login(text,text), race_server_time(), race_submit_action(text,text,jsonb),
  race_admin_fetch(text,text,bigint), race_get_secrets(text,text), race_set_secrets(text,text,jsonb),
  race_team_view(text,text) to anon, authenticated;

-- Tiempo real
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin
      alter publication supabase_realtime add table race_actions;
    exception when duplicate_object then null;
    end;
  end if;
end $$;

-- ALTA (descomentar y cambiar los PINs antes de ejecutar):
-- select race_bootstrap('fontanar', 'PIN-ADMIN', 'PIN-JUEZ', 'PIN-MAMA');
