// POST /api/comando   body: { "pin": "..." }
// Ordena al ESP32 reiniciarse (se usa después de recargar el depósito de agua).
// Protegido por ADMIN_PIN (variable de entorno de Vercel).
const crypto = require("crypto");
const { configuracion, consultar } = require("./_supabase");

const PIN_MIN = 8;            // PIN corto = fácil de adivinar
const ESPERA_MIN_S = 30;      // anti-abuso entre comandos
const VIGENCIA_S = 120;       // el ESP32 ignora comandos más viejos

function pinCorrecto(recibido, esperado) {
  // Comparación en tiempo constante (hash para igualar longitudes)
  const a = crypto.createHash("sha256").update(String(recibido)).digest();
  const b = crypto.createHash("sha256").update(String(esperado)).digest();
  return crypto.timingSafeEqual(a, b);
}

module.exports = async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json({ ok: false, mensaje: "Método no permitido" });
  }

  const cfg = configuracion();
  const adminPin = process.env.ADMIN_PIN;
  if (!cfg || !adminPin || adminPin.length < PIN_MIN) {
    return res.status(503).json({
      ok: false,
      mensaje: `Servidor sin configurar: faltan variables o ADMIN_PIN tiene menos de ${PIN_MIN} caracteres`
    });
  }

  const pin = req.body && typeof req.body.pin === "string" ? req.body.pin : "";
  if (!pinCorrecto(pin, adminPin)) {
    await new Promise((r) => setTimeout(r, 1000));   // frena intentos por fuerza bruta
    return res.status(401).json({ ok: false, mensaje: "PIN incorrecto" });
  }

  try {
    const ultimos = await consultar(cfg, "comandos?select=creado,ejecutado&order=creado.desc&limit=1");
    if (ultimos.length) {
      const edad = (Date.now() - new Date(ultimos[0].creado).getTime()) / 1000;
      const pendiente = !ultimos[0].ejecutado && edad < VIGENCIA_S;
      if (edad < ESPERA_MIN_S || pendiente) {
        return res.status(429).json({
          ok: false,
          mensaje: pendiente
            ? "Ya hay un reinicio pendiente: espera a que el ESP32 lo ejecute"
            : `Espera ${Math.ceil(ESPERA_MIN_S - edad)} s antes de volver a intentarlo`
        });
      }
    }

    await consultar(cfg, "comandos", {
      method: "POST",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({ comando: "reiniciar" })
    });

    return res.status(200).json({
      ok: true,
      mensaje: "Orden enviada: el ESP32 se reiniciará en unos segundos. El gas queda 60 s en precalentamiento."
    });
  } catch (error) {
    console.error(error);
    return res.status(503).json({ ok: false, mensaje: "No se pudo registrar la orden" });
  }
};
