// ===== Monitor de Gas y Temperatura (v3) =====
// La web NO habla con la base directamente: usa las funciones de Vercel
//   GET  /api/estado   -> última lectura guardada, últimas alertas y datos del canal en vivo
//   POST /api/comando  -> ordena reiniciar el ESP32 (con PIN)
// Valores EN VIVO (cada 1 s): canal Realtime de Supabase (WebSocket, solo lectura de
// mensajes "broadcast"). La web avisa "mirando" cada 10 s y el ESP32 transmite solo
// mientras alguien mira. Si el canal falla, se sigue mostrando lo guardado (cada 5 s).

const INTERVALO = 2000;          // ms entre consultas a /api/estado sin canal en vivo
const INTERVALO_CON_VIVO = 5000; // con el canal en vivo funcionando basta para las alertas
const VIVO_VIGENTE = 3000;       // ms: un valor en vivo más viejo que esto ya no se considera "en vivo"
const MIRANDO_MS = 10000;        // aviso "mirando" al ESP32
const LATIDO_MS = 25000;         // latido del canal (si no, el servidor lo cierra)
const MAX_ANTIGUEDAD = 30000;    // ms: si el último dato es más viejo, el ESP32 no está enviando
                                 // (envío cada 5 s + conexión TLS nueva por envío + caché de 2 s)
const ZONA = "America/La_Paz";
const CANAL = "realtime:detector";

const $ = (id) => document.getElementById(id);

const TEXTO_ALERTA = {
  gas: "🚨 Gas detectado",
  calor: "🔥 Temperatura alta",
  falla: "⚠️ Falla de sensor",
  sin_agua: "🚱 Sin agua"
};

let ultimoDato = null;   // se conserva si la consulta falla
let consultando = false;
let ultimoVivo = 0;      // Date.now() del último valor en vivo recibido


async function leerDatos() {
  if (consultando) return;
  consultando = true;
  try {
    const respuesta = await fetch("/api/estado", { cache: "no-store" });
    const datos = await respuesta.json().catch(() => ({}));
    if (!respuesta.ok) throw new Error(datos.error || "HTTP " + respuesta.status);

    if (datos.vivo) iniciarVivo(datos.vivo);

    if (!datos.ultimo) {
      conexion("Conectado", true);
      if (!hayVivo()) franja("Sin registros: el ESP32 aún no ha enviado datos", "aviso");
      return;
    }

    ultimoDato = datos.ultimo;
    mostrarAlertas(datos.alertas || []);
    // Con valores en vivo recientes no se pisa la pantalla con el dato guardado (más viejo)
    if (!hayVivo()) {
      mostrar(datos.ultimo);
      actualizarFranja(datos.ultimo, datos.servidor);
    }
    conexion(hayVivo() ? "Conectado · en vivo" : "Conectado", true);

  } catch (error) {
    console.error(error);
    conexion("Sin conexión con el servidor", false);
    if (hayVivo()) return;
    if (ultimoDato) {
      franja("Datos desactualizados: se muestra la última lectura conocida", "aviso");
    } else {
      franja("No se pudo obtener datos: " + error.message, "grave");
    }
  } finally {
    consultando = false;
  }
}

function hayVivo() {
  return Date.now() - ultimoVivo < VIVO_VIGENTE;
}


// ---------------- Canal en vivo (protocolo Phoenix de Supabase Realtime) ----------------
let vivo = null;   // { ws, ref, timers }

function iniciarVivo(cfg) {
  if (vivo || !cfg.url || !cfg.key || typeof WebSocket === "undefined") return;
  vivo = { ws: null, ref: 2, timers: [] };
  conectarVivo(cfg);
}

