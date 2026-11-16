# Tareas: Detector de Gas y Temperatura

> Creado el 2026-11-15. Plan para eliminar los supuestos y cerrar los puntos críticos de `por_hacer.md`.
> **Regla:** una tarea solo se marca `[x]` cuando tiene su **prueba** (captura, medición anotada o salida del comando). Sin prueba, sigue abierta.

Estado verificado en el código antes de crear este archivo:
- El `setup()` **no se bloquea sin WiFi** (`ESP32/detector/detector.ino`, `WiFi.begin` sin espera). Falta probarlo con el equipo (tarea 24).
- El banner del Monitor Serie dice `=== Detector v3 ===` (se corrige en la tarea 19).
- El mensaje de "60 s" está escrito a mano y no se calcula con `PRECALENTAMIENTO_MS` (tarea 19).

---

## Fase 1: Averiguar la verdad (sin cambiar nada)

- [ ] **1. ¿Está aplicada la v4 de la base?** En el SQL Editor de Supabase, comprobar que no existe `registros_archivo` y que sí existen la función `registrar_lectura` (14 parámetros) y la configuración del depósito en `dispositivos`.
  - Quién: tú · Prueba: captura del resultado
- [ ] **2. Arranque del ESP32.** Abrir el Monitor Serie a 115200 baudios.
  - Quién: tú · Prueba: copia de las primeras 20 líneas
- [ ] **3. ¿El ESP32 guarda datos?** Revisar la tabla `registros`.
  - Quién: tú · Prueba: filas nuevas cada ~5 s y ningún error 4xx en el Serie
- [ ] **4. ¿Qué hay publicado en Vercel?** Ver el commit publicado y si existen `SUPABASE_URL`, `SUPABASE_SECRET_KEY` y `ADMIN_PIN`.
  - Quién: tú · Prueba: captura del panel
- [ ] **5. ¿Funciona el keepalive?** En GitHub, revisar si existe `URL_APP` y si el workflow se ha ejecutado alguna vez.
  - Quién: tú · Prueba: captura de Settings → Variables y de Actions
- [ ] **6. Voltaje del MQ-7.** Con el multímetro, medir AO respecto a GND con el sensor caliente y acercándole gas (encendedor sin llama).
  - Quién: tú · Prueba: valor máximo en V, anotado: `______ V`
- [ ] **7. Caudal de las bombas.** Llenar un vaso medidor 10 s con cada bomba y dividir los ml entre 10.
  - Quién: tú · Prueba: bomba 1 `____ ml/s` · bomba 2 `____ ml/s`
- [ ] **8. Capacidad del depósito.**
  - Quién: tú · Prueba: `______ ml`

## Fase 2: Hardware (según los resultados de la fase 1)

- [ ] **9. Divisor del MQ-7** (solo si la tarea 6 da más de 3.3 V): divisor 10k/20k y `FACTOR_DIVISOR_MQ7 = 1.5`.
  - Prueba: nueva medición en el pin ≤ 3.3 V
- [ ] **10. Protección de las bombas:** un diodo 1N4007 en paralelo a cada bomba y un capacitor de 470–1000 µF en la alimentación.
  - Prueba: foto del montaje
- [ ] **11. Ruido del LM35:** capacitor de 0.1 µF entre OUT y GND, cables cortos o trenzados y el sensor lejos de los relés.
  - Prueba: 10 min con las bombas encendidas sin picos de más de 45 °C
- [ ] **12. Apagado del relé con `INPUT`:** con `APAGAR_RELE_CON_INPUT = true`, la bomba debe quedar **apagada** en reposo.
  - Prueba: resultado anotado (sí/no)
- [ ] **13. Fuente de 5 V y 2 A o más.**
  - Prueba: 30 min con las bombas sin "brownout" en el Serie

## Fase 3: Decisiones (solo las tomas tú)

- [ ] **14.** Con el caudal medido, ¿se activa el control de agua o se queda desactivado? *(Hoy las bombas pueden trabajar en seco sin límite.)*
  - Decisión: `__________`
- [ ] **15.** Si el LM35 falla con las bombas encendidas, ¿siguen encendidas sin tiempo máximo o se les pone un límite?
  - Decisión: `__________`
