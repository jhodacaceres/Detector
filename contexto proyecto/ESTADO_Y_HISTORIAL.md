# Detector de Gas y Temperatura: estado actual e historial de trabajo

> Documento de entrada para retomar el proyecto (personas o IA).
> Resume **qué es**, **cómo está hoy**, **qué se decidió y por qué**, **qué se hizo** y **qué falta**.
> Sin credenciales: los valores reales están solo en `ESP32/detector/secrets.h`, `.env.local` y Vercel, todos fuera de git.
> Última actualización: 2026-11-13.

**Documentos relacionados** (detalle técnico):

| Documento | Para qué |
|---|---|
| [`CONTEXTO_PROYECTO.md`](CONTEXTO_PROYECTO.md) | Referencia técnica completa: hardware, firmware, base de datos, API y web |
| [`PLAN_CONTINGENCIAS.md`](PLAN_CONTINGENCIAS.md) | Todo lo que puede fallar y cómo responder; checklist antes de cada demostración |
| [`GUIA_PUESTA_EN_MARCHA.md`](GUIA_PUESTA_EN_MARCHA.md) | Pasos de instalación en orden |

---

## 1. El proyecto en una página

Sistema IoT **demostrativo que se opera como si fuera real**: debe contemplar contingencias de todo tipo (base de datos, incendio, agua, red, energía, seguridad).

```
LM35 (temp) ─┐                         ┌─▶ Buzzer (gas / falla / sin agua)
MQ-7 (gas) ──┼─▶ ESP32 ─ control local ─┼─▶ 2 bombas por relé (calor), depósito limitado
             │      │                   └─ (funciona SIN WiFi)
             │      └─ WiFi ─▶ Supabase (RPC con token) ─▶ alertas ─▶ Telegram
             │                    ▲
Navegador ─▶ Vercel /api (secret key oculta) ─┘   · GitHub Actions keepalive cada 3 días
```

| Pieza | Tecnología | Dónde está |
|---|---|---|
| Firmware | Arduino (ESP32), FreeRTOS con 2 tareas | `ESP32/detector/detector.ino` |
| Base de datos | Supabase (Postgres) con RLS, RPC, triggers, `pg_cron`, `pg_net` y Vault | `supabase/*.sql` |
| Web | HTML + JS sin frameworks, funciones serverless de Node | `index.html`, `app.js`, `api/` |
| Hosting | Vercel con deploy automático desde GitHub (`jhodacaceres/Detector`, rama `main`) | `vercel.json` |
| Avisos | Bot de Telegram (vía `pg_net` desde la base) | Configuración en Vault |
| Mantenimiento | Keepalive (GitHub Actions) y respaldos (`pg_dump`) | `.github/workflows/`, `supabase/respaldo.ps1` |

---

## 2. Decisiones del proyecto (no cambiar sin acordarlo)

