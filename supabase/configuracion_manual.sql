-- =====================================================================
-- Configuración manual (después de migracion_v3.sql)
-- Ejecuta cada PASO por separado en Supabase -> SQL Editor.
-- Este archivo NO debe contener valores reales: escríbelos solo en el editor.
-- =====================================================================


-- PASO 1. Alta del ESP32: genera un token y guarda solo su hash.
--         Copia el valor de "copiar_a_secrets_h" en ESP32/detector/secrets.h (DEVICE_TOKEN).
--         Se muestra UNA sola vez: si lo pierdes, revoca (paso 4) y repite.
with nuevo as (
  select encode(extensions.gen_random_bytes(24), 'hex') as token
),
alta as (
  insert into public.dispositivos (nombre, token_hash)
  select 'ESP32 detector', encode(extensions.digest(token, 'sha256'), 'hex') from nuevo
  returning id
)
select nuevo.token as copiar_a_secrets_h, alta.id as id_dispositivo
  from nuevo, alta;


-- PASO 2. Telegram
--   a) En Telegram, habla con @BotFather -> /newbot -> copia el token del bot.
--   b) Escríbele cualquier mensaje a tu bot.
--   c) Abre https://api.telegram.org/bot<TOKEN>/getUpdates y copia "chat":{"id": ...}
--   d) Reemplaza los valores y ejecuta (varios chats: separados por coma "111,222"):
-- select vault.create_secret('<TOKEN_DEL_BOT>', 'telegram_bot_token', 'Bot de alertas del detector');
-- select vault.create_secret('<CHAT_ID>',       'telegram_chat_id',   'Chats que reciben alertas');

-- Para cambiar un valor ya guardado:
-- select vault.update_secret((select id from vault.secrets where name = 'telegram_chat_id'), '<NUEVO_VALOR>');


-- PASO 3. Pruebas
-- select public.enviar_telegram('Prueba del detector ✅');        -- debe llegar al celular
-- select * from net._http_response order by created desc limit 5; -- respuesta de Telegram
-- select public.uso_bd();                                          -- espacio usado
-- select public.mantenimiento_registros();                         -- retención manual
-- select * from cron.job;                                          -- tareas programadas
-- select * from cron.job_run_details order by start_time desc limit 10;


-- PASO 4. Revocar un dispositivo (token robado o perdido)
-- update public.dispositivos set activo = false where id = <ID>;
-- Luego repetir el PASO 1 y cargar el token nuevo en secrets.h.
