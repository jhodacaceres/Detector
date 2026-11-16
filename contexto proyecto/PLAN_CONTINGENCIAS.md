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
| **Falsa alarma por ruido eléctrico del LM35** (observado: la lectura salta entre 24 y 35 °C de un segundo a otro, con picos de 49–56 °C que generaron alertas de calor) | 🟠 | Alertas de calor y Telegram "🔥" sin calor real; temperatura errática en el Monitor Serie | La histéresis (45/43 °C) **no alcanza** contra picos aislados. **Sin filtro en el software, por decisión del proyecto** | Revisar el cableado del LM35 | Cables cortos o trenzados, LM35 lejos de los relés, bombas y antena del ESP32; capacitor de 0.1 µF entre OUT y GND del LM35 |
| Falsa alarma (cautín, secador o sol directo cerca del sensor) | 🟢 | Alerta `calor` sin fuego visible | La histéresis evita la oscilación | Alejar la fuente de calor; la alerta se normaliza sola | Ubicar el LM35 lejos de fuentes de calor que no sean de riesgo |

## 2. Gas (CO)

| Escenario | Sev. | Detección | Respuesta automática | Procedimiento manual | Prevención |
|---|---|---|---|---|---|
| Fuga real de CO | 🔴 | MQ-7 > 1.5 V, buzzer continuo y Telegram "🚨" | Buzzer hasta bajar de 1.3 V | **Evacuar**, ventilar (abrir puertas y ventanas), **no** accionar interruptores ni llamas, cortar el gas desde afuera y llamar a emergencias | Revisar artefactos a gas; detector certificado como respaldo |
| Gas durante los 60 s de precalentamiento | 🟠 | La web muestra "Precalentando" | **No hay alarma de gas** durante ese tiempo | Tras un reinicio, vigilar en persona el primer minuto | Reiniciar solo cuando haga falta |
| Falsa alarma (alcohol, aerosoles, humedad, humo de cocina) | 🟢 | Alerta `gas` sin fuente de CO | Se normaliza sola al bajar de 1.3 V | Ventilar y confirmar el origen | No usar alcohol ni aerosoles cerca del sensor |
| MQ-7 degradado (lecturas en aire limpio que suben con el tiempo) | 🟡 | Historial en `registros_resumen` (`gas_min` creciente) | — | Revisar el umbral o cambiar el sensor | Revisión mensual de `gas_min` |
| MQ-7 desconectado | 🟠 | `falla` (gas < 0.01 V), 2 pitidos por segundo y Telegram | — | Revisar el cable de AOUT y GPIO35 | Conectores firmes |
| El MQ-7 no detecta (sensor dañado) | 🔴 | **Silenciosa**: no hay detección automática | — | Prueba periódica: acercar un **encendedor** al sensor y verificar que suba la lectura (es la prueba usada en el proyecto). El MQ-7 responde más al CO que al butano: si hace falta pasar 1.5, acercarlo más o concentrar humo de 2–3 fósforos apagados en un vaso boca abajo sobre el sensor | Prueba antes de cada demostración |
| Mal contacto del AOUT del MQ-7 (pasó el 2026-11-14) | 🟠 | **Silenciosa**: lectura fija (ej. 0.11) que no responde al humo; no se marca `falla` porque no baja de 0.01 | — | Sacar un momento el cable AOUT: si el valor no cambia, el cable no está en el D35 (vecino del D34 y del D32). Reasentarlo | Conectores firmes; revisar tras mover cables |
| AOUT supera 3.3 V y daña el GPIO35 | 🟠 | Lecturas fijas o erráticas | — | Cambiar el ESP32 | Divisor 10k/20k y `FACTOR_DIVISOR_MQ7 = 1.5` |

## 3. Agua

> Desde el 2026-11-14 **no hay un depósito fijo**: la web ya no muestra el agua y el control de agua del firmware está desactivado (`CAUDAL_ML_POR_S = 0`). Las filas sobre el contador y el bloqueo aplican solo si se vuelve a calibrar un depósito.