function conectarVivo(cfg) {
  const host = cfg.url.replace(/^https?:\/\//, "").replace(/\/+$/, "");
  const ws = new WebSocket("wss://" + host + "/realtime/v1/websocket?apikey=" +
                           encodeURIComponent(cfg.key) + "&vsn=1.0.0");
  vivo.ws = ws;

  const enviar = (topic, event, payload) => {
    if (ws.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify({ topic, event, payload, ref: String(vivo.ref++), join_ref: "1" }));
  };
  // Avisar al ESP32 que hay alguien mirando (solo con la pestaña visible: cuida la cuota)
  const mirando = () => {
    if (document.visibilityState === "visible") {
      enviar(CANAL, "broadcast", { type: "broadcast", event: "mirando", payload: {} });
    }
  };

  ws.onopen = () => {
    ws.send(JSON.stringify({
      topic: CANAL, event: "phx_join", ref: "1", join_ref: "1",
      payload: { config: { broadcast: { self: false, ack: false }, presence: { key: "" }, private: false } }
    }));
    vivo.timers.push(setInterval(() => enviar("phoenix", "heartbeat", {}), LATIDO_MS));
  };

  ws.onmessage = (m) => {
    let d;
    try { d = JSON.parse(m.data); } catch { return; }
    if (d.event === "phx_reply" && d.ref === "1") {
      if (d.payload && d.payload.status === "ok") {
        mirando();
        vivo.timers.push(setInterval(mirando, MIRANDO_MS));
      }
    } else if (d.event === "broadcast" && d.payload && d.payload.event === "lectura") {
      mostrarVivo(d.payload.payload || {});
    }
  };

  ws.onclose = () => {
    vivo.timers.forEach(clearInterval);
    vivo.timers = [];
    setTimeout(() => conectarVivo(cfg), 5000);   // reintento
  };
  ws.onerror = () => ws.close();
}

// Al volver a la pestaña se avisa enseguida (sin esperar 10 s)
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && vivo && vivo.ws && vivo.ws.readyState === WebSocket.OPEN) {
    vivo.ws.send(JSON.stringify({ topic: CANAL, event: "broadcast", ref: String(vivo.ref++), join_ref: "1",
      payload: { type: "broadcast", event: "mirando", payload: {} } }));
  }
});

function mostrarVivo(p) {
  // Mismo formato que un registro guardado; la hora es la de llegada (el dato tiene < 1 s)
  const d = {
    lectura_temperatura: p.t,
    lectura_gas: p.g,
    calor: !!p.calor,
    gas: !!p.gas,
    falla: !!p.falla,
    sin_agua: !!p.sin_agua,
    precalentando: !!p.precal,
    fecha: new Date().toISOString()
  };
  if (!Number.isFinite(Number(d.lectura_temperatura)) || !Number.isFinite(Number(d.lectura_gas))) return;
  ultimoVivo = Date.now();
  mostrar(d, true);
  actualizarFranja(d, d.fecha);
  conexion("Conectado · en vivo", true);
}


function mostrar(d, enVivo = false) {
  // --- Temperatura ---
  $("temp").textContent = Number(d.lectura_temperatura).toFixed(1);
  alarma($("tarjetaTemp"), d.calor);
  $("estadoTemp").textContent = d.calor ? "TEMPERATURA ALTA" : "Normal";

  // --- Gas ---
  $("gas").textContent = Number(d.lectura_gas).toFixed(2);
  alarma($("tarjetaGas"), d.gas);
  $("tarjetaGas").classList.toggle("aviso", !!d.precalentando);
  $("estadoGas").textContent = d.precalentando ? "Precalentando sensor"
                             : d.gas ? "GAS DETECTADO - ALARMA ACTIVA" : "Sin gas";

  // --- Bombas (se encienden con el calor) ---
  const activas = d.calor && !d.sin_agua;
  $("bombas").textContent = d.sin_agua ? "Bloqueadas" : activas ? "Activas" : "Apagadas";
  alarma($("tarjetaBombas"), d.calor || d.sin_agua);
  $("estadoBombas").textContent = d.sin_agua ? "SIN AGUA - BOMBAS BLOQUEADAS"
                                : activas ? "BOMBAS ACTIVAS" : "En espera (se activan sobre 45 °C)";

  // --- Hora de la lectura ---
  $("actualizado").textContent = (enVivo ? "En vivo · " : "Última lectura guardada: ") +
    new Date(d.fecha).toLocaleString("es-BO", { timeZone: ZONA });
}


