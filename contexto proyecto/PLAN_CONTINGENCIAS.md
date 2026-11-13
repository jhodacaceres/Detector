# Plan de contingencias: Detector de Gas y Temperatura

> Qué puede salir mal, cómo nos enteramos, qué hace el sistema solo y qué debe hacer una persona.
> El prototipo es demostrativo, pero se opera **como si fuera un sistema real**.
> Contexto técnico: [`CONTEXTO_PROYECTO.md`](CONTEXTO_PROYECTO.md).

## Severidad

| Nivel | Significado | Tiempo de respuesta |
|---|---|---|
| 🔴 **Crítica** | Riesgo para personas o bienes | Inmediato |
| 🟠 **Alta** | El sistema deja de proteger o de avisar | Menos de 1 hora |
| 🟡 **Media** | Se pierde una función secundaria (datos, web) | Menos de 1 día |
| 🟢 **Baja** | Molestia, sin pérdida de protección | Planificado |

## Aviso importante

Un ESP32 con un MQ-7 **no es una alarma de CO certificada** (UL 2034 / EN 50291). En una instalación real debe **complementar**, nunca reemplazar, a un detector comercial y a un extintor.

---

## 1. Incendio y calor

| Escenario | Sev. | Detección | Respuesta automática | Procedimiento manual | Prevención |
|---|---|---|---|---|---|
| Temperatura sobre 45 °C | 🔴 | LM35, alerta `calor` y Telegram "🔥" | Bombas encendidas hasta bajar de 43 °C o hasta que se acabe el agua | Verificar el origen del calor. Si hay fuego: extintor, cortar la energía, evacuar y llamar a bomberos (**119** en Bolivia) | Mantener el depósito lleno; probar las bombas antes de cada demostración |
| El LM35 se quema o se desconecta durante el incendio | 🔴 | `falla` (temperatura < 1 o > 125), Telegram "⚠️" y 2 pitidos por segundo | **Si las bombas estaban encendidas, siguen encendidas** (falla segura) | Asumir que el incendio continúa hasta comprobar lo contrario en persona | Cable del LM35 con protección térmica y alejado de la fuente de calor |
| El incendio dura más de lo que alcanza el agua | 🔴 | Alerta `sin_agua` y Telegram "🚱" | Bombas bloqueadas para que no trabajen en seco | Extintor y evacuación. **No** reiniciar sin haber recargado | Dimensionar el depósito según la autonomía necesaria (ver la sección Agua) |
| El fuego corta la luz o el WiFi | 🔴 | La web muestra "ESP32 sin enviar datos" | Sin red: el buzzer y las bombas siguen funcionando. Sin luz: **nada funciona** | Inspección en persona | UPS o power bank (sección Energía) |
| Falsa alarma (cautín, secador o sol directo cerca del sensor) | 🟢 | Alerta `calor` sin fuego visible | La histéresis evita la oscilación | Alejar la fuente de calor; la alerta se normaliza sola | Ubicar el LM35 lejos de fuentes de calor que no sean de riesgo |

## 2. Gas (CO)