| Tema | Decisión | Motivo |
|---|---|---|
| **Fórmulas de los sensores** | Se mantienen **exactas**: `((analogReadMilliVolts(pin) * 3.3) / 4095.0)`, `× 100` para la temperatura | Decisión del proyecto. Se sabe que miden alrededor de un 20 % de menos (la conversión se aplica dos veces); los umbrales están en esa misma escala |
| **Gas** | En **voltios**, alarma > 1.5 V (se apaga < 1.3 V) | Igual que el código original; no se usa Rs/R0 |
| **Calor** | Bombas > 45 °C (se apagan < 43 °C) | Histéresis para que el relé no oscile |
| **Agua** | **Sin depósito fijo** (desde el 2026-11-14): la web ya no muestra el agua, solo el estado de las bombas. El firmware conserva el control de agua, **desactivado** con `CAUDAL_ML_POR_S = 0`; solo bloquearía las bombas si se vuelve a calibrar. La base no cambia (`agua_ml` queda vacío) | Ya no hay un depósito de capacidad conocida |
| **Caudal** | **No se asume**: `CAUDAL_ML_POR_S = 0` (sin calibrar) hasta medirlo. Mientras tanto, bombas sin límite y vigilancia del depósito a la vista | No se pudo medir; un valor inventado daría un control falso |
| **Recarga** | Llenar el depósito y luego **reiniciar** el ESP32 con el botón de la web (con PIN) o el botón EN | Al arrancar se asume el depósito lleno |
| **Extras** | Se mantienen **todos**: token del ESP32, Telegram, botón de reinicio, retención, keepalive y respaldos | Se descartó simplificar quitando funciones |
| **Web** | Lee mediante Vercel; la **secret key** solo está en las variables de entorno. La key **publishable** (pública por diseño) llega al navegador por `/api/estado` para el canal en vivo | Un `.env` en una web estática no oculta nada (se ve con F12) |
| **Refresco** | **Valores en vivo cada 1 s** por Supabase Realtime Broadcast, **solo mientras alguien mira la web**. La base sigue guardando cada 5 s | Guardar 1 dato por segundo llenaría la base en ~1 mes (90 días de detalle, 500 MB, esquema congelado) y Realtime gratuito tiene 2 millones de mensajes al mes |
| **Seguridad** | `anon` (la key pública del ESP32) **solo** ejecuta 3 RPC; no accede a ninguna tabla | Antes cualquiera podía insertar datos falsos |
| **Retención** | 90 días de detalle → luego resumen por hora para siempre; alertas para siempre | Espacio limitado (500 MB en el plan gratuito) |
| **Base de datos** | Normalizada (3FN, v4) con **una** desnormalización intencional: la "foto" de valores en `alertas` | Conservar la alerta aunque se borre su registro |
| **Fecha** | `fecha` = instante real (UTC); `fecha_bolivia` = columna generada en hora de La Paz | Se ve la hora local sin perder exactitud |
| **Firebase** | Ya no se usa | Una sola fuente de datos (Supabase) |
| **Esquema de la base** | **CONGELADO desde la v4: prohibido modificarlo** (tablas, columnas, relaciones, funciones, triggers) | Se imprime un documento con las tablas y el diagrama entidad-relación. Todo ajuste se hace en el firmware, la API o la web |

---

## 3. Historial de lo que se hizo

### Punto de partida (V1, commit `6cbd540`)
- El ESP32 hacía PUT a **Firebase** (`temp`, `ratio`, `gas`, `calor`). El LM35 tenía una calibración empírica y el gas se medía como Rs/R0 (`R0 = 1655`).
- La web leía Firebase cada 1 s y desde el navegador guardaba en Supabase (`registros` y `alertas`).

### Versión en uso al comenzar esta etapa
- El ESP32 hacía **POST directo** a `registros` con la key publishable. Las fórmulas actuales ya estaban en uso y el gas se medía en voltios.
- **Error inicial:** `42501 new row violates row-level security policy` → faltaban políticas RLS.

### Etapa 1: permisos y v2
- Se explicó RLS y se crearon políticas para `anon`.
- Se creó `migracion_v2.sql` (**aplicada**): columnas `calor` y `gas`, default de `fecha` en `now()` (el anterior desfasaba 4 h), trigger de alerta e índice.
- La web pasó a leer de Supabase y se creó el primer `CONTEXTO_PROYECTO.md`.

### Etapa 2: auditoría (errores propios detectados y corregidos)

| Error o supuesto | Corrección |
|---|---|
| Se cambiaron las fórmulas sin revisar el historial de git (se ignoró la calibración de V1) | Las fórmulas en uso se restauraron **sin cambios** |
| Se dijo que el ESP32 "solo inserta" y la web "solo lee", pero ambos usaban `anon` | RPC con token por dispositivo; `anon` sin acceso a las tablas |
| Se presentaron cifras del ADC inventadas como si fueran datos | Se retiraron; ahora se documentan como "supuestos no verificados" |
| Se afirmó que los valores salían "1000 veces menores" | Era alrededor de un 20 %; se corrigió |
| `setup()` se bloqueaba sin WiFi → sin alarma ni bombas | Control local independiente de la red |
| Una alerta por cada lectura | Alertas solo al **cambiar** de estado |
| Se asumió agua ilimitada | Control de agua con bloqueo |
| Se cambió la fecha sin preguntar | `fecha_bolivia` generada |