| Escenario | Sev. | Detección | Respuesta automática | Procedimiento manual | Prevención |
|---|---|---|---|---|---|
| **Depósito agotado** (requiere el caudal calibrado; ver la fila siguiente) | 🟠 | Contador de agua ≤ 50 ml, Telegram "🚱" y la web dice "SIN AGUA" | Bombas **bloqueadas** y pitido largo alterno | 1) Recargar el depósito. 2) Verificar el nivel **a la vista**. 3) Web → PIN → "Reiniciar" (o botón EN de la placa) | Depósito acorde a la autonomía: `capacidad = 2 bombas × caudal × segundos necesarios` |
| **Caudal sin calibrar** (estado actual: `CAUDAL_ML_POR_S = 0`) | 🟠 | El Monitor Serie avisa al arrancar (la web ya no muestra el agua) | **Ninguna**: no hay bloqueo por falta de agua; las bombas funcionan mientras haya calor | **Vigilar el depósito a la vista** mientras funcionen las bombas; si se vacía, cortar la energía de las bombas | Medir el caudal (ml llenados en 10 s ÷ 10), ponerlo en `CAUDAL_ML_POR_S` y volver a cargar el firmware |
| Caudal medido que cambia con el tiempo (bomba gastada, manguera tapada) | 🟡 | El agua se acaba antes o después de lo que indica la web | — | Volver a medir y actualizar `CAUDAL_ML_POR_S` | Medir al instalar y al cambiar de bomba |
| Se reinicia **sin** haber recargado | 🟠 | — (el sistema cree que está lleno) | — | La web pide confirmación antes de reiniciar. Verificar el agua siempre a la vista | Procedimiento: primero recargar, después reiniciar |
| Bomba trabada u obstruida (el relé hace clic pero no sale agua) | 🟠 | **Silenciosa**: el contador descuenta igual | — | Revisar la manguera y la bomba; probar con 3.3–5 V directo | Prueba de bombas antes de cada demostración |
| Fuga de agua o inundación cerca de la electrónica | 🔴 | A la vista | — | **Cortar la energía primero**, secar y revisar antes de volver a encender | Depósito y mangueras **debajo** y lejos del ESP32; bandeja antiderrame |
| Agua sobre el ESP32 | 🔴 | Reinicios o lecturas erráticas | El watchdog reinicia | Desconectar y secar 24 h antes de encender | Carcasa o separación física |

## 4. Energía

| Escenario | Sev. | Detección | Respuesta automática | Procedimiento manual | Prevención |
|---|---|---|---|---|---|
| Corte de luz | 🔴 | La web muestra "ESP32 sin enviar datos" | Al volver la luz: arranque seguro (bombas apagadas y buzzer apagado), 60 s de precalentamiento y depósito supuesto lleno | Verificar el nivel de agua; si se gastó, recargar | **UPS o power bank** con salida de 5 V y 2 A |
| Caída de tensión al arrancar las bombas (*brownout*) (ocurrió el 2026-11-14 alimentando todo desde el USB de la PC) | 🟠 | Monitor Serie: "Motivo del reinicio: CAÍDA DE TENSIÓN", o caracteres raros repetidos (mensaje de arranque a 74880 baudios). El relé se activa un instante y se suelta | El ESP32 se reinicia (las bombas se apagan) | 1) Probar cada bomba sola: si una sola ya falla, está trabada o dañada. 2) Reasentar las conexiones del riel de 5 V y GND. 3) Usar el cargador de pared, **no el USB de la PC** | Cargador de **2 A o más** y capacitores de **470 µF** (entrada de la fuente) y **100 µF** (relé), ya puestos. Sin diodos flyback por decisión del proyecto (riesgo aceptado) |
| Fuente quemada | 🟠 | La web muestra "sin datos" | — | Reemplazar la fuente | Fuente de calidad, sin cables adaptados flojos |

## 5. Red

