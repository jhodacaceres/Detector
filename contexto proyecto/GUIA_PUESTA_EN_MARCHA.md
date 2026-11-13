# Guía de puesta en marcha (v3)

Sigue los pasos **en orden**. Cada paso indica cómo comprobar que salió bien antes de continuar.
Tiempo aproximado: 45–60 minutos.

> ⚠️ Desde el **paso 2**, el código viejo del ESP32 deja de poder guardar datos (error 401). Haz los pasos 2, 3 y 4 seguidos.

---

## Paso 1 (opcional, recomendado): respaldo de la base

**¿Qué es `pg_dump`?** Es un programa oficial de PostgreSQL (la base de datos que usa Supabase) que **copia toda la base a un archivo `.sql`**: tablas y datos. Si algo sale mal, ese archivo permite reconstruirla. `respaldo.ps1` solo lo ejecuta por ti, le pone la fecha al archivo y borra los respaldos viejos.

1. Instala PostgreSQL en PowerShell: `winget install PostgreSQL.PostgreSQL.17`
   (instala el servidor completo; solo usaremos su herramienta `pg_dump`).
2. Agrega `C:\Program Files\PostgreSQL\17\bin` al PATH: Inicio → "Editar las variables de entorno del sistema" → Variables de entorno → `Path` → Nuevo. **Cierra y vuelve a abrir** la terminal.
3. Obtén la cadena de conexión en Supabase: botón **Connect** (arriba) → **Session pooler** → copia la URI.
   - Reemplaza `[YOUR-PASSWORD]` por la contraseña de la base.
   - Si no la recuerdas: Project Settings → Database → **Reset database password**.
4. Pégala en `.env.local` (raíz del proyecto): `SUPABASE_DB_URL=postgresql://...`
5. En la carpeta `Detector`, ejecuta: `powershell -ExecutionPolicy Bypass -File supabase\respaldo.ps1`

✅ **Comprobación:** aparece `Respaldo listo: X KB` y existe el archivo `respaldos\AAAA-MM-DD_HHmm.sql`.

---

## Paso 2: migración de la base

1. Supabase → **SQL Editor** → **New query**.
2. Abre `supabase/migracion_v3.sql`, copia **todo** su contenido, pégalo y pulsa **Run**.
3. Si aparece un error con `pg_cron` o `pg_net`: Database → **Extensions** → activa `pg_cron` y `pg_net` → ejecuta de nuevo (es seguro repetirlo).

✅ **Comprobación:** "Success". En Table Editor aparecen las tablas `dispositivos`, `comandos` y `registros_resumen`.

4. Después, en una consulta nueva, haz lo mismo con `supabase/migracion_v4.sql` (normalización).
   Si ya subiste el firmware anterior, **vuelve a subirlo** después de la v4 (paso 4): la función que recibe los datos cambió.

---

## Paso 3: token del ESP32

1. SQL Editor → nueva consulta → pega **solo el PASO 1** de `supabase/configuracion_manual.sql` (el bloque `with nuevo as ... from nuevo, alta;`) → **Run**.
2. Copia el valor de la columna **`copiar_a_secrets_h`**. Se muestra **una sola vez**.
3. Abre `ESP32/detector/secrets.h` (**no** `secrets.example.h`) y pégalo:
   `#define DEVICE_TOKEN  "el_token_copiado"`

✅ **Comprobación:** en Table Editor → `dispositivos` hay una fila "ESP32 detector".

> Si perdiste el token: `update public.dispositivos set activo = false;` y repite este paso.

---

## Paso 4: subir el firmware al ESP32

1. Arduino IDE → **Archivo → Abrir** → `ESP32/detector/detector.ino`.
   Arriba deben aparecer las pestañas `detector.ino`, `secrets.example.h` y `secrets.h`.
2. **Herramientas → Placa → ESP32 Dev Module** y elige el puerto COM.
3. Pulsa **Subir** (→).
4. **Herramientas → Monitor Serie**, a **115200** baudios.

✅ **Comprobación en el Monitor Serie:**
- `=== Detector v3 ===` y el motivo del reinicio.
- Cada segundo: `Temp: ... | Gas (V): ... | ... WiFi=ok`.
- **No** aparecen líneas `[Supabase] ... HTTP 4xx`.
- En Supabase → Table Editor → `registros` llegan filas nuevas cada unos 5 s, con `id_dispositivo = 1`.