### Etapa 3: v3 completa (implementada)
- **Firmware v3**:
  - El núcleo 1 se encarga de las alarmas y el núcleo 0 de la red.
  - Histéresis, detección de sensor desconectado y watchdog de 10 s.
  - Relés que se apagan con `INPUT` (módulo de 5 V controlado con 3.3 V).
  - Control de agua, precalentamiento de 60 s, buffer de 50 eventos sin red, NTP y comandos remotos.
  - `secrets.h` fuera de git.
- **`migracion_v3.sql`**:
  - Tablas `dispositivos` y `comandos`.
  - RPC `registrar_lectura`, `obtener_comando` y `confirmar_comando`.
  - Triggers de alerta por evento y de Telegram.
  - Retención con `pg_cron` y monitoreo de espacio (aviso al 80 %).
  - Permisos cerrados.
- **Web**: proxy `api/estado.js` y `api/comando.js` (PIN, anti-abuso), tarjetas de agua y bombas, franja de estado, alertas, botón de reinicio y `vercel.json` con CSP. Se eliminó `config.js`.
- **Operación**: `keepalive.yml`, `respaldo.ps1`, `.env.example`, `.gitignore` reforzado.
- **Documentación**: `CONTEXTO_PROYECTO.md` (reescrito), `PLAN_CONTINGENCIAS.md` (unos 50 escenarios, procedimientos A–D, checklist, roles) y `GUIA_PUESTA_EN_MARCHA.md`.
- Se eliminaron `ESP32/CODIGO_ESP32.txt` (reemplazado por el sketch) y `config.js`.

### Etapa 4: normalización (v4, preparada)
- **`migracion_v4.sql`**:
  - Elimina `registros_archivo` (era la misma entidad partida en dos y rompía la relación alertas → registros) y devuelve sus filas a `registros` sin disparar alertas.
  - Mueve la configuración del depósito a `dispositivos` y quita `autonomia_s` (dato derivado, ahora lo calcula la API).
  - `registros_resumen` gana clave propia y FK a `dispositivos`.
- El firmware envía la configuración del depósito (`p_caudal_ml_por_s`, `p_reserva_ml`, `p_num_bombas`) y `/api/estado` calcula la autonomía.

### Etapa 5: diagnóstico de hardware (2026-11-14)
| Problema | Causa encontrada | Solución |
|---|---|---|
| El relé "tenía menos energía": se activaba un instante y se soltaba; el Monitor Serie mostraba caracteres raros repetidos | El ESP32 se reiniciaba al arrancar las bombas (los caracteres son su mensaje de arranque a 74880 baudios). Todo se alimentaba desde el USB de la PC, que no alcanza para las bombas | Cargador de pared de 5 V para el riel; capacitores de 470 µF (entrada de la fuente) y 100 µF (relé). Una bomba funcionaba y dos no hasta reasentar las conexiones |
| El buzzer sonaba siempre, con `gas=0` y `falla=0` | **GPIO27 dañado**: no baja a 0 V. Se descubrió con `ESP32/buscar_pin` (con el cable en otro pin se callaba) | Buzzer movido al **GPIO32** (`PIN_BUZZER = 32`) |
| Caracteres raros en el Monitor Serie al sonar el buzzer | Ruido eléctrico en la alimentación | Capacitores de 100 µF (buzzer) y 47 µF (LM35) |
| El MQ-7 parecía no responder (lectura fija en 0.11) | Mal contacto del cable | Reasentado: vuelve a responder. Llegó a ~1.12 en la prueba; para pasar 1.5 se acerca más el encendedor o se concentra humo de fósforos en un vaso |
| Un sketch de prueba pegado dentro de `detector.ino` borró el firmware | Copiar código desde el chat cortó líneas y se pegó en el archivo equivocado | Firmware restaurado. **Toda prueba va en `ESP32/buscar_pin/buscar_pin.ino`** |
| El ESP32 no se conectaba al WiFi de la casa ("MESH HOME") | Prueba `w` de `buscar_pin`: la red se veía (WPA2, -51 dBm) pero el router respondía **motivo 15: contraseña incorrecta**. La de `secrets.h` no coincidía con la guardada en Windows | Contraseña corregida en `secrets.h` (copiada del perfil WiFi de la PC). Conecta y envía a la web |

