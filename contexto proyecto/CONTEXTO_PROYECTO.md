# Contexto del proyecto: Detector de Gas y Temperatura (ESP32)

> Este archivo da contexto a una IA o asistente sobre el estado del proyecto.
> Las credenciales se muestran como marcadores `<...>`. Los valores reales están **solo** en `ESP32/detector/secrets.h`, `.env.local` y las variables de entorno de Vercel, todos fuera de git.
> Última actualización: 2026-11-13 (v3).
> Ver también: [`PLAN_CONTINGENCIAS.md`](PLAN_CONTINGENCIAS.md).

## 1. Qué es

Es un sistema IoT de demostración que **simula un sistema real de seguridad**: debe contemplar todo lo que puede fallar.

1. Mide la **temperatura** (LM35) y el **gas CO** (MQ-7) con un ESP32.
2. Actúa en el lugar, **con o sin internet**:
   - **Gas** → buzzer continuo.
   - **Calor** → 2 bombas de agua (relé de 2 canales) con un **depósito limitado**. Al agotarse el agua, las bombas se bloquean.
   - **Falla de sensor** → pitidos cortos.
   - **Sin agua** → pitido largo y alterno.
3. Guarda las lecturas en **Supabase** mediante una RPC autenticada con el token del dispositivo.
4. Avisa por **Telegram** cuando ocurre un evento (alerta y normalización).
5. Muestra el estado en una **web en Vercel**, que lee mediante funciones del servidor; ninguna key llega al navegador. La web permite **reiniciar el ESP32** con un PIN después de recargar el depósito.

## 2. Arquitectura (v3)

```
┌─────────────┐  RPC registrar_lectura (token)   ┌──────────────────── Supabase ────────────────────┐
│   ESP32     │ ───────────────────────────────▶ │ registros ─trigger─▶ alertas ─trigger─▶ Telegram  │
│ core1: alarma│ ◀── RPC obtener/confirmar_comando│ comandos   dispositivos   (pg_net + Vault)        │
│ core0: red  │                                   │ pg_cron: retención diaria + control de espacio    │
└─────────────┘                                   └───────────────▲──────────────────────────────────┘
                                                                  │ secret key (solo en el servidor)
┌─────────────┐   GET /api/estado  · POST /api/comando  ┌─────────┴────────┐
│ Navegador   │ ───────────────────────────────────────▶│ Vercel Functions │
└─────────────┘   (sin keys)                            └──────────────────┘
GitHub Actions (keepalive cada 3 días) ──▶ /api/estado ──▶ evita que Supabase se pause
```

**Permisos:**
- La key **publishable** del ESP32 (rol `anon`) **solo** puede ejecutar 3 RPC: `registrar_lectura`, `obtener_comando` y `confirmar_comando`. No tiene acceso directo a ninguna tabla.
- La **secret key** solo existe en Vercel y en `.env.local`. Con ella, `/api/estado` lee y `/api/comando` inserta comandos.
- Firebase se usó en V1 y **ya no se usa**.

## 3. Estructura de carpetas

```
Detector/
├── index.html                 # Dashboard: temperatura, gas, agua/bombas, alertas, botón de reinicio
├── app.js                     # Consulta /api/estado cada 2 s y envía /api/comando
├── api/
│   ├── _supabase.js           # Utilidades compartidas (no es un endpoint)
│   ├── estado.js              # GET: última lectura y 5 alertas
│   └── comando.js             # POST {pin}: ordena reiniciar el ESP32
├── vercel.json                # Encabezados de seguridad (CSP, etc.)
├── .env.example               # Plantilla de variables (versionada)
├── .env.local                 # Valores reales (IGNORADO)
├── .gitignore                 # .env, .env*.local, secrets.h, respaldos/, .vercel
├── .github/workflows/keepalive.yml
├── ESP32/
│   ├── detector/
│   │   ├── detector.ino       # Firmware v3
│   │   ├── secrets.example.h  # Plantilla de credenciales
│   │   └── secrets.h          # Credenciales reales (IGNORADO)
│   └── conexiones_esp32_gas.xlsx
├── supabase/
│   ├── migracion_v2.sql       # Ya aplicada
│   ├── migracion_v3.sql       # Seguridad, eventos, Telegram, comandos, retención
│   ├── configuracion_manual.sql  # Token del dispositivo, Telegram, pruebas
│   └── respaldo.ps1           # pg_dump con rotación (8 respaldos)
└── contexto proyecto/
    ├── CONTEXTO_PROYECTO.md   # Este archivo
    ├── PLAN_CONTINGENCIAS.md
    └── GUIA_PUESTA_EN_MARCHA.md  # Pasos de instalación en orden
```