**Si algo falla:**

| Mensaje | Causa | Solución |
|---|---|---|
| `HTTP 401` / `42501` | Token incorrecto | Repetir el paso 3 |
| `HTTP 404` | No se ejecutó la migración | Repetir el paso 2 |
| `WiFi=sin conexión` siempre | Red de 5 GHz o contraseña mal escrita | Revisar `secrets.h` |
| Error de compilación | — | Copia el error y pídeme ayuda |

---

## Paso 5: bot de Telegram

1. En Telegram, busca **@BotFather** → `/newbot` → ponle un nombre → copia el **token** (`123456:ABC...`).
2. Abre tu bot y envíale cualquier mensaje (por ejemplo "hola").
3. En el navegador abre `https://api.telegram.org/bot<TOKEN>/getUpdates` y copia el número de `"chat":{"id": ...}`.
4. SQL Editor (**no** lo guardes en ningún archivo):
   ```sql
   select vault.create_secret('<TOKEN_DEL_BOT>', 'telegram_bot_token', 'Bot de alertas');
   select vault.create_secret('<CHAT_ID>', 'telegram_chat_id', 'Chats de alertas');
   ```
   Para que avise a varias personas, cada una envía un mensaje al bot y se ponen los IDs separados por coma: `'111,222'`.
5. Prueba: `select public.enviar_telegram('Prueba del detector ✅');`

✅ **Comprobación:** el mensaje llega al celular.

---

## Paso 6: variables de entorno en Vercel

1. Supabase → Project Settings → **API Keys** → sección **Secret keys** → crea o copia la key `sb_secret_...`.
   ⚠️ Esta key tiene **acceso total**: nunca la pegues en código, en chats ni en GitHub.
2. Vercel → tu proyecto → **Settings → Environment Variables** → agrega:

   | Nombre | Valor |
   |---|---|
   | `SUPABASE_URL` | `https://wvmvjwwggquhsvdabmng.supabase.co` |
   | `SUPABASE_SECRET_KEY` | la key `sb_secret_...` |
   | `ADMIN_PIN` | una frase de 8 caracteres o más (es el PIN del botón Reiniciar) |

3. Escribe los mismos valores en `.env.local`.

---

## Paso 7: subir el código a GitHub (Vercel se actualiza solo)

1. En la carpeta `Detector`: `git status`.
   **No** deben aparecer `secrets.h` ni `.env.local`.
2. `git add -A` → `git commit -m "v3: seguridad, contingencias, agua y retención"` → `git push`.
3. Vercel → **Deployments**: espera el estado **Ready**.

✅ **Comprobación:**
- `https://TU-APP.vercel.app/api/estado` muestra un JSON con `"ultimo"`.
- La web muestra los datos y "Sistema normal" (o "Precalentando" durante el primer minuto).

---

## Paso 8: keepalive de Supabase

1. GitHub → repositorio → **Settings → Secrets and variables → Actions** → pestaña **Variables** → **New repository variable**:
   - Nombre: `URL_APP`
   - Valor: `https://TU-APP.vercel.app` (sin `/` al final)
2. Pestaña **Actions** → "Keepalive Supabase" → **Run workflow**.

✅ **Comprobación:** marca verde y `HTTP 200` en el log.

---

## Paso 9: medir el caudal de las bombas

1. Pon una bomba a llenar un vaso medidor durante **10 s** (o fuerza el calor con un secador).
2. `CAUDAL_ML_POR_S = ml llenados ÷ 10`. Ajústalo en `detector.ino` junto con `CAPACIDAD_ML` (lo que realmente cabe en tu depósito).
3. Vuelve a subir el firmware.

---

## Paso 10: prueba completa

Haz el **checklist** de [`PLAN_CONTINGENCIAS.md`](PLAN_CONTINGENCIAS.md) (10 puntos). Además:

- **Botón Reiniciar:**
  - Con un PIN incorrecto → "PIN incorrecto".
  - Con el PIN correcto → el ESP32 se reinicia en 5–10 s y el agua vuelve al 100 %.
- **Sin WiFi:** apaga el router, acerca calor → las bombas y el buzzer funcionan igual. Al encender el router, llegan las alertas a Telegram con la hora real.
- **Sin agua:** con `CAPACIDAD_ML = 100` y calor sostenido → bombas bloqueadas, aviso "🚱" y la web lo muestra. Luego vuelve a poner el valor real.
