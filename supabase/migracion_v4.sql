-- =====================================================================
-- Migración v4: normalización (se ejecuta DESPUÉS de migracion_v3.sql)
--
--  1. La configuración del depósito (capacidad, caudal, reserva, bombas) pasa a
--     "dispositivos": es un dato del dispositivo, no de cada lectura (3FN).
--  2. Se elimina registros.autonomia_s (dato derivado: se calcula en /api/estado).
--  3. Se elimina registros_archivo: era la misma entidad que "registros" partida
--     en dos y rompía la relación alertas -> registros. Ahora "registros" guarda
--     90 días de detalle y luego queda solo el resumen por hora.
--  4. registros_resumen se relaciona con dispositivos (FK) y tiene clave propia.
--
-- Desnormalización INTENCIONAL que se mantiene: alertas guarda una copia de
-- fecha / temperatura / gas ("foto" del momento) para conservar la alerta
-- aunque su registro se borre a los 90 días.
--
-- Idempotente y en una transacción. Hacer respaldo antes (supabase/respaldo.ps1).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Configuración del depósito en dispositivos
-- ---------------------------------------------------------------------
alter table public.dispositivos
  add column if not exists capacidad_ml     double precision,
  add column if not exists caudal_ml_por_s  double precision,
  add column if not exists reserva_ml       double precision,
  add column if not exists num_bombas       integer;

-- Conservar la última capacidad que se había guardado por lectura
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'registros' and column_name = 'capacidad_ml') then
    update public.dispositivos d
       set capacidad_ml = r.capacidad_ml
      from (select distinct on (id_dispositivo) id_dispositivo, capacidad_ml
              from public.registros
             where id_dispositivo is not null and capacidad_ml is not null
             order by id_dispositivo, id_registro desc) r
     where d.id = r.id_dispositivo
       and d.capacidad_ml is null;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. Devolver a "registros" lo que se hubiera archivado y eliminar el archivo
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.registros_archivo') is not null then
    -- Sin trigger: devolver filas antiguas no debe generar alertas ni mensajes de Telegram
    alter table public.registros disable trigger trg_crear_alerta;

    insert into public.registros (
      id_registro, fecha, lectura_gas, lectura_temperatura, calor, gas, falla, sin_agua, agua_ml, id_dispositivo
    ) overriding system value
    select id_registro, fecha, lectura_gas, lectura_temperatura,
           coalesce(calor, false), coalesce(gas, false), coalesce(falla, false), coalesce(sin_agua, false),
           agua_ml, id_dispositivo
      from public.registros_archivo
    on conflict (id_registro) do nothing;

    alter table public.registros enable trigger trg_crear_alerta;

    -- Volver a enlazar las alertas que habían perdido su registro
    update public.alertas a
       set id_registro = r.id_registro
      from public.registros r
     where a.id_registro is null
       and r.fecha = a.fecha;

    drop table public.registros_archivo;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. Columnas que ya no corresponden a "registros"
-- ---------------------------------------------------------------------
alter table public.registros
  drop column if exists capacidad_ml,
  drop column if exists autonomia_s;

-- ---------------------------------------------------------------------
-- 4. registros_resumen: clave propia + relación con dispositivos
-- ---------------------------------------------------------------------
alter table public.registros_resumen
  add column if not exists id_dispositivo integer references public.dispositivos(id) on delete set null;

do $$
begin
  -- La PK anterior era solo "hora": no admite varios dispositivos
  if exists (select 1 from pg_constraint
             where conrelid = 'public.registros_resumen'::regclass and contype = 'p'
               and conname = 'registros_resumen_pkey'
               and not exists (select 1 from information_schema.columns
                               where table_schema = 'public' and table_name = 'registros_resumen'
                                 and column_name = 'id')) then
    alter table public.registros_resumen drop constraint registros_resumen_pkey;
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'registros_resumen' and column_name = 'id') then
    alter table public.registros_resumen add column id integer generated always as identity primary key;
  end if;
end $$;

alter table public.registros_resumen alter column hora set not null;

-- Una fila por hora y dispositivo (0 = registros antiguos sin dispositivo)
create unique index if not exists registros_resumen_hora_disp_uq
  on public.registros_resumen (hora, (coalesce(id_dispositivo, 0)));