- [ ] **16.** Tras un reinicio, ¿se asume el depósito lleno o se exige una confirmación? *(Solo importa si en la 14 se activa el control de agua.)*
  - Decisión: `__________`
- [ ] **17.** ¿Se quita de la web la lógica de "Sin agua" (`app.js`) o se deja por si se calibra?
  - Decisión: `__________`
- [ ] **18.** ¿Se cambia el include de `buscar_pin.ino` a una ruta relativa? *(Hoy publica la ruta de tu PC en GitHub.)*
  - Decisión: `__________`

## Fase 4: Cambios en el código (Claude, uno por uno y con tu OK)

- [ ] **19.** Banner `Detector v3` → `v4` y mensaje del precalentamiento calculado con `PRECALENTAMIENTO_MS`.
  - Prueba: diff aprobado
- [ ] **20.** Aplicar las decisiones de la fase 3.
  - Prueba: diff aprobado
- [ ] **21.** `git status`: comprobar que no aparecen `secrets.h` ni `.env.local`.
  - Prueba: salida del comando
- [ ] **22.** Commit y push.
  - Prueba: Vercel publica el commit nuevo y la web carga sin 503
- [ ] **23.** Subir el firmware al ESP32.
  - Prueba: el Serie muestra `=== Detector v4 ===`

## Fase 5: Pruebas reales

- [ ] **24. Sin WiFi** (router apagado): el buzzer y las bombas responden al gas y al calor.
- [ ] **25. Red estable:** `[Red] OK · hace 1–6 s` durante 30 min o más, con las bombas funcionando.
- [ ] **26. Gas** (después de los 60 s): suena el buzzer, aparece la alerta en la web y llega el mensaje de Telegram.
- [ ] **27. Calor:** por encima de 45 °C se encienden las bombas; por debajo de 43 °C se apagan.
- [ ] **28. Falla de sensor:** al desconectar el LM35, 2 pitidos por segundo y una alerta.
- [ ] **29. Corte de luz durante una alarma:** el sistema arranca en estado seguro (bombas y buzzer apagados).
- [ ] **30. Reinicio con PIN desde la web:** funciona con el PIN correcto y lo rechaza con uno incorrecto.
- [ ] **31. Checklist completo de `PLAN_CONTINGENCIAS.md`:** cada fila marcada con su fecha.
- [ ] **32. Keepalive:** después de 3 días aparece en verde en GitHub Actions.

## Fase 6: Documentación

- [ ] **33.** Corregir la documentación con los resultados **reales** de las fases 1 y 5:
  - La contradicción sobre la v4 en `ESTADO_Y_HISTORIAL.md` (líneas 145, 174 y 202).
  - El encabezado "(v3)" de `CONTEXTO_PROYECTO.md`.
  - El "depósito supuesto lleno" de `PLAN_CONTINGENCIAS.md:64`.
  - El árbol de archivos (`migracion_v4.sql`, `ESTADO_Y_HISTORIAL.md`, `ESP32/buscar_pin/`).
- [ ] **34.** Actualizar `por_hacer.md`: ningún punto ✅ sin su prueba.

---

## Limitaciones aceptadas (se conocen y no se corrigen)

- El ESP32 usa HTTPS sin validar el certificado (`setInsecure()`).
- `/api/estado` es público: se ve el estado actual, pero no el historial.
- El PIN de reinicio tiene poca protección: usar un PIN de 8 caracteres o más.
- El MQ-7 no es una alarma de CO certificada.
- Durante los 60 s de precalentamiento no hay alarma de gas; vigilar en persona el primer minuto tras cada reinicio.

## Reglas para el asistente (para no asumir nada)

1. No afirmar nada que no esté leído en el código o medido o confirmado por el usuario. Si no se sabe, decir "no verificado".
2. No inventar valores físicos: si falta un dato, va en 0 = "sin calibrar".
3. Preguntar antes de cada cambio y esperar el OK.
4. No modificar el esquema de la base de datos (congelado desde la v4).
5. Las pruebas van en `ESP32/buscar_pin/buscar_pin.ino`, nunca en `detector.ino`.

**Orden recomendado:** empezar por la tarea 1, porque de ella dependen las tareas 3, 22 y 23.
