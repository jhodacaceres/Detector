// ============================================================
//  Plantilla de credenciales.
//  1. Copia este archivo como "secrets.h" en esta misma carpeta.
//  2. Completa los valores reales.
//  secrets.h está en .gitignore: NUNCA lo subas a GitHub.
// ============================================================
#pragma once

// WiFi (solo redes de 2.4 GHz)
#define WIFI_SSID     "NOMBRE_DE_TU_WIFI"
#define WIFI_PASS     "CONTRASENA_DE_TU_WIFI"

// Supabase: URL del proyecto (sin barra final) y key publishable (sb_publishable_...)
#define SUPABASE_URL  "https://TU_PROYECTO.supabase.co"
#define SUPABASE_KEY  "sb_publishable_XXXXXXXXXXXXXXXX"

// Token del dispositivo: se genera con supabase/configuracion_manual.sql (paso 1)
#define DEVICE_TOKEN  "PEGAR_AQUI_EL_TOKEN_DEL_DISPOSITIVO"
