# Por hacer: Detector de Gas y Temperatura

> Revisión del 2026-11-13, actualizada el 2026-11-14.
> Contrasta la documentación de `contexto proyecto/` con el código real.
> Primero van los supuestos y errores del asistente, y después los puntos críticos pendientes.

---

## A. Supuestos y errores del asistente

### Errores ya corregidos (registrados en `ESTADO_Y_HISTORIAL.md`)

1. Cambió las fórmulas sin revisar el historial de git.
2. Dijo que el ESP32 "solo inserta" y la web "solo lee", cuando ambos usaban el rol `anon` y cualquiera podía escribir.
3. Presentó como datos unas cifras del ADC que había inventado.
4. Dijo que los valores salían "1000 veces menores". En realidad la diferencia es de un ~20 %.
5. Escribió un `setup()` que se bloqueaba sin WiFi, y sin WiFi no había alarma ni bombas.
6. Hizo que se creara una alerta por cada lectura, en vez de solo al cambiar el estado.
7. Asumió que el agua era ilimitada.
8. Cambió la fecha sin preguntar.
9. Estuvo a punto de asumir un caudal para las bombas. Quedó en 0 = sin calibrar.

### Supuestos de la revisión

10. Presentó su memoria como verdadera sin contrastarla con el código. La revisión lo corrigió y encontró discrepancias (sección B).
11. Interpretó "abrir el archivo" como abrirlo con el programa predeterminado.
12. Su memoria resume decisiones, no razonamientos. Puede faltar contexto.

---

## B. Puntos críticos

### 🔴 Seguridad física

- [ ] **1. Precalentamiento del MQ-7.** El 2026-11-13 estaba en `PRECALENTAMIENTO_MS = 0` (en un cambio sin commit), aunque la documentación y la web dicen 60 s. Con 0, el gas se evalúa con el sensor frío y pueden saltar falsas alarmas o una falla de sensor al arrancar.
  - **Revisión del 2026-11-14:** vuelve a estar en `60000`. Confirmar que se queda así en el commit.
- [ ] **2. Las bombas pueden trabajar en seco.** Con `CAUDAL_ML_POR_S = 0` no hay ningún bloqueo por falta de agua. Por ahora la única protección es vigilar el depósito a la vista.
- [ ] **3. Un reinicio hace que el sistema crea que el depósito está lleno.** Cualquier reinicio en medio de un incendio deja el agua en 100 % y las bombas apagadas hasta la siguiente lectura. Puede venir del watchdog, de una caída de tensión, del vigilante de red (a los 180 s) o del botón de la web. Cuando se calibre el caudal, esto se vuelve un riesgo real.
- [ ] **4. El ruido del LM35 genera alarmas falsas.** Hubo picos de 49–56 °C que encendieron las bombas sin calor real. Se decidió no filtrarlo por software. Acciones:
  - Cables cortos o trenzados.
  - Un capacitor de 0.1 µF entre OUT y GND.
  - El sensor lejos de los relés y las bombas.
- [ ] **5. Un relé pegado deja las bombas encendidas.** El software no puede apagarlo.
- [ ] **6. Fallas que nadie detecta:** si el MQ-7 deja de detectar, el buzzer se daña o una bomba se tapa, el sistema no avisa. Solo se descubren con las pruebas manuales del checklist.
- [ ] **7. El MQ-7 no es una alarma de CO certificada.** No tiene un ciclo real de calefacción.

### 🟠 Hardware sin verificar

- [ ] **8. La salida del MQ-7 puede llegar a 5 V** y entra en el GPIO35, que soporta 3.3 V. Puede dañar el pin. Medirla con el multímetro; si pasa de 3.3 V, poner un divisor 10k/20k y `FACTOR_DIVISOR_MQ7 = 1.5`.
- [ ] **9. Faltan protecciones en las bombas:** no tienen diodo flyback ni capacitor. Eso puede causar caídas de tensión (brownout) y es la causa probable de que la red se trabe. Poner un diodo 1N4007 por bomba y un capacitor de 470–1000 µF.
- [ ] **10. El apagado del relé con `INPUT` no está probado** en este módulo. Si el relé se enciende con `INPUT`, usar `APAGAR_RELE_CON_INPUT = false`.

### 🟠 Estado del despliegue

- [ ] **11. Hay cambios sin guardar en git:** firmware, `app.js`, `conexiones_esp32_gas.xlsx`, `ESP32/buscar_pin/` y la documentación. La web publicada en Vercel sigue siendo la versión antigua.
- [ ] **12. Faltan las variables de Vercel** (`SUPABASE_URL`, `SUPABASE_SECRET_KEY` y `ADMIN_PIN`) y su copia en `.env.local`. Sin ellas, la web responde 503.
- [ ] **13. Falta la variable `URL_APP` en GitHub.** Hay que definirla y ejecutar el keepalive; si no corre, Supabase se pausa a los 7 días sin actividad.
- [ ] **14. No está confirmado que el firmware v4 esté en el ESP32.** Si no está, la v4 de la base rechaza sus envíos.
- [ ] **15. El arreglo de la red trabada no está validado.** Confirmar que el Monitor Serie muestra `[Red] OK · hace 1–6 s` durante más de 30 minutos.

### 🟡 Documentación inconsistente

- [ ] **16. `ESTADO_Y_HISTORIAL.md` se contradice:** en un lugar dice que la v4 está aplicada y en otros dos (árbol de archivos y tabla de riesgos) que está pendiente.
- [ ] **17. `CONTEXTO_PROYECTO.md` está desactualizado:** su encabezado todavía dice "v3", y el árbol de carpetas no incluye `migracion_v4.sql`, `ESTADO_Y_HISTORIAL.md` ni `ESP32/buscar_pin/`.
- [ ] **18. El precalentamiento debe coincidir en el código, la web y la documentación** (60 s). Ver el punto 1.

### 🟡 Seguridad informática (limitaciones aceptadas)

- [ ] **19. HTTPS sin validar el certificado:** el ESP32 usa `setInsecure()`.
- [ ] **20. `/api/estado` es público:** cualquiera puede ver el estado actual, pero no el historial.
- [ ] **21. El PIN de reinicio tiene poca protección:** solo 1 s de espera por intento y 1 comando cada 30 s. Usar un PIN de 8 caracteres o más.

### Pendientes operativos

- [ ] Medir el caudal real de las bombas (ml llenados en 10 s ÷ 10) y ajustar `CAUDAL_ML_POR_S` y `CAPACIDAD_ML`.
- [ ] Prueba completa con el checklist de `PLAN_CONTINGENCIAS.md`.
- [ ] Antes de cada commit: `git status` y comprobar que `secrets.h` y `.env.local` no aparecen.

---

## C. Verificado como correcto

- `secrets.h` y `.env.local` están ignorados por git.
- El esquema de la base no se toca (congelado desde la v4).
