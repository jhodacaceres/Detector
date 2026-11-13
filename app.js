// ===== Monitor de Gas y Temperatura (v3) =====
// La web NO habla con Supabase directamente: usa las funciones de Vercel
//   GET  /api/estado   -> última lectura y últimas alertas
//   POST /api/comando  -> ordena reiniciar el ESP32 (con PIN)
// Así ninguna key queda expuesta en el navegador.

const INTERVALO = 2000;          // ms entre consultas
const MAX_ANTIGUEDAD = 20000;    // ms: si el último dato es más viejo, el ESP32 no está enviando
const ZONA = "America/La_Paz";

const $ = (id) => document.getElementById(id);

const TEXTO_ALERTA = {
  gas: "🚨 Gas detectado",
  calor: "🔥 Temperatura alta",
  falla: "⚠️ Falla de sensor",
  sin_agua: "🚱 Sin agua"
};

let ultimoDato = null;   // se conserva si la consulta falla
let consultando = false;


async function leerDatos() {
  if (consultando) return;
  consultando = true;
  try {
    const respuesta = await fetch("/api/estado", { cache: "no-store" });
    const datos = await respuesta.json().catch(() => ({}));
    if (!respuesta.ok) throw new Error(datos.error || "HTTP " + respuesta.status);

    if (!datos.ultimo) {
      conexion("Conectado", true);
      franja("Sin registros: el ESP32 aún no ha enviado datos", "aviso");
      return;
    }

    ultimoDato = datos.ultimo;
    mostrar(datos.ultimo);
    mostrarAlertas(datos.alertas || []);
    conexion("Conectado", true);
    actualizarFranja(datos.ultimo);

  } catch (error) {
    console.error(error);
    conexion("Sin conexión con el servidor", false);
    if (ultimoDato) {
      franja("Datos desactualizados: se muestra la última lectura conocida", "aviso");
    } else {
      franja("No se pudo obtener datos: " + error.message, "grave");
    }
  } finally {
    consultando = false;
  }
}


function mostrar(d) {
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

  // --- Agua y bombas ---
  const agua = d.agua_ml == null ? null : Number(d.agua_ml);
  const capacidad = d.capacidad_ml == null ? null : Number(d.capacidad_ml);
  $("agua").textContent = agua == null ? "--" : agua.toFixed(0);
  $("tarjetaAgua").classList.toggle("aviso", !d.agua_calibrada);

  if (!d.agua_calibrada) {
    // Caudal no medido: no se muestra un nivel inventado
    $("barraAgua").style.width = "0%";
    $("detalleAgua").textContent = "Caudal SIN CALIBRAR: control de agua desactivado. Vigilar el depósito a la vista.";
  } else if (agua != null && capacidad) {
    const pct = Math.max(0, Math.min(100, (agua / capacidad) * 100));
    $("barraAgua").style.width = pct.toFixed(0) + "%";
    $("detalleAgua").textContent = pct.toFixed(0) + "% de " + capacidad.toFixed(0) + " ml"
      + (d.autonomia_s != null ? " · autonomía ≈ " + Number(d.autonomia_s).toFixed(0) + " s con 2 bombas" : "");
  }

  const tarjetaAgua = $("tarjetaAgua");
  alarma(tarjetaAgua, d.sin_agua);
  if (d.sin_agua)      $("estadoBombas").textContent = "SIN AGUA - BOMBAS BLOQUEADAS";
  else if (d.calor)    $("estadoBombas").textContent = "BOMBAS ACTIVAS";
  else                 $("estadoBombas").textContent = "Bombas apagadas";

  // --- Hora de la lectura ---
  $("actualizado").textContent = "Última lectura: " +
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
function actualizarFranja(d) {
  const antiguedad = Date.now() - new Date(d.fecha).getTime();
  if (antiguedad > MAX_ANTIGUEDAD) {
    franja("ESP32 sin enviar datos recientes (sin WiFi, sin energía o apagado). La alarma local sigue funcionando si tiene energía.", "grave");
  } else if (d.sin_agua) {
    franja("Depósito sin agua: recargar y pulsar «Reiniciar»", "grave");
  } else if (d.gas) {
    franja("GAS DETECTADO: ventilar y evacuar", "grave");
  } else if (d.falla) {
    franja("Falla de sensor: revisar conexiones del LM35 / MQ-7", "grave");
  } else if (d.calor) {
    franja(d.agua_calibrada
      ? "Temperatura alta: bombas activas"
      : "Temperatura alta: bombas activas. Agua sin control: vigilar el depósito para que no trabajen en seco", "grave");
  } else if (d.precalentando) {
    franja("Sensor de gas precalentando (60 s): la alarma de gas aún no está activa", "aviso");
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
  if (!confirm("¿El depósito ya fue recargado? El ESP32 se reiniciará y asumirá el depósito lleno.")) return;

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


$("botonReiniciar").addEventListener("click", reiniciar);
leerDatos();
setInterval(leerDatos, INTERVALO);
