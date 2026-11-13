-- =====================================================================
-- Migración v3 (se ejecuta DESPUÉS de migracion_v2.sql, ya aplicada)
--
--  - ESP32 inserta solo por la RPC registrar_lectura (token del dispositivo)
--  - anon pierde todo acceso directo a las tablas (la web lee por /api/estado)
--  - Alertas por EVENTO (cambio de estado) con valores copiados
--  - Notificaciones por Telegram (pg_net + Vault)
--  - Comandos remotos (reinicio desde la web)
--  - Retención: registros 7 días -> archivo 90 días -> resumen por hora
--  - Monitoreo del espacio de la base
--
-- Es idempotente: se puede ejecutar más de una vez.
-- Ejecutar en Supabase -> SQL Editor. Si falla, NO se aplica nada (transacción).
-- Antes de ejecutarla: hacer un respaldo (supabase/respaldo.ps1).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Extensiones
--    Si pg_cron o pg_net dan error, actívalas en Database -> Extensions
--    y vuelve a ejecutar este archivo.
-- ---------------------------------------------------------------------
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_net   with schema extensions;
create extension if not exists pg_cron;

-- ---------------------------------------------------------------------
-- 1. Dispositivos (antes que registros, por la FK)
-- ---------------------------------------------------------------------
create table if not exists public.dispositivos (
  id           integer generated always as identity primary key,
  nombre       text not null,
  token_hash   text not null unique,          -- SHA-256 del token (nunca el token)
  activo       boolean not null default true,
  ultimo_envio timestamptz,
  creado       timestamptz not null default now()
);
alter table public.dispositivos enable row level security;   -- sin políticas: nadie externo la ve

-- ---------------------------------------------------------------------
-- 2. registros: columnas nuevas
-- ---------------------------------------------------------------------
alter table public.registros
  add column if not exists falla          boolean not null default false,
  add column if not exists sin_agua       boolean not null default false,
  add column if not exists precalentando  boolean not null default false,
  add column if not exists agua_ml        double precision,
  add column if not exists capacidad_ml   double precision,
  add column if not exists autonomia_s    double precision,
  add column if not exists id_dispositivo integer references public.dispositivos(id) on delete set null;

-- Hora de Bolivia visible en el Table Editor (fecha sigue siendo el instante real)
do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'registros' and column_name = 'fecha_bolivia') then
    begin
      alter table public.registros
        add column fecha_bolivia timestamp generated always as (fecha at time zone 'America/La_Paz') stored;
    exception when others then
      raise notice 'No se pudo crear registros.fecha_bolivia: %', sqlerrm;
    end;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. alertas: tipo, valores copiados, notificación, FK que no bloquea el archivado
-- ---------------------------------------------------------------------
alter table public.alertas
  add column if not exists tipo                text,
  add column if not exists lectura_temperatura double precision,
  add column if not exists lectura_gas         double precision,
  add column if not exists notificada          boolean not null default false;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'alertas_tipo_check') then
    alter table public.alertas
      add constraint alertas_tipo_check check (tipo is null or tipo in ('gas', 'calor', 'falla', 'sin_agua'));
  end if;
end $$;

-- Alertas anteriores a v3: copiar fecha y valores reales de su registro.
-- (Las creadas antes de v2 quedaron con la fecha del momento de la migración.)
update public.alertas a
   set fecha               = r.fecha,
       lectura_temperatura = r.lectura_temperatura,
       lectura_gas         = r.lectura_gas,
       tipo                = case when r.gas then 'gas' when r.calor then 'calor' end,
       notificada          = true          -- no se notifican: son históricas
  from public.registros r
 where a.id_registro = r.id_registro
   and a.tipo is null;

-- Al mover registros al archivo, la alerta se conserva (id_registro queda en null)
alter table public.alertas drop constraint if exists alertas_id_registro_fkey;
alter table public.alertas
  add constraint alertas_id_registro_fkey
  foreign key (id_registro) references public.registros(id_registro) on delete set null;

do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'alertas' and column_name = 'fecha_bolivia') then
    begin
      alter table public.alertas
        add column fecha_bolivia timestamp generated always as (fecha at time zone 'America/La_Paz') stored;
    exception when others then
      raise notice 'No se pudo crear alertas.fecha_bolivia: %', sqlerrm;
    end;
  end if;