| Escenario | Sev. | Detección | Respuesta automática | Procedimiento manual | Prevención |
|---|---|---|---|---|---|
| WiFi caído o router apagado | 🟡 | La web muestra "sin datos"; el Monitor Serie dice "WiFi=sin conexión" | **Control local intacto**; buffer de 50 eventos con su hora; reconexión cada 30 s | Revisar el router | Router con UPS |
| Internet caído (hay WiFi) | 🟡 | Igual que el anterior; el Monitor Serie dice "error de conexión" | Reintentos de 5 s a 60 s; eventos guardados | Esperar o usar un hotspot del celular (cambiar `secrets.h`) | — |
| **Tarea de red trabada** (hay WiFi pero no se guarda nada y no aparece ningún error; ocurrió el 2026-11-13 al encenderse las bombas) | 🟠 | La web muestra "ESP32 sin enviar datos"; el Monitor Serie deja de mostrar `[Red] OK` cada minuto | **Vigilante en el loop:** sin "señal de vida" de la red durante 60 s, fuerza una reconexión WiFi; a los 180 s, reinicia el ESP32. Si Supabase está caído **no** reinicia (la tarea sigue viva reintentando) | Si se repite seguido: revisar el ruido de las bombas y relés (diodos, capacitor, fuente) | Diodo flyback, capacitor y fuente de 2 A o más |
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
| **Canal en vivo caído** (Realtime sin conexión) | 🟢 | El pie de la web deja de decir "En vivo" y vuelve a "Última lectura guardada"; el Monitor Serie no muestra `[Vivo] Canal en vivo listo` | La web vuelve sola a consultar `/api/estado` cada 2 s (datos cada 5 s); el ESP32 y la web reintentan cada 5 s | Si no vuelve: revisar `SUPABASE_PUBLISHABLE_KEY` en Vercel y status.supabase.com | — |
| **Cuota Realtime agotada** (2 millones de mensajes al mes en el plan gratuito) | 🟡 | Supabase → Usage → Realtime; los valores en vivo dejan de llegar | La web sigue con lo guardado (cada 5 s) | Esperar al mes siguiente o subir `VIVO_MS` a 2000 en el firmware | Cerrar la web cuando no se use (con la pestaña oculta no se pide transmisión) |
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
| **Valores falsos en la pantalla en vivo** o avisos `mirando` falsos (canal Realtime público) | 🟡 | Valores en vivo que no coinciden con "Última lectura guardada" o con el Monitor Serie; uso de Realtime alto en Supabase → Usage | La base, el historial y las alertas **no** se ven afectados (los escribe solo la RPC con token) | Confiar en las alertas y en Telegram; si se abusa de la cuota, quitar `SUPABASE_PUBLISHABLE_KEY` de Vercel (la web vuelve a lo guardado) | Aceptado: un canal privado exigiría cambiar la base (congelada) |
| Consulta masiva de `/api/estado` | 🟢 | Logs de Vercel | Caché de 2 s en la CDN; solo expone el estado actual | — | — |

## 9. Hardware

| Escenario | Sev. | Detección | Respuesta automática | Procedimiento manual | Prevención |
|---|---|---|---|---|---|
| ESP32 colgado | 🟠 | Sin datos | **Watchdog de 10 s** → reinicio ("Motivo: WATCHDOG") | Si se repite, revisar la fuente y el código | — |
| Relé pegado (no se apaga) | 🔴 | Bombas encendidas sin calor; el agua se acaba | El contador bloquea por software, pero **el relé físico sigue cerrado** | **Desconectar la bomba o la fuente** a mano y cambiar el relé | Diodo flyback (protege los contactos) |
| El relé no se apaga con 3.3 V | 🟠 | Bombas siempre encendidas | — | `APAGAR_RELE_CON_INPUT = true` (por defecto) | Probar al instalar |
| Buzzer que suena siempre (con `gas=0` y `falla=0` en el Monitor Serie) | 🟠 | Pitido continuo sin alarma | — | Mover el cable del GPIO a otro pin con `ESP32/buscar_pin`: si deja de sonar, el pin está dañado (pasó con el GPIO27 el 2026-11-14; se movió al 32). Si sigue, revisar el transistor (patas en filas distintas, C y E sin corto) | Capacitores puestos. Sin diodos (riesgo aceptado): pin libre de reserva para el buzzer, el GPIO33 |
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
2. [ ] Cargador de pared de 2 A o más en el riel (no el USB de la PC); capacitores de 470 µF, 100 µF (×2) y 47 µF en su lugar.
3. [ ] Monitor Serie: "Motivo del reinicio" normal (no brownout ni watchdog).
4. [ ] WiFi conectado ("WiFi=ok") y la web muestra "Sistema normal".
5. [ ] Temperatura coherente con el ambiente (recordar que las fórmulas en uso miden alrededor de un 20 % de menos).
6. [ ] Gas: tras 2–3 min encendido, lectura estable en aire limpio (~0.11); encendedor cerca del sensor → la lectura sube y, al pasar 1.5, `gas=1` y buzzer continuo; al retirarlo se apaga por debajo de 1.3. Si no llega a 1.5: humo de 2–3 fósforos en un vaso sobre el sensor.
   Calor (punto 7): el encendedor también sirve, **sin que la llama toque el LM35 ni los cables**.
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