Repositorio: GitHub `jhodacaceres/Detector`, rama `main`. Cada push a GitHub publica automáticamente en Vercel.

## 4. Hardware

| Componente | Detalle |
|---|---|
| ESP32 | Con WiFi de 2.4 GHz. ADC1: GPIO34 y GPIO35, que funcionan con el WiFi activo |
| LM35 | Temperatura, 10 mV/°C, alimentado a 5 V (su salida nunca supera 1.5 V) |
| MQ-7 | Módulo con R1–R4 y C2–C3, AOUT a GPIO35, alimentado a 5 V |
| Relé | Módulo de 2 canales **SRD-05VDC-SL-C**, VCC a 5 V, activo en LOW |
| Bombas | 2 bombas de agua de 5 V conectadas a COM/NO de cada relé |
| Depósito | **500 ml** como referencia mínima; en un caso real la capacidad la define el usuario |
| Buzzer | Mediante transistor NPN y resistor de 1 kΩ en GPIO27 |
| Fuente | 5 V (cable USB adaptado), con un riel de 5 V y GND común |

### Pines

| GPIO | Uso | Lógica |
|---|---|---|
| 34 | LM35 | Analógico |
| 35 | MQ-7 AOUT | Analógico |
| 25 | Relé IN1 → bomba 1 | **Encender:** `OUTPUT` + `LOW`. **Apagar:** `INPUT` (alta impedancia) |
| 26 | Relé IN2 → bomba 2 | Igual que el GPIO25 |
| 27 | Buzzer | `HIGH` = suena |

La tabla completa de conexiones está en `ESP32/conexiones_esp32_gas.xlsx` (25 conexiones).

**¿Por qué el relé se apaga con `INPUT`?** El módulo funciona a 5 V y el ESP32 entrega solo 3.3 V en HIGH, lo que a veces no alcanza para apagarlo. En alta impedancia no circula corriente y el relé se apaga con seguridad. Además, al arrancar los pines ya son entradas, así que las bombas empiezan apagadas. Si un módulo se encendiera con `INPUT`, se cambia `APAGAR_RELE_CON_INPUT = false`.

## 5. Firmware (`ESP32/detector/detector.ino`)

### Fórmulas en uso (no modificar sin acordarlo)

```cpp
temp      = ((analogReadMilliVolts(34) * 3.3) / 4095.0) * 100.0;                     // °C
valor_mq7 = ((analogReadMilliVolts(35) * 3.3) / 4095.0) * FACTOR_DIVISOR_MQ7;        // V
```

- `analogReadMilliVolts()` ya devuelve milivoltios calibrados con los datos de fábrica del chip. Esos datos se graban una sola vez en la memoria **eFuse** del ESP32.
- La escala `3.3/4095` corresponde a `analogRead()` (valor crudo de 0 a 4095). Al aplicarla sobre milivoltios, **los valores salen alrededor de un 20 % más bajos** que los reales (25 °C reales se ven como unos 20 °C).
- **Se mantienen así por decisión del proyecto.** Los umbrales están expresados en esta misma escala.
- `FACTOR_DIVISOR_MQ7 = 1.0`. Si se agrega un divisor de 10k/20k, pasa a `1.5`.
- **Historia:** V1 (commit `6cbd540`) usaba `temp = (mV − 78.05)/8.627` y el gas como Rs/R0 con `R0 = 1655` (`gas = ratio < 10`). Ya no se usa.