### Etapa 6: valores en vivo y web sin depósito (2026-11-14)
- **Firmware:** tarea `tareaVivo` con WebSocket a Supabase Realtime; transmite cada 1 s solo mientras la web avisa `mirando`. Requiere la librería **WebSockets 2.7.2** (instalada). Compilado sin errores (87 % de la memoria de programa).
- **Web:** `app.js` se une al canal, avisa `mirando` cada 10 s (solo con la pestaña visible), muestra los valores en vivo y espacia las consultas a `/api/estado` a 5 s mientras el canal funciona. Se quitó la tarjeta "Agua del depósito" (queda la tarjeta de bombas) y los textos del depósito en el botón Reiniciar.
- **API:** `/api/estado` entrega `vivo: { url, key publishable }` si existe la variable `SUPABASE_PUBLISHABLE_KEY`.
- **`vercel.json`:** CSP con `connect-src wss://*.supabase.co`.
- **Verificado:** prueba de punta a punta contra el proyecto real (un cliente con el formato de la web y otro con el del firmware): unión al canal, `mirando` → `lectura` recibida.
- `buscar_pin.ino` ahora es un menú: `w` = prueba de WiFi (lee `secrets.h` sin copiarlo), `0` = pines en LOW, número = probar ese pin.

---

## 4. Estado de la instalación

| # | Paso | Estado |
|---|---|---|
| 1 | Respaldo de la base (`respaldo.ps1`) | ✅ Hecho |
| 2 | `migracion_v3.sql` | ✅ Aplicada (resultado: `schedule: 2`) |
| 3 | Token del ESP32 en `secrets.h` | ✅ Hecho |
| 4 | Firmware v3 subido | ✅ Compila y guarda datos |
| 4b | `migracion_v4.sql` y volver a subir el firmware (con el caudal sin calibrar) | ✅ v4 aplicada · ⏳ confirmar que se subió el firmware |
| 5 | Bot de Telegram y secretos en Vault | ✅ Hecho (llegó el mensaje de prueba) |
| 6 | Variables en Vercel (`SUPABASE_URL`, `SUPABASE_SECRET_KEY`, `ADMIN_PIN`, **`SUPABASE_PUBLISHABLE_KEY`**) y en `.env.local` | ⏳ **Siguiente paso** · `SUPABASE_PUBLISHABLE_KEY` ya está en `.env.local`; falta en Vercel |
| 7 | `git commit` + `push` (Vercel publica solo) | ⏳ Pendiente: nada se ha subido todavía |
| 8 | Variable `URL_APP` en GitHub y ejecutar el keepalive | ⏳ Pendiente |
| 9 | Medir el caudal real de las bombas y ajustar `CAUDAL_ML_POR_S` y `CAPACIDAD_ML` | ⏳ Pendiente |
| 10 | Prueba completa (checklist de `PLAN_CONTINGENCIAS.md`) | ⏳ Pendiente |

> ⚠️ Hasta completar los pasos 6 y 7, **la web publicada en Vercel sigue siendo la versión antigua**.
> ⚠️ Tras aplicar la v4, el firmware actual recibirá errores hasta que se vuelva a subir.

---

## 5. Archivos del proyecto

```
Detector/
├── index.html · app.js · vercel.json        Web
├── api/ _supabase.js · estado.js · comando.js   Funciones de Vercel
├── .env.example (versionado) · .env.local (ignorado)
├── .gitignore                               .env, .env*.local, secrets.h, respaldos/, .vercel
├── .github/workflows/keepalive.yml
├── ESP32/
│   ├── detector/ detector.ino · secrets.example.h · secrets.h (ignorado)
│   ├── buscar_pin/ buscar_pin.ino           Sketch para todas las pruebas de hardware
│   └── conexiones_esp32_gas.xlsx            Tabla de 33 conexiones
├── supabase/
│   ├── migracion_v2.sql   ✅ aplicada
│   ├── migracion_v3.sql   ✅ aplicada
│   ├── migracion_v4.sql   ⏳ pendiente
│   ├── configuracion_manual.sql   Token, Telegram, pruebas, revocación
│   └── respaldo.ps1
├── respaldos/ (ignorado)
└── contexto proyecto/
    ├── ESTADO_Y_HISTORIAL.md   ← este archivo
    ├── CONTEXTO_PROYECTO.md
    ├── PLAN_CONTINGENCIAS.md
    └── GUIA_PUESTA_EN_MARCHA.md
```

