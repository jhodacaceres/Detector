// GET /api/estado
// Devuelve solo lo que la web necesita: última lectura y últimas 5 alertas.
// La key de Supabase nunca llega al navegador.
const { configuracion, consultar } = require("./_supabase");

// Une la lectura con la configuración de su dispositivo y calcula la autonomía
// (dato derivado: no se guarda en la base).
function aplanar(registro) {
  if (!registro) return null;
  const { dispositivos: disp, ...lectura } = registro;
  const capacidad = disp && disp.capacidad_ml;
  let autonomia = null;
  if (disp && lectura.agua_ml != null && disp.caudal_ml_por_s > 0 && disp.num_bombas > 0) {
    const util = Math.max(0, lectura.agua_ml - (disp.reserva_ml || 0));
    autonomia = util / (disp.num_bombas * disp.caudal_ml_por_s);
  }
  // Caudal 0 o desconocido = sin calibrar: no se muestra agua ni autonomía inventadas
  const aguaCalibrada = !!(disp && disp.caudal_ml_por_s > 0);
  return { ...lectura, capacidad_ml: capacidad ?? null, autonomia_s: autonomia, agua_calibrada: aguaCalibrada };
}

module.exports = async function handler(req, res) {
  if (req.method !== "GET") {
    res.setHeader("Allow", "GET");
    return res.status(405).json({ error: "Método no permitido" });
  }

  const cfg = configuracion();
  if (!cfg) {
    return res.status(503).json({ error: "Servidor sin configurar: faltan SUPABASE_URL o SUPABASE_SECRET_KEY en Vercel" });
  }

  try {
    const [registros, alertas] = await Promise.all([
      // La configuración del depósito viene del dispositivo (relación registros -> dispositivos)
      consultar(cfg,
        "registros?select=fecha,lectura_temperatura,lectura_gas,calor,gas,falla,sin_agua,precalentando,agua_ml," +
        "dispositivos(capacidad_ml,caudal_ml_por_s,reserva_ml,num_bombas)" +
        "&order=id_registro.desc&limit=1"),
      consultar(cfg,
        "alertas?select=fecha,tipo,lectura_temperatura,lectura_gas&order=id_alertas.desc&limit=5")
    ]);

    // La CDN de Vercel sirve la misma respuesta 2 s: absorbe el tráfico de muchas pestañas
    res.setHeader("Cache-Control", "public, s-maxage=2, stale-while-revalidate=5");
    // Canal en vivo (Realtime): la key PUBLISHABLE es pública por diseño (la misma del ESP32).
    // La secret key nunca sale del servidor. Sin la variable, la web funciona solo con lo guardado.
    const publica = process.env.SUPABASE_PUBLISHABLE_KEY;
    return res.status(200).json({
      ultimo: aplanar(registros[0]),
      alertas,
      servidor: new Date().toISOString(),
      vivo: publica ? { url: cfg.url, key: publica } : null
    });
  } catch (error) {
    console.error(error);
    return res.status(503).json({ error: "No se pudo consultar la base de datos" });
  }
};