### Umbrales (con histéresis, para que el relé no oscile)

| Señal | Activa | Desactiva |
|---|---|---|
| Calor (bombas) | `temp > 45` | `temp < 43` |
| Gas (buzzer) | `valor_mq7 > 1.5` | `valor_mq7 < 1.3` |

### Estados y comportamiento

| Estado | Condición | Acción |
|---|---|---|
| Precalentamiento | Primeros 60 s tras arrancar | El gas no se evalúa; la temperatura sí |
| Falla de sensor | `temp < 1` o `temp > 125`; `gas < 0.01` (después del precalentamiento) | 2 pitidos cortos por segundo y alerta. **Si falla el LM35 con las bombas encendidas, siguen encendidas** (un incendio puede quemar el sensor) |
| Sin agua | Contador ≤ `RESERVA_ML` | Bombas bloqueadas aunque siga el calor, pitido largo alterno y alerta |

**Prioridad del buzzer:** gas (continuo) > falla > sin agua.

### Control de agua (estimado, no hay sensor de nivel)

- `CAPACIDAD_ML = 500` y `RESERVA_ML = 50`.
- **`CAUDAL_ML_POR_S = 0` = SIN CALIBRAR (estado actual).** El caudal no se ha medido y **no se asume ningún valor**. Mientras sea 0:
  - **Firmware:** no descuenta agua ni bloquea las bombas (funcionan mientras haya calor), envía `agua_ml = null` y avisa en el Monitor Serie.
  - **Web:** muestra "Caudal SIN CALIBRAR" y la franja pide **vigilar el depósito a la vista**.
  - **Riesgo activo:** las bombas pueden trabajar en seco.
- **Para calibrarlo:** una bomba llena un vaso durante 10 s; `caudal = ml ÷ 10`. Se pone ese valor en el firmware y se vuelve a subir. El control se activa solo: `agua -= bombas × caudal × dt` y el bloqueo ocurre al llegar a `RESERVA_ML`.
- Al arrancar se asume el **depósito lleno**. Para recargar: llenar el depósito y reiniciar desde la web (con PIN) o con el botón EN de la placa.

### Red y robustez

- **El control local nunca depende de la red.**
  - El `loop`, en el core 1, lee y actúa cada 1 s.
  - La tarea `tareaRed`, en el core 0, envía los datos.
  - No hay `while` bloqueante esperando el WiFi.
- **Envío:**
  - Cada 5 s, la última lectura (`xQueueOverwrite`).
  - En cada cambio de `calor`, `gas`, `falla` o `sin_agua`, un **evento** en un buffer de 50 que se conserva sin red y se envía al volver.
- **Hora:** NTP (UTC−4). Los eventos se envían con su hora real (`p_fecha`).
- **Errores:** reintentos con espera creciente de 5 s a 60 s; reconexión forzada del WiFi cada 30 s; timeouts de HTTP de 3 s y de TLS de 5 s.
- **Watchdog** de 10 s en el `loop`. Al arrancar se imprime el motivo del reinicio: watchdog, brownout, comando remoto, etc.
- **Comandos remotos:** cada unos 5 s llama a `obtener_comando`. Si hay un `reiniciar` con menos de 2 minutos de antigüedad, lo confirma y ejecuta `ESP.restart()`.
- `client.setInsecure()`: HTTPS sin validar el certificado (limitación conocida del prototipo).

### Credenciales (`secrets.h`, ignorado por git)

`WIFI_SSID`, `WIFI_PASS`, `SUPABASE_URL`, `SUPABASE_KEY` (`sb_publishable_...`) y `DEVICE_TOKEN`.

## 6. Supabase

### Tablas