| Escenario | Sev. | Detección | Respuesta automática | Procedimiento manual | Prevención |
|---|---|---|---|---|---|
| Fuga real de CO | 🔴 | MQ-7 > 1.5 V, buzzer continuo y Telegram "🚨" | Buzzer hasta bajar de 1.3 V | **Evacuar**, ventilar (abrir puertas y ventanas), **no** accionar interruptores ni llamas, cortar el gas desde afuera y llamar a emergencias | Revisar artefactos a gas; detector certificado como respaldo |
| Gas durante los 60 s de precalentamiento | 🟠 | La web muestra "Precalentando" | **No hay alarma de gas** durante ese tiempo | Tras un reinicio, vigilar en persona el primer minuto | Reiniciar solo cuando haga falta |
| Falsa alarma (alcohol, aerosoles, humedad, humo de cocina) | 🟢 | Alerta `gas` sin fuente de CO | Se normaliza sola al bajar de 1.3 V | Ventilar y confirmar el origen | No usar alcohol ni aerosoles cerca del sensor |
| MQ-7 degradado (lecturas en aire limpio que suben con el tiempo) | 🟡 | Historial en `registros_resumen` (`gas_min` creciente) | — | Revisar el umbral o cambiar el sensor | Revisión mensual de `gas_min` |
| MQ-7 desconectado | 🟠 | `falla` (gas < 0.01 V), 2 pitidos por segundo y Telegram | — | Revisar el cable de AOUT y GPIO35 | Conectores firmes |
| El MQ-7 no detecta (sensor dañado) | 🔴 | **Silenciosa**: no hay detección automática | — | Prueba periódica: acercar un encendedor **apagado** (butano) y verificar que suba la lectura | Prueba antes de cada demostración |
| AOUT supera 3.3 V y daña el GPIO35 | 🟠 | Lecturas fijas o erráticas | — | Cambiar el ESP32 | Divisor 10k/20k y `FACTOR_DIVISOR_MQ7 = 1.5` |

## 3. Agua

| Escenario | Sev. | Detección | Respuesta automática | Procedimiento manual | Prevención |
|---|---|---|---|---|---|
| **Depósito agotado** (requiere el caudal calibrado; ver la fila siguiente) | 🟠 | Contador de agua ≤ 50 ml, Telegram "🚱" y la web dice "SIN AGUA" | Bombas **bloqueadas** y pitido largo alterno | 1) Recargar el depósito. 2) Verificar el nivel **a la vista**. 3) Web → PIN → "Reiniciar" (o botón EN de la placa) | Depósito acorde a la autonomía: `capacidad = 2 bombas × caudal × segundos necesarios` |
| **Caudal sin calibrar** (estado actual: `CAUDAL_ML_POR_S = 0`) | 🟠 | La web dice "Caudal SIN CALIBRAR"; el Monitor Serie avisa al arrancar | **Ninguna**: no hay bloqueo por falta de agua; las bombas funcionan mientras haya calor | **Vigilar el depósito a la vista** mientras funcionen las bombas; si se vacía, cortar la energía de las bombas | Medir el caudal (ml llenados en 10 s ÷ 10), ponerlo en `CAUDAL_ML_POR_S` y volver a cargar el firmware |
| Caudal medido que cambia con el tiempo (bomba gastada, manguera tapada) | 🟡 | El agua se acaba antes o después de lo que indica la web | — | Volver a medir y actualizar `CAUDAL_ML_POR_S` | Medir al instalar y al cambiar de bomba |
| Se reinicia **sin** haber recargado | 🟠 | — (el sistema cree que está lleno) | — | La web pide confirmación ("¿El depósito ya fue recargado?"). Verificar siempre a la vista | Procedimiento: primero recargar, después reiniciar |
| Bomba trabada u obstruida (el relé hace clic pero no sale agua) | 🟠 | **Silenciosa**: el contador descuenta igual | — | Revisar la manguera y la bomba; probar con 3.3–5 V directo | Prueba de bombas antes de cada demostración |
| Fuga de agua o inundación cerca de la electrónica | 🔴 | A la vista | — | **Cortar la energía primero**, secar y revisar antes de volver a encender | Depósito y mangueras **debajo** y lejos del ESP32; bandeja antiderrame |
| Agua sobre el ESP32 | 🔴 | Reinicios o lecturas erráticas | El watchdog reinicia | Desconectar y secar 24 h antes de encender | Carcasa o separación física |

## 4. Energía