end $$;

create index if not exists alertas_fecha_idx   on public.alertas (fecha desc);
create index if not exists registros_fecha_idx on public.registros (fecha desc);

-- ---------------------------------------------------------------------
-- 4. Comandos remotos (botón "Reiniciar" de la web)
-- ---------------------------------------------------------------------
create table if not exists public.comandos (
  id             integer generated always as identity primary key,
  id_dispositivo integer references public.dispositivos(id) on delete cascade,  -- null = todos
  comando        text not null check (comando in ('reiniciar')),
  creado         timestamptz not null default now(),
  ejecutado      timestamptz
);
alter table public.comandos enable row level security;
create index if not exists comandos_creado_idx on public.comandos (creado desc);

-- ---------------------------------------------------------------------
-- 5. Retención: archivo y resumen
-- ---------------------------------------------------------------------
create table if not exists public.registros_archivo (
  id_registro         integer primary key,
  fecha               timestamptz not null,
  lectura_gas         double precision,
  lectura_temperatura double precision,
  calor               boolean,
  gas                 boolean,
  falla               boolean,
  sin_agua            boolean,
  agua_ml             double precision,
  id_dispositivo      integer
);
alter table public.registros_archivo enable row level security;
create index if not exists registros_archivo_fecha_idx on public.registros_archivo (fecha);

create table if not exists public.registros_resumen (
  hora        timestamptz primary key,      -- inicio de la hora
  n_lecturas  integer not null,
  temp_prom   double precision,
  temp_min    double precision,
  temp_max    double precision,
  gas_prom    double precision,
  gas_min     double precision,
  gas_max     double precision,
  n_calor     integer not null default 0,
  n_gas       integer not null default 0,
  n_falla     integer not null default 0,
  n_sin_agua  integer not null default 0
);
alter table public.registros_resumen enable row level security;