| Tabla | Contenido | Acceso de `anon` |
|---|---|---|
| `dispositivos` | `id`, `nombre`, `token_hash` (SHA-256), `activo`, `ultimo_envio`, `capacidad_ml`, `caudal_ml_por_s`, `reserva_ml`, `num_bombas` | Ninguno |
| `registros` | `id_registro`, `fecha` (timestamptz, `now()`), `fecha_bolivia` (generada), `lectura_temperatura`, `lectura_gas`, `calor`, `gas`, `falla`, `sin_agua`, `precalentando`, `agua_ml`, `id_dispositivo` (FK) | Ninguno |
| `alertas` | `id_alertas`, `id_registro` (FK `on delete set null`), `fecha`, `fecha_bolivia`, `tipo` (`gas`/`calor`/`falla`/`sin_agua`), `lectura_temperatura`, `lectura_gas`, `notificada` | Ninguno |
| `comandos` | `id`, `id_dispositivo` (FK; null = todos), `comando` (`reiniciar`), `creado`, `ejecutado` | Ninguno |
| `registros_resumen` | `id`, `hora`, `id_dispositivo` (FK), promedio, mínimo y máximo de temperatura y gas, conteos de estados. Único por (hora, dispositivo) | Ninguno |

### Modelo y normalización (v4)

```
dispositivos 1 ──< registros 1 ──< alertas
     │ 1
     ├──< comandos
     └──< registros_resumen
```

- **3FN:**
  - La configuración del depósito (capacidad, caudal, reserva, bombas) depende del **dispositivo**, así que está en `dispositivos` y no se repite en cada lectura.
  - La autonomía es un **dato derivado**: no se guarda, la calcula `/api/estado`.
- **Desnormalización intencional:** `alertas` copia `fecha`, `lectura_temperatura` y `lectura_gas` como una "foto" del momento. A los 90 días el registro se borra (`id_registro` queda en null), pero la alerta se conserva completa.
- **Derivado seguro:** `fecha_bolivia` es una columna generada, así que la base la mantiene siempre coherente.
- **No todas las tablas necesitan relacionarse:** una FK solo existe si hay una relación real. Aun así, todas las tablas actuales se relacionan con `dispositivos`.
- **Historia:** la v3 tenía `registros_archivo`, que era la misma entidad partida por antigüedad y rompía la relación alertas → registros. Se eliminó en la v4.

**Fecha:**
- `fecha` guarda el instante real (UTC).
- `fecha_bolivia` muestra la hora de La Paz en el Table Editor.
- Las filas anteriores a v2 tienen la fecha desfasada 4 horas, por el default `now() AT TIME ZONE ...` de la versión original. No se corrigen.

### Funciones

| Función | Quién la usa | Qué hace |
|---|---|---|
| `registrar_lectura(p_token, p_temperatura, p_gas, p_calor, p_alerta_gas, p_falla, p_sin_agua, p_precalentando, p_agua_ml, p_capacidad_ml, p_caudal_ml_por_s, p_reserva_ml, p_num_bombas, p_fecha)` | ESP32 (`anon`) | Valida el token y la frecuencia (1/s, HTTP 429), valida rangos, inserta la lectura y actualiza la configuración del depósito en `dispositivos` |
| `obtener_comando(p_token)` / `confirmar_comando(p_token, p_id)` | ESP32 (`anon`) | Comandos remotos |
| `crear_alerta()` (trigger en `registros`) | Interno | Alerta **solo al cambiar** un estado de false a true; aviso de "Normalizado" al volver de true a false |
| `notificar_alerta()` (trigger en `alertas`) | Interno | Envía el aviso a Telegram y marca `notificada` |
| `enviar_telegram(texto)` | Interno | `pg_net` hacia la API de Telegram; secretos en Vault; admite varios chats separados por coma |
| `mantenimiento_registros(90)` | `pg_cron` a las 03:00 de Bolivia | Resume por hora y dispositivo lo que tiene más de 90 días y luego lo borra |
| `uso_bd()` / `revisar_espacio_bd(80)` | `pg_cron` a las 08:00 de Bolivia | Avisa por Telegram si la base supera el 80 % de 500 MB |

### Retención

```
registros (90 días, detalle) ──diario 03:00──▶ registros_resumen (1 fila/hora/dispositivo, para siempre)
                              └──────────────▶ se borra
alertas: para siempre (con su "foto" de valores)
```