function mostrarAlertas(alertas) {
  const lista = $("listaAlertas");
  lista.replaceChildren();
  if (alertas.length === 0) {
    const li = document.createElement("li");
    li.textContent = "Sin alertas registradas";
    lista.appendChild(li);
    return;
  }
  for (const a of alertas) {
    const li = document.createElement("li");
    const texto = document.createElement("span");
    texto.textContent = TEXTO_ALERTA[a.tipo] || "🔔 Alerta";
    const hora = document.createElement("span");
    hora.className = "hora";
    hora.textContent = new Date(a.fecha).toLocaleString("es-BO", { timeZone: ZONA });
    li.append(texto, hora);
    lista.appendChild(li);
  }
}


// Estado general del sistema (prioridad: lo más grave primero)
function actualizarFranja(d, horaServidor) {
  // Se compara con la hora del SERVIDOR (viene en la misma respuesta), no con el reloj
  // del navegador: si la PC está adelantada o atrasada, el aviso saldría por error.
  const referencia = horaServidor ? new Date(horaServidor).getTime() : Date.now();
  const antiguedad = referencia - new Date(d.fecha).getTime();
  if (antiguedad > MAX_ANTIGUEDAD) {
    franja("ESP32 sin enviar datos recientes (sin WiFi, sin energía o apagado). La alarma local sigue funcionando si tiene energía.", "grave");
  } else if (d.sin_agua) {
    franja("Bombas bloqueadas por falta de agua: revisar y pulsar «Reiniciar»", "grave");
  } else if (d.gas) {
    franja("GAS DETECTADO: ventilar y evacuar", "grave");
  } else if (d.falla) {
    franja("Falla de sensor: revisar conexiones del LM35 / MQ-7", "grave");
  } else if (d.calor) {
    franja("Temperatura alta: bombas activas", "grave");
  } else if (d.precalentando) {
    franja("Sensor de gas precalentando: la alarma de gas aún no está activa", "aviso");
  } else {
    franja("Sistema normal", "");
  }
}


async function reiniciar() {
  const pin = $("pin").value;
  const mensaje = $("mensajeComando");
  if (!pin) {
    mensaje.textContent = "Escribe el PIN";
    mensaje.className = "fail";
    return;
  }
  if (!confirm("¿Reiniciar el ESP32? Se reinicia en unos segundos.")) return;

  const boton = $("botonReiniciar");
  boton.disabled = true;
  mensaje.textContent = "Enviando...";
  mensaje.className = "";
  try {
    const respuesta = await fetch("/api/comando", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ pin })
    });
    const datos = await respuesta.json().catch(() => ({}));
    mensaje.textContent = datos.mensaje || ("Error HTTP " + respuesta.status);
    mensaje.className = datos.ok ? "ok" : "fail";
    if (datos.ok) $("pin").value = "";
  } catch (error) {
    mensaje.textContent = "No se pudo contactar al servidor";
    mensaje.className = "fail";
  } finally {
    boton.disabled = false;
  }
}


function alarma(elemento, activa) {
  elemento.classList.toggle("alarma", !!activa);
}

function franja(texto, nivel) {
  const el = $("franja");
  el.textContent = texto;
  el.className = nivel;
}

function conexion(mensaje, ok) {
  const el = $("conexion");
  el.textContent = mensaje;
  el.className = ok ? "ok" : "fail";
}


// Consultas a /api/estado: más espaciadas cuando el canal en vivo funciona
async function ciclo() {
  await leerDatos();
  setTimeout(ciclo, hayVivo() ? INTERVALO_CON_VIVO : INTERVALO);
}

$("botonReiniciar").addEventListener("click", reiniciar);
ciclo();