---

## 6. Riesgos abiertos y supuestos sin verificar

| Tema | Situación | Acción |
|---|---|---|
| Caudal de las bombas **no medido** | `CAUDAL_ML_POR_S = 0`: control de agua desactivado y bombas sin límite. **Riesgo activo de que trabajen en seco** | Vigilar el depósito a la vista; medirlo (paso 9) |
| AOUT del MQ-7 hasta 5 V en el GPIO35 (que admite 3.3 V) | Riesgo de dañar el pin | Medir con multímetro; divisor 10k/20k y `FACTOR_DIVISOR_MQ7 = 1.5` |
| **Ruido del LM35** (la lectura salta entre 24 y 35 °C; picos de 49–56 °C generaron alertas de calor falsas el 2026-11-13) | Activa bombas y alertas sin calor real. Se decidió **no** filtrar por software por ahora | Puesto el 47 µF en la alimentación del LM35 (2026-11-14). Falta: cerámico de 100 nF (104) entre OUT y GND; alejarlo de los relés y las bombas |
| Tarea de red trabada en silencio (2026-11-13, 20 min sin guardar datos; se repitió a las 16:20) | Causa probable: reutilización de la conexión TLS. Corregido: conexión nueva en cada envío, más el vigilante de red (reconexión a los 60 s, reinicio a los 180 s) | Confirmar que `[Red] OK · hace 1–6 s` se mantiene durante 30 min o más |
| Reloj del ESP32 unos 54 s atrasado | Las lecturas recientes ahora usan la hora de Supabase | — |
| **GPIO27 dañado** (2026-11-14: no baja a 0 V y el buzzer sonaba siempre). El buzzer se movió al **GPIO32** | Otro pin podría dañarse igual por los picos de las bombas | No usar el GPIO27; diodos y capacitor en las bombas |
| Bombas sin diodo flyback: **riesgo aceptado** (2026-11-14, no se dispone de diodos). Los capacitores ya están puestos | Los picos al apagarlas pueden dañar otros pines (probable causa del GPIO27) y los contactos del relé | Si el buzzer o un relé se comportan raro, diagnosticar el pin con `ESP32/buscar_pin` y moverlo a uno libre (33). Poner diodos si se consiguen |
| Canal en vivo público (Realtime) | Con la key publishable se pueden mostrar valores falsos en la pantalla en vivo o gastar la cuota con `mirando` falsos. La base y las alertas no se ven afectadas | Aceptado (los canales privados requieren cambiar la base). Revisar el uso de Realtime en Supabase → Usage |
| Cuota Realtime del plan gratuito (2 millones de mensajes al mes) | ≈ 2 mensajes por segundo con la web abierta: alcanza para ≈ 270 h de pantalla abierta al mes | Cerrar la web cuando no se use; si hace falta, `VIVO_MS = 2000` en el firmware |
| Relé que se apaga con `INPUT` | Sin probar en todos los módulos | Si se enciende, `APAGAR_RELE_CON_INPUT = false` |
| `fecha_bolivia` | Depende de que Postgres aceptara la columna generada | Revisar que exista en Table Editor |
| `migracion_v4.sql` y firmware v4 | No se han ejecutado ni compilado | Paso 4b |
| `setInsecure()` (TLS sin validar) | Limitación del prototipo | Aceptado y documentado |
| MQ-7 sin ciclo real de calefacción ni *burn-in* | Lecturas de CO aproximadas | No reemplaza a una alarma certificada |
| Supabase gratuito: se pausa tras 7 días sin actividad | Mitigado con el keepalive | Paso 8 |

---

## 7. Cómo retomar

1. Leer este archivo y luego `CONTEXTO_PROYECTO.md`.
2. Continuar con el **primer paso ⏳** de la tabla de la sección 4, siguiendo `GUIA_PUESTA_EN_MARCHA.md`.
3. Avanzar **un paso a la vez** y comprobar el resultado de cada uno antes de seguir.
4. Antes de cualquier commit: `git status` y comprobar que `secrets.h` y `.env.local` **no** aparecen.
