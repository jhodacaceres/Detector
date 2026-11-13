// Utilidades compartidas por las funciones de /api (Vercel).
// El prefijo "_" evita que Vercel lo publique como endpoint.
// La secret key vive SOLO en las variables de entorno del servidor.

function configuracion() {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) return null;
  return { url: url.replace(/\/+$/, ""), key };
}

function cabeceras(key, extra = {}) {
  const h = { apikey: key, "Content-Type": "application/json", ...extra };
  // Las keys antiguas (JWT "eyJ...") también requieren Authorization.
  // Las nuevas (sb_secret_...) van solo en "apikey".
  if (key.startsWith("eyJ")) h.Authorization = "Bearer " + key;
  return h;
}

async function consultar(cfg, ruta, opciones = {}) {
  const respuesta = await fetch(cfg.url + "/rest/v1/" + ruta, {
    ...opciones,
    headers: cabeceras(cfg.key, opciones.headers),
    signal: AbortSignal.timeout(5000)
  });
  if (!respuesta.ok) {
    // No se reenvía el detalle al navegador: solo se registra en los logs de Vercel
    console.error("Supabase", ruta, respuesta.status, await respuesta.text());
    throw new Error("Supabase HTTP " + respuesta.status);
  }
  return respuesta.status === 204 || respuesta.status === 201 ? null : respuesta.json();
}

module.exports = { configuracion, consultar };