**Rapidez:** la web lee la última fila mediante índices (`id_registro`, `fecha`), así que el tamaño de la tabla no la hace lenta. **Espacio estimado:** unas 17 000 filas por día enviando cada 5 s y funcionando las 24 h; 90 días ≈ 200 MB de los 500 MB del plan gratuito. Si se acerca al 80 %, llega un aviso por Telegram (ver `PLAN_CONTINGENCIAS.md`, Procedimiento A).

### Orden de instalación

1. Respaldo con `supabase/respaldo.ps1`.
2. `migracion_v3.sql` y luego `migracion_v4.sql`.
3. `configuracion_manual.sql`:
   - Paso 1: token → `secrets.h`.
   - Paso 2: secretos de Telegram en Vault.
   - Paso 3: pruebas.

## 7. Web (Vercel)

- **Variables de entorno en Vercel:** `SUPABASE_URL`, `SUPABASE_SECRET_KEY` y `ADMIN_PIN` (8 caracteres o más). Las mismas van en `.env.local` para trabajar en local.
- `GET /api/estado`:
  - Devuelve `{ ultimo, alertas[5], servidor }`.
  - Lo cachea la CDN durante 2 s.
  - Sin variables configuradas o si falla Supabase, responde `503`.
- `POST /api/comando` con `{pin}`:
  - `401`: PIN incorrecto (con 1 s de espera).
  - `429`: hay un comando pendiente o pasaron menos de 30 s desde el anterior.
  - `200`: comando creado.
- **Interfaz:**
  - Franja de estado. Prioridad: sin datos > sin agua > gas > falla > calor > precalentamiento > normal.
  - Tarjetas de temperatura, gas y agua (barra, autonomía, estado de las bombas).
  - Últimas alertas.
  - Botón de reinicio con PIN y confirmación.
- `vercel.json`: CSP `default-src 'self'`, `X-Frame-Options: DENY`, `nosniff`, `no-referrer`.
- **Limitación:** `/api/estado` es público. Cualquiera puede ver el estado actual, pero no el historial ni otras tablas.

## 8. Operación

- **Keepalive:** el workflow de GitHub llama a `/api/estado` cada 3 días. Requiere la *repository variable* `URL_APP`.
- **Respaldos:** `powershell -ExecutionPolicy Bypass -File supabase\respaldo.ps1`. Necesita `pg_dump` de una versión igual o mayor a la de la base y `SUPABASE_DB_URL` en `.env.local`. Conserva los 8 más recientes.

## 9. Supuestos no verificados

| Supuesto | Cómo verificarlo |
|---|---|
| Caudal de las bombas: **no medido** (`CAUDAL_ML_POR_S = 0`, control de agua desactivado) | Medir los ml llenados en 10 s con una bomba |
| El módulo de relé se apaga con `INPUT` | Probarlo; si se enciende, `APAGAR_RELE_CON_INPUT = false` |
| AOUT del MQ-7 por debajo de 3.3 V | Medirlo con un multímetro en presencia de gas; si lo supera, usar un divisor |
| `fecha_bolivia` como columna generada | Si la migración muestra el aviso "No se pudo crear", no existe |
| La key `sb_publishable` funciona también en `Authorization: Bearer` | Funciona en la práctica (la v2 llegó hasta RLS) |
| Compilación del firmware | No compilado en este equipo (no hay arduino-cli): compilar en el Arduino IDE |
| SQL de v3 | No ejecutado todavía contra la base real |

## 10. Historial

- **V1** (commit `6cbd540`): ESP32 → Firebase (PUT de `temp`, `ratio`, `gas`, `calor`); la web leía Firebase y guardaba en Supabase.
- **V2:** el ESP32 escribía directo en `registros` con el rol `anon`; trigger de alerta por cada lectura.
- **V3** (actual): RPC con token, eventos, Telegram, agua limitada, comandos remotos, retención, proxy en Vercel y plan de contingencias.
