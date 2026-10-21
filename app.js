// ===== Monitor de Gas y Temperatura =====
// Lee la Realtime Database de Firebase por REST cada segundo.
// No necesita SDK ni API key: las reglas estan en lectura publica.

const DB_URL = "https://detector-68ca4-default-rtdb.firebaseio.com/datos.json";
const INTERVALO = 1000;   // milisegundos entre lecturas

// Referencias a los elementos del HTML
const elTemp        = document.getElementById("temp");
const elRatio       = document.getElementById("ratio");
const elEstadoTemp  = document.getElementById("estadoTemp");
const elEstadoGas   = document.getElementById("estadoGas");
const tarjetaTemp   = document.getElementById("tarjetaTemp");
const tarjetaGas    = document.getElementById("tarjetaGas");
const elConexion    = document.getElementById("conexion");
const elActualizado = document.getElementById("actualizado");


async function leerDatos() {
  try {
    // cache: "no-store" evita que el navegador devuelva datos viejos
    const respuesta = await fetch(DB_URL, { cache: "no-store" });

    if (!respuesta.ok) throw new Error("HTTP " + respuesta.status);

    const datos = await respuesta.json();

    if (datos === null) {
      conexion("Base de datos vacia: el ESP32 aun no ha escrito", false);
      return;
    }

    mostrar(datos);
    conexion("Conectado", true);

  } catch (error) {
    conexion("Sin conexion con Firebase", false);
    console.error(error);
  }
}


function mostrar(d) {
  // --- Temperatura ---
  elTemp.textContent = Number(d.temp).toFixed(1);

  if (d.calor) {
    tarjetaTemp.classList.add("alarma");
    elEstadoTemp.textContent = "TEMPERATURA ALTA - BOMBAS ACTIVAS";
  } else {
    tarjetaTemp.classList.remove("alarma");
    elEstadoTemp.textContent = "Normal";
  }

  // --- Gas ---
  elRatio.textContent = Number(d.ratio).toFixed(2);

  if (d.gas) {
    tarjetaGas.classList.add("alarma");
    elEstadoGas.textContent = "GAS DETECTADO - ALARMA ACTIVA";
  } else {
    tarjetaGas.classList.remove("alarma");
    elEstadoGas.textContent = "Sin gas";
  }

  // --- Hora de la ultima lectura ---
  const ahora = new Date();
  elActualizado.textContent = "Actualizado: " + ahora.toLocaleTimeString("es-BO");
}


function conexion(mensaje, ok) {
  elConexion.textContent = mensaje;
  elConexion.className = ok ? "ok" : "fail";
}


// Primera lectura inmediata, luego cada segundo
leerDatos();
setInterval(leerDatos, INTERVALO);