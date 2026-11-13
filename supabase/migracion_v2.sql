-- =====================================================================
-- Migración v2: ESP32 -> Supabase (única fuente) | Web solo lectura
-- Ejecutar UNA vez en Supabase -> SQL Editor.
-- =====================================================================

-- 1. Estados calculados por el ESP32 (así los umbrales viven en un solo lugar)
alter table public.registros
  add column if not exists calor boolean not null default false,
  add column if not exists gas   boolean not null default false;

-- 2. Corregir la fecha por defecto.
--    "now() AT TIME ZONE 'America/La_Paz'" devuelve una hora local SIN zona,
--    que Postgres vuelve a interpretar como UTC -> quedaba 4 h corrida.
--    timestamptz siempre guarda el instante real; la zona se aplica al mostrar.
alter table public.registros
  alter column fecha set default now();

-- 3. Fecha de la alerta
alter table public.alertas
  add column if not exists fecha timestamptz not null default now();

-- 4. Trigger: cada registro con gas o calor genera su alerta automáticamente
create or replace function public.crear_alerta()
returns trigger
language plpgsql
security definer          -- inserta en alertas aunque anon no tenga permiso
set search_path = public
as $$
begin
  if new.gas or new.calor then
    insert into public.alertas (id_registro) values (new.id_registro);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_crear_alerta on public.registros;
create trigger trg_crear_alerta
after insert on public.registros
for each row execute function public.crear_alerta();

-- 5. RLS: el ESP32 solo inserta registros; la web solo lee
alter table public.registros enable row level security;
alter table public.alertas   enable row level security;

drop policy if exists "anon puede insertar registros" on public.registros;
drop policy if exists "anon puede leer registros"     on public.registros;
drop policy if exists "anon puede insertar alertas"   on public.alertas;
drop policy if exists "anon puede leer alertas"       on public.alertas;

create policy "anon puede insertar registros"
  on public.registros for insert to anon
  with check (true);

create policy "anon puede leer registros"
  on public.registros for select to anon
  using (true);

create policy "anon puede leer alertas"
  on public.alertas for select to anon
  using (true);

-- 6. Índice para leer rápido el último registro
create index if not exists registros_fecha_idx on public.registros (fecha desc);