| Escenario | Sev. | Detección | Respuesta automática | Procedimiento manual | Prevención |
|---|---|---|---|---|---|
| Corte de luz | 🔴 | La web muestra "ESP32 sin enviar datos" | Al volver la luz: arranque seguro (bombas apagadas y buzzer apagado), 60 s de precalentamiento y depósito supuesto lleno | Verificar el nivel de agua; si se gastó, recargar | **UPS o power bank** con salida de 5 V y 2 A |
| Caída de tensión al arrancar las bombas (*brownout*) | 🟠 | Monitor Serie: "Motivo del reinicio: CAÍDA DE TENSIÓN" | El ESP32 se reinicia (las bombas se apagan) | Revisar la fuente y los cables | Fuente de **2 A o más**, diodo **1N4007** en paralelo con cada bomba y capacitor de **470–1000 µF** entre 5 V y GND |
| Fuente quemada | 🟠 | La web muestra "sin datos" | — | Reemplazar la fuente | Fuente de calidad, sin cables adaptados flojos |

## 5. Red

| Escenario | Sev. | Detección | Respuesta automática | Procedimiento manual | Prevención |
|---|---|---|---|---|---|
| WiFi caído o router apagado | 🟡 | La web muestra "sin datos"; el Monitor Serie dice "WiFi=sin conexión" | **Control local intacto**; buffer de 50 eventos con su hora; reconexión cada 30 s | Revisar el router | Router con UPS |
| Internet caído (hay WiFi) | 🟡 | Igual que el anterior; el Monitor Serie dice "error de conexión" | Reintentos de 5 s a 60 s; eventos guardados | Esperar o usar un hotspot del celular (cambiar `secrets.h`) | — |
| Cambio de red o de contraseña del WiFi | 🟡 | El ESP32 nunca conecta | Control local intacto | Editar `secrets.h` y volver a cargar el firmware | Documentar la red en la tabla de roles |
| Red de 5 GHz | 🟢 | No conecta | — | Usar una red de 2.4 GHz | El ESP32 solo admite 2.4 GHz |

## 6. Nube y servicios

| Escenario | Sev. | Detección | Respuesta automática | Procedimiento manual | Prevención |
|---|---|---|---|---|---|
| **Supabase pausado** (7 días sin actividad, plan gratuito) | 🟠 | Monitor Serie: errores de conexión; la web responde 503 | Control local intacto | Supabase → proyecto → **Restore**, y esperar unos minutos | **Keepalive** de GitHub Actions cada 3 días (verificar que esté activo) |
| Keepalive desactivado (GitHub lo apaga tras 60 días sin commits) | 🟡 | Pestaña Actions: "workflow disabled" | — | Actions → Keepalive → **Enable workflow** | Hacer un commit al menos cada 60 días o revisarlo una vez al mes |
| **Base de datos llena** (500 MB en el plan gratuito) | 🟠 | Telegram "💾 Base de datos al 80 %"; `select public.uso_bd();` | Retención diaria (90 días de detalle; después, resumen por hora) | Ver el **Procedimiento A** | Retención activa; revisar `cron.job_run_details` |
| El cron de retención falla | 🟡 | `select * from cron.job_run_details order by start_time desc;` muestra `failed` | — | Ejecutar `select public.mantenimiento_registros();` a mano y leer el error | Revisión mensual |
| Supabase caído (incidente del proveedor) | 🟡 | status.supabase.com | Control local intacto; eventos en buffer (máximo 50) | Esperar; anotar los eventos vistos en persona | — |
| Vercel caído o deploy roto | 🟡 | La web no carga | — | Ver los datos en Supabase → Table Editor (`registros`, `alertas`); revisar los logs de Vercel | Revisar el deploy después de cada push |
| Variables de entorno faltantes en Vercel | 🟡 | La web responde 503 "Servidor sin configurar" | — | Vercel → Settings → Environment Variables → volver a desplegar | Usar `.env.example` como lista de control |
| Telegram no llega | 🟠 | `alertas.notificada = false`; `select * from net._http_response order by created desc;` | La alerta se guarda igual | Verificar los secretos en Vault y que el bot no esté bloqueado; probar `select public.enviar_telegram('prueba');` | **Varios chats** separados por coma en `telegram_chat_id` |