-- ---------------------------------------------------------------------
-- 6. Telegram
--    Secretos en Vault (ver configuracion_manual.sql):
--      telegram_bot_token  y  telegram_chat_id (uno o varios, separados por coma)
-- ---------------------------------------------------------------------
create or replace function public.enviar_telegram(p_texto text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_token text;
  v_chats text;
  v_chat  text;
begin
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'telegram_bot_token';
  select decrypted_secret into v_chats from vault.decrypted_secrets where name = 'telegram_chat_id';
  if v_token is null or v_chats is null then
    raise notice 'Telegram no configurado (faltan secretos en Vault)';
    return false;
  end if;

  foreach v_chat in array string_to_array(v_chats, ',') loop
    perform net.http_post(
      url     := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      body    := jsonb_build_object('chat_id', trim(v_chat), 'text', p_texto),
      headers := '{"Content-Type": "application/json"}'::jsonb
    );
  end loop;
  return true;
exception when others then
  -- Nunca bloquear el guardado de datos por un fallo de Telegram
  raise notice 'Error al encolar Telegram: %', sqlerrm;
  return false;
end;
$$;

create or replace function public.notificar_alerta()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_titulo text;
  v_texto  text;
begin
  v_titulo := case new.tipo
    when 'gas'      then '🚨 GAS DETECTADO: ventilar y evacuar'
    when 'calor'    then '🔥 TEMPERATURA ALTA: bombas activadas'
    when 'falla'    then '⚠️ FALLA DE SENSOR: revisar conexiones'
    when 'sin_agua' then '🚱 SIN AGUA: bombas bloqueadas. Recargar el depósito y reiniciar desde la web'
    else '🔔 Alerta'
  end;

  v_texto := v_titulo
    || E'\nTemp: ' || coalesce(round(new.lectura_temperatura::numeric, 1)::text, '-') || ' °C'
    || ' | Gas: '  || coalesce(round(new.lectura_gas::numeric, 2)::text, '-') || ' V'
    || E'\nHora: ' || to_char(new.fecha at time zone 'America/La_Paz', 'DD/MM/YYYY HH24:MI:SS');

  if public.enviar_telegram(v_texto) then
    update public.alertas set notificada = true where id_alertas = new.id_alertas;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notificar_alerta on public.alertas;
create trigger trg_notificar_alerta
after insert on public.alertas
for each row execute function public.notificar_alerta();

-- ---------------------------------------------------------------------
-- 7. Alertas por EVENTO (reemplaza la función de v2; el trigger
--    trg_crear_alerta de v2 sigue apuntando a esta función)
-- ---------------------------------------------------------------------
create or replace function public.crear_alerta()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gas      boolean;
  v_calor    boolean;
  v_falla    boolean;
  v_sin_agua boolean;
  v_tipo     text;
  v_normal   text[] := '{}';
begin
  -- Estado anterior del mismo dispositivo
  select gas, calor, falla, sin_agua
    into v_gas, v_calor, v_falla, v_sin_agua
    from public.registros
   where id_registro < new.id_registro
     and id_dispositivo is not distinct from new.id_dispositivo
   order by id_registro desc
   limit 1;

  v_gas := coalesce(v_gas, false);
  v_calor := coalesce(v_calor, false);
  v_falla := coalesce(v_falla, false);
  v_sin_agua := coalesce(v_sin_agua, false);

  -- false -> true: nueva alerta
  foreach v_tipo in array array['gas', 'calor', 'falla', 'sin_agua'] loop
    if (v_tipo = 'gas'      and new.gas      and not v_gas)
    or (v_tipo = 'calor'    and new.calor    and not v_calor)
    or (v_tipo = 'falla'    and new.falla    and not v_falla)
    or (v_tipo = 'sin_agua' and new.sin_agua and not v_sin_agua) then
      insert into public.alertas (id_registro, fecha, tipo, lectura_temperatura, lectura_gas)
      values (new.id_registro, new.fecha, v_tipo, new.lectura_temperatura, new.lectura_gas);
    end if;
  end loop;

  -- true -> false: aviso de normalización
  if v_gas      and not new.gas      then v_normal := v_normal || 'gas'::text; end if;
  if v_calor    and not new.calor    then v_normal := v_normal || 'temperatura'::text; end if;
  if v_falla    and not new.falla    then v_normal := v_normal || 'sensores'::text; end if;
  if v_sin_agua and not new.sin_agua then v_normal := v_normal || 'agua (depósito recargado)'::text; end if;

  if array_length(v_normal, 1) > 0 then
    perform public.enviar_telegram('✅ Normalizado: ' || array_to_string(v_normal, ', ')
      || E'\nHora: ' || to_char(new.fecha at time zone 'America/La_Paz', 'DD/MM/YYYY HH24:MI:SS'));
  end if;

  return new;
end;
$$;

drop trigger if exists trg_crear_alerta on public.registros;
create trigger trg_crear_alerta
after insert on public.registros
for each row execute function public.crear_alerta();

-- ---------------------------------------------------------------------
-- 8. RPC del ESP32
-- ---------------------------------------------------------------------
create or replace function public.registrar_lectura(
  p_token          text,
  p_temperatura    double precision,
  p_gas            double precision,
  p_calor          boolean,
  p_alerta_gas     boolean,
  p_falla          boolean          default false,
  p_sin_agua       boolean          default false,
  p_precalentando  boolean          default false,
  p_agua_ml        double precision default null,
  p_capacidad_ml   double precision default null,
  p_autonomia_s    double precision default null,
  p_fecha          timestamptz      default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id     integer;
  v_ultimo timestamptz;
  v_fecha  timestamptz := now();
begin
  select id, ultimo_envio into v_id, v_ultimo
    from public.dispositivos
   where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
     and activo
   for update;

  if v_id is null then
    raise exception 'Token inválido o dispositivo inactivo' using errcode = '42501';
  end if;

  -- Límite de frecuencia: 1 envío por segundo por dispositivo (HTTP 429)
  if v_ultimo is not null and now() - v_ultimo < interval '1 second' then
    raise exception 'Demasiadas solicitudes' using errcode = 'PT429';
  end if;

  -- Validación de rangos (NaN también queda fuera)
  if p_temperatura is null or not (p_temperatura between -50 and 300) then
    raise exception 'Temperatura fuera de rango: %', p_temperatura using errcode = '22003';
  end if;
  if p_gas is null or not (p_gas between 0 and 5) then
    raise exception 'Gas fuera de rango: %', p_gas using errcode = '22003';
  end if;
  if p_agua_ml is not null and not (p_agua_ml between 0 and 1000000) then
    raise exception 'Agua fuera de rango: %', p_agua_ml using errcode = '22003';
  end if;

  -- Hora del ESP32 (eventos guardados sin red): solo si es razonable
  if p_fecha is not null and p_fecha between now() - interval '24 hours' and now() + interval '1 minute' then
    v_fecha := p_fecha;
  end if;

  insert into public.registros (
    fecha, lectura_temperatura, lectura_gas, calor, gas, falla, sin_agua,
    precalentando, agua_ml, capacidad_ml, autonomia_s, id_dispositivo
  ) values (
    v_fecha, p_temperatura, p_gas, p_calor, p_alerta_gas, p_falla, p_sin_agua,
    p_precalentando, p_agua_ml, p_capacidad_ml, p_autonomia_s, v_id
  );

  update public.dispositivos set ultimo_envio = now() where id = v_id;
end;
$$;

create or replace function public.obtener_comando(p_token text)
returns table (id integer, comando text)
language plpgsql
security definer
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  v_disp integer;
begin
  select d.id into v_disp
    from public.dispositivos d
   where d.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
     and d.activo;

  if v_disp is null then
    raise exception 'Token inválido o dispositivo inactivo' using errcode = '42501';
  end if;

  -- Solo comandos recientes: un clic viejo no reinicia al volver la red
  return query
    select c.id, c.comando
      from public.comandos c
     where (c.id_dispositivo = v_disp or c.id_dispositivo is null)
       and c.ejecutado is null
       and c.creado > now() - interval '2 minutes'
     order by c.creado desc
     limit 1;
end;
$$;

create or replace function public.confirmar_comando(p_token text, p_id integer)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_disp integer;
begin
  select d.id into v_disp
    from public.dispositivos d
   where d.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
     and d.activo;

  if v_disp is null then
    raise exception 'Token inválido o dispositivo inactivo' using errcode = '42501';
  end if;

  update public.comandos
     set ejecutado = now()
   where id = p_id
     and ejecutado is null
     and (id_dispositivo = v_disp or id_dispositivo is null);
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Mantenimiento (retención) y espacio
-- ---------------------------------------------------------------------
create or replace function public.mantenimiento_registros(
  p_dias_crudo   integer default 7,
  p_dias_archivo integer default 90
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_corte     timestamptz := date_trunc('hour', now() - make_interval(days => p_dias_crudo));
  v_resumidas integer;
  v_movidos   integer;
  v_borrados  integer;
begin
  -- 1. Resumen por hora de lo que sale de "registros"
  insert into public.registros_resumen as r (
    hora, n_lecturas, temp_prom, temp_min, temp_max, gas_prom, gas_min, gas_max,
    n_calor, n_gas, n_falla, n_sin_agua
  )
  select date_trunc('hour', fecha), count(*),
         avg(lectura_temperatura), min(lectura_temperatura), max(lectura_temperatura),
         avg(lectura_gas), min(lectura_gas), max(lectura_gas),
         count(*) filter (where calor), count(*) filter (where gas),
         count(*) filter (where falla), count(*) filter (where sin_agua)
    from public.registros
   where fecha < v_corte
   group by 1
  on conflict (hora) do update set
    temp_prom  = (r.temp_prom * r.n_lecturas + excluded.temp_prom * excluded.n_lecturas)
                 / (r.n_lecturas + excluded.n_lecturas),
    gas_prom   = (r.gas_prom * r.n_lecturas + excluded.gas_prom * excluded.n_lecturas)
                 / (r.n_lecturas + excluded.n_lecturas),
    temp_min   = least(r.temp_min, excluded.temp_min),
    temp_max   = greatest(r.temp_max, excluded.temp_max),
    gas_min    = least(r.gas_min, excluded.gas_min),
    gas_max    = greatest(r.gas_max, excluded.gas_max),
    n_calor    = r.n_calor + excluded.n_calor,
    n_gas      = r.n_gas + excluded.n_gas,
    n_falla    = r.n_falla + excluded.n_falla,
    n_sin_agua = r.n_sin_agua + excluded.n_sin_agua,
    n_lecturas = r.n_lecturas + excluded.n_lecturas;
  get diagnostics v_resumidas = row_count;

  -- 2. Mover el detalle al archivo
  with movidos as (
    delete from public.registros where fecha < v_corte
    returning id_registro, fecha, lectura_gas, lectura_temperatura, calor, gas, falla, sin_agua, agua_ml, id_dispositivo
  )
  insert into public.registros_archivo (
    id_registro, fecha, lectura_gas, lectura_temperatura, calor, gas, falla, sin_agua, agua_ml, id_dispositivo
  )
  select * from movidos
  on conflict (id_registro) do nothing;
  get diagnostics v_movidos = row_count;

  -- 3. Borrar del archivo lo más antiguo (queda el resumen)
  delete from public.registros_archivo where fecha < now() - make_interval(days => p_dias_archivo);
  get diagnostics v_borrados = row_count;

  return jsonb_build_object(
    'corte', v_corte,
    'horas_resumidas', v_resumidas,
    'movidos_al_archivo', v_movidos,
    'borrados_del_archivo', v_borrados
  );
end;
$$;

create or replace function public.uso_bd(p_limite_mb numeric default 500)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'mb', round(pg_database_size(current_database()) / 1024.0 / 1024.0, 1),
    'limite_mb', p_limite_mb,
    'porcentaje', round(pg_database_size(current_database()) / 1024.0 / 1024.0 / p_limite_mb * 100, 1),
    'tablas', (select jsonb_object_agg(relname, pg_size_pretty(pg_total_relation_size(relid)))
                 from pg_statio_user_tables where schemaname = 'public')
  );
$$;

create or replace function public.revisar_espacio_bd(p_alerta_pct numeric default 80)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uso jsonb := public.uso_bd();
begin
  if (v_uso ->> 'porcentaje')::numeric >= p_alerta_pct then
    perform public.enviar_telegram('💾 Base de datos al ' || (v_uso ->> 'porcentaje') || '% ('
      || (v_uso ->> 'mb') || ' MB de ' || (v_uso ->> 'limite_mb')
      || ' MB). Revisar PLAN_CONTINGENCIAS.md: "Base de datos llena".');
  end if;
  return v_uso;
end;
$$;

-- Tareas programadas (UTC). 07:00 UTC = 03:00 Bolivia; 12:00 UTC = 08:00 Bolivia
select cron.schedule('mantenimiento-registros', '0 7 * * *',  $cron$select public.mantenimiento_registros();$cron$);
select cron.schedule('control-espacio-bd',      '0 12 * * *', $cron$select public.revisar_espacio_bd();$cron$);

-- ---------------------------------------------------------------------
-- 10. Permisos: anon solo puede ejecutar las RPC del ESP32
-- ---------------------------------------------------------------------
drop policy if exists "anon puede insertar registros" on public.registros;
drop policy if exists "anon puede leer registros"     on public.registros;
drop policy if exists "anon puede insertar alertas"   on public.alertas;
drop policy if exists "anon puede leer alertas"       on public.alertas;

alter table public.registros enable row level security;
alter table public.alertas   enable row level security;

revoke all on table public.registros, public.alertas, public.dispositivos, public.comandos,
                    public.registros_archivo, public.registros_resumen
  from anon, authenticated;

-- Funciones internas: nadie externo puede llamarlas
revoke all on function public.enviar_telegram(text)                      from public, anon, authenticated;
revoke all on function public.notificar_alerta()                         from public, anon, authenticated;
revoke all on function public.crear_alerta()                             from public, anon, authenticated;
revoke all on function public.mantenimiento_registros(integer, integer)  from public, anon, authenticated;
revoke all on function public.uso_bd(numeric)                            from public, anon, authenticated;
revoke all on function public.revisar_espacio_bd(numeric)                from public, anon, authenticated;

-- RPC del ESP32
revoke all on function public.registrar_lectura(text, double precision, double precision, boolean, boolean,
  boolean, boolean, boolean, double precision, double precision, double precision, timestamptz)
  from public, anon, authenticated;
revoke all on function public.obtener_comando(text)            from public, anon, authenticated;
revoke all on function public.confirmar_comando(text, integer) from public, anon, authenticated;

grant execute on function public.registrar_lectura(text, double precision, double precision, boolean, boolean,
  boolean, boolean, boolean, double precision, double precision, double precision, timestamptz) to anon;
grant execute on function public.obtener_comando(text)            to anon;
grant execute on function public.confirmar_comando(text, integer) to anon;

commit;

-- Siguiente paso: supabase/configuracion_manual.sql (token del dispositivo y Telegram)