-- ---------------------------------------------------------------------
-- 5. RPC del ESP32 (nueva firma: la configuración va a dispositivos)
-- ---------------------------------------------------------------------
drop function if exists public.registrar_lectura(text, double precision, double precision, boolean, boolean,
  boolean, boolean, boolean, double precision, double precision, double precision, timestamptz);

create or replace function public.registrar_lectura(
  p_token            text,
  p_temperatura      double precision,
  p_gas              double precision,
  p_calor            boolean,
  p_alerta_gas       boolean,
  p_falla            boolean          default false,
  p_sin_agua         boolean          default false,
  p_precalentando    boolean          default false,
  p_agua_ml          double precision default null,
  p_capacidad_ml     double precision default null,
  p_caudal_ml_por_s  double precision default null,
  p_reserva_ml       double precision default null,
  p_num_bombas       integer          default null,
  p_fecha            timestamptz      default null
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

  if p_fecha is not null and p_fecha between now() - interval '24 hours' and now() + interval '1 minute' then
    v_fecha := p_fecha;
  end if;

  insert into public.registros (
    fecha, lectura_temperatura, lectura_gas, calor, gas, falla, sin_agua, precalentando, agua_ml, id_dispositivo
  ) values (
    v_fecha, p_temperatura, p_gas, p_calor, p_alerta_gas, p_falla, p_sin_agua, p_precalentando, p_agua_ml, v_id
  );

  -- Configuración del depósito: se guarda una vez en el dispositivo (solo si viene)
  update public.dispositivos
     set ultimo_envio    = now(),
         capacidad_ml    = coalesce(p_capacidad_ml, capacidad_ml),
         caudal_ml_por_s = coalesce(p_caudal_ml_por_s, caudal_ml_por_s),
         reserva_ml      = coalesce(p_reserva_ml, reserva_ml),
         num_bombas      = coalesce(p_num_bombas, num_bombas)
   where id = v_id;
end;
$$;

revoke all on function public.registrar_lectura(text, double precision, double precision, boolean, boolean,
  boolean, boolean, boolean, double precision, double precision, double precision, double precision, integer, timestamptz)
  from public, anon, authenticated;
grant execute on function public.registrar_lectura(text, double precision, double precision, boolean, boolean,
  boolean, boolean, boolean, double precision, double precision, double precision, double precision, integer, timestamptz)
  to anon;

-- ---------------------------------------------------------------------
-- 6. Retención: 90 días de detalle en "registros", luego solo resumen
-- ---------------------------------------------------------------------
drop function if exists public.mantenimiento_registros(integer, integer);

create or replace function public.mantenimiento_registros(p_dias integer default 90)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_corte     timestamptz := date_trunc('hour', now() - make_interval(days => p_dias));
  v_resumidas integer;
  v_borrados  integer;
begin
  -- 1. Resumen por hora y dispositivo de lo que se va a borrar
  insert into public.registros_resumen as r (
    hora, id_dispositivo, n_lecturas, temp_prom, temp_min, temp_max, gas_prom, gas_min, gas_max,
    n_calor, n_gas, n_falla, n_sin_agua
  )
  select date_trunc('hour', fecha), id_dispositivo, count(*),
         avg(lectura_temperatura), min(lectura_temperatura), max(lectura_temperatura),
         avg(lectura_gas), min(lectura_gas), max(lectura_gas),
         count(*) filter (where calor), count(*) filter (where gas),
         count(*) filter (where falla), count(*) filter (where sin_agua)
    from public.registros
   where fecha < v_corte
   group by 1, 2
  on conflict (hora, (coalesce(id_dispositivo, 0))) do update set
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

  -- 2. Borrar el detalle (las alertas se conservan con su "foto"; id_registro queda en null)
  delete from public.registros where fecha < v_corte;
  get diagnostics v_borrados = row_count;

  return jsonb_build_object('corte', v_corte, 'horas_resumidas', v_resumidas, 'registros_borrados', v_borrados);
end;
$$;

revoke all on function public.mantenimiento_registros(integer) from public, anon, authenticated;

-- La tarea programada de v3 llama a mantenimiento_registros() sin argumentos: sigue funcionando
select cron.schedule('mantenimiento-registros', '0 7 * * *', $cron$select public.mantenimiento_registros();$cron$);

-- ---------------------------------------------------------------------
-- 7. Permisos de las tablas (por si alguna cambió)
-- ---------------------------------------------------------------------
revoke all on table public.registros, public.alertas, public.dispositivos, public.comandos, public.registros_resumen
  from anon, authenticated;

commit;