## 7. Datos

| Escenario | Sev. | Detección | Respuesta automática | Procedimiento manual | Prevención |
|---|---|---|---|---|---|
| Pérdida o corrupción de la base | 🟠 | Tablas vacías o errores | — | **Procedimiento B** (restauración) | `respaldo.ps1` semanal (se conservan 8) |
| Migración fallida a mitad | 🟡 | Error en el SQL Editor | Todo va en una transacción: **no se aplica nada** | Leer el error, corregir y ejecutar de nuevo (es idempotente) | Respaldo **antes** de cada migración |
| Datos falsos inyectados | 🟠 | Lecturas absurdas | La RPC exige token, limita a 1 envío por segundo y valida rangos | Revocar el token (**Procedimiento C**) | Token secreto solo en `secrets.h` |
| Hora incorrecta en los registros | 🟢 | `fecha_bolivia` incoherente | NTP; la RPC ignora `p_fecha` si está fuera de las últimas 24 h | — | — |
| Buffer de eventos lleno (más de 50 sin red) | 🟢 | Monitor Serie: "Buffer lleno" | Se descarta el evento más antiguo | — | Restablecer la red pronto |

## 8. Seguridad

| Escenario | Sev. | Detección | Respuesta automática | Procedimiento manual | Prevención |
|---|---|---|---|---|---|
| Token del ESP32 robado (acceso físico al chip) | 🟠 | Registros desde lugares u horarios extraños | — | **Procedimiento C** | Dispositivo en un lugar con acceso restringido |
| Secret key de Supabase filtrada | 🔴 | Cambios inesperados en la base | — | Supabase → API Keys → **revocar y crear una nueva** → actualizar Vercel y `.env.local` → volver a desplegar | Solo en Vercel y `.env.local`; nunca en código |
| Contraseña del WiFi o token subidos a GitHub | 🟠 | `git log -p` o una alerta de GitHub | — | Cambiar la contraseña del WiFi y revocar el token. **Borrar el archivo no basta**: queda en el historial | `secrets.h` y `.env*.local` en `.gitignore`; `git status` antes de cada commit |
| PIN de la web adivinado | 🟡 | Reinicios no solicitados (Monitor Serie: "comando remoto") | 1 s de espera por intento fallido; 1 comando cada 30 s como máximo | Cambiar `ADMIN_PIN` en Vercel y volver a desplegar | PIN de **8 caracteres o más** (mejor una frase) |
| Consulta masiva de `/api/estado` | 🟢 | Logs de Vercel | Caché de 2 s en la CDN; solo expone el estado actual | — | — |

## 9. Hardware

| Escenario | Sev. | Detección | Respuesta automática | Procedimiento manual | Prevención |
|---|---|---|---|---|---|
| ESP32 colgado | 🟠 | Sin datos | **Watchdog de 10 s** → reinicio ("Motivo: WATCHDOG") | Si se repite, revisar la fuente y el código | — |
| Relé pegado (no se apaga) | 🔴 | Bombas encendidas sin calor; el agua se acaba | El contador bloquea por software, pero **el relé físico sigue cerrado** | **Desconectar la bomba o la fuente** a mano y cambiar el relé | Diodo flyback (protege los contactos) |
| El relé no se apaga con 3.3 V | 🟠 | Bombas siempre encendidas | — | `APAGAR_RELE_CON_INPUT = true` (por defecto) | Probar al instalar |
| Buzzer dañado | 🟠 | **Silenciosa** | — | Telegram es el respaldo; cambiar el buzzer | Prueba antes de cada demostración |
| Cable suelto en un sensor | 🟠 | `falla`, pitidos y Telegram | — | Revisar las conexiones contra `conexiones_esp32_gas.xlsx` | Soldar o usar conectores firmes |

## 10. Factor humano

| Escenario | Sev. | Detección | Respuesta automática | Procedimiento manual | Prevención |
|---|---|---|---|---|---|
| Nadie atiende la alarma | 🔴 | — | Buzzer local y Telegram | — | Varios destinatarios en Telegram; roles definidos (tabla de abajo) |
| Desconexión accidental | 🟡 | "Sin datos" en la web | — | Volver a conectar | Cables rotulados |
| Código modificado sin probar | 🟠 | Comportamiento inesperado | — | Volver a la última versión en git | **Checklist** antes de cada demostración; commits pequeños |

---

## Procedimientos

### A. Base de datos llena

1. Ver el uso: `select public.uso_bd();` (incluye el tamaño por tabla).
2. **Respaldo** con `respaldo.ps1`.
3. Retención más agresiva: `select public.mantenimiento_registros(30);` (deja 30 días de detalle; lo anterior queda resumido por hora).
4. Si sigue llena: `select public.mantenimiento_registros(7);`. Las alertas y el resumen por hora se conservan.
5. Si aún no alcanza: reducir la frecuencia de envío (`ENVIO_MS` en el firmware) o cambiar a un plan de pago.

### B. Restaurar un respaldo

1. Crear un proyecto nuevo en Supabase o vaciar el esquema `public` del actual.
2. `psql "<SUPABASE_DB_URL>" -f respaldos\AAAA-MM-DD_HHmm.sql`
3. Volver a ejecutar `migracion_v3.sql` (vuelve a crear permisos, triggers y cron).
4. Volver a cargar los secretos de Telegram (Vault no se respalda) y, si el proyecto es nuevo, actualizar las URL y keys en `secrets.h`, Vercel y `.env.local`.

### C. Revocar el token del ESP32

1. `update public.dispositivos set activo = false where id = <ID>;`
2. `configuracion_manual.sql`, paso 1, para generar un token nuevo.
3. Copiarlo a `secrets.h` y volver a cargar el firmware.

### D. Recarga del depósito

1. Comprobar que las bombas están **apagadas**.
2. Llenar el depósito hasta su capacidad (`CAPACIDAD_ML`).
3. Verificar a la vista que no haya fugas.
4. Web → PIN → **Reiniciar** (o botón **EN** de la placa).
5. Esperar unos 10 s: la web debe mostrar el agua al 100 % y "Precalentando".
6. Durante 60 s **no hay alarma de gas**: vigilar en persona.

---

## Checklist antes de cada demostración

1. [ ] Depósito lleno y sin fugas; mangueras lejos de la electrónica.
2. [ ] Fuente de 2 A o más conectada; diodos y capacitor en su lugar.
3. [ ] Monitor Serie: "Motivo del reinicio" normal (no brownout ni watchdog).
4. [ ] WiFi conectado ("WiFi=ok") y la web muestra "Sistema normal".
5. [ ] Temperatura coherente con el ambiente (recordar que las fórmulas en uso miden alrededor de un 20 % de menos).
6. [ ] Gas: después de 60 s, lectura estable en aire limpio; prueba con butano → buzzer.
7. [ ] Calor: acercar una fuente de calor → bombas encendidas y Telegram "🔥". Al retirarla se apagan por debajo de 43 °C.
8. [ ] Telegram: `select public.enviar_telegram('prueba');` llega a todos los chats.
9. [ ] `select public.uso_bd();` por debajo del 80 % y `cron.job_run_details` sin fallos.
10. [ ] `git status`: ni `secrets.h` ni `.env.local` aparecen como archivos a subir.

## Roles y contactos

| Rol | Responsable | Contacto |
|---|---|---|
| Responsable del sistema | `<nombre>` | `<teléfono>` |
| Respuesta en el lugar (alarma, recarga de agua) | `<nombre>` | `<teléfono>` |
| Administración de Supabase / Vercel | `<nombre>` | `<correo>` |
| Emergencias | Bomberos **119** · Policía **110** · Ambulancia **118** | — |

Red WiFi del dispositivo: `<SSID>`. La contraseña **no** se escribe aquí.
