// ============================================================
//  Detector de Gas y Temperatura - ESP32 (v3)
//
//  - Control local SIEMPRE activo (con o sin WiFi): buzzer, bombas, control de agua.
//  - La red corre en otra tarea (core 0) y nunca bloquea las alarmas (core 1).
//  - Envía a Supabase por la RPC registrar_lectura (con token del dispositivo).
//  - Revisa comandos remotos (botón "Reiniciar" de la web).
//
//  Credenciales en secrets.h (copiar desde secrets.example.h).
//  Documentación: contexto proyecto/CONTEXTO_PROYECTO.md y PLAN_CONTINGENCIAS.md
// ============================================================
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <esp_task_wdt.h>
#include <esp_system.h>
#include <esp_arduino_version.h>
#include <time.h>
#include "secrets.h"

// ---------------- Pines ----------------
const int PIN_LM35   = 34;   // ADC1
const int PIN_MQ7    = 35;   // ADC1
const int PIN_BOMBA1 = 25;   // Relé IN1 (activo en LOW)
const int PIN_BOMBA2 = 26;   // Relé IN2 (activo en LOW)
const int PIN_BUZZER = 27;   // Transistor NPN (HIGH = suena)

// ---------------- Umbrales con histéresis ----------------
const float TEMP_ON  = 45.0;   // °C: enciende bombas
const float TEMP_OFF = 43.0;   // °C: apaga bombas
const float GAS_ON   = 1.5;    // V: activa alarma de gas
const float GAS_OFF  = 1.3;    // V: desactiva alarma de gas

// Divisor de tensión en el MQ-7 (AOUT puede superar 3.3 V).
// Sin divisor: 1.0 | Con divisor 10k (arriba) / 20k (abajo): 1.5
const float FACTOR_DIVISOR_MQ7 = 1.0;

// ---------------- Validez de los sensores ----------------
const float TEMP_MIN_VALIDA = 1.0;     // por debajo: LM35 desconectado
const float TEMP_MAX_VALIDA = 125.0;   // por encima: entrada flotando o sensor dañado
const float GAS_MIN_VALIDO  = 0.01;    // por debajo: MQ-7 desconectado

// ---------------- Agua (depósito limitado) ----------------
const float CAPACIDAD_ML    = 500.0;   // ajustar al depósito real
// Caudal REAL por bomba en ml/s. 0 = SIN CALIBRAR (todavía no medido).
// Sin calibrar: no se descuenta agua ni se bloquean las bombas (funcionan mientras
// haya calor) -> VIGILAR EL DEPÓSITO A LA VISTA. Para medirlo: una bomba llena un vaso
// durante 10 s; caudal = ml llenados / 10. Al poner el valor, el control de agua se activa solo.
const float CAUDAL_ML_POR_S = 0.0;
const float RESERVA_ML      = 50.0;    // nunca se consume (evita que las bombas trabajen en seco)
const int   NUM_BOMBAS      = 2;
const bool  AGUA_CALIBRADA  = CAUDAL_ML_POR_S > 0;

// Relé: apagar dejando el pin en alta impedancia (INPUT).
// Así un módulo de 5 V se apaga aunque el ESP32 trabaje a 3.3 V.
// Si tu módulo se ENCIENDE con INPUT, cambia a false (se apagará con HIGH).
const bool APAGAR_RELE_CON_INPUT = true;

// ---------------- Tiempos ----------------
const unsigned long PRECALENTAMIENTO_MS = 60000;  // MQ-7 sin evaluar al arrancar
const unsigned long LECTURA_MS          = 1000;   // lectura de sensores
const unsigned long ENVIO_MS            = 5000;   // envío periódico
const unsigned long COMANDO_MS          = 5000;   // revisión de comandos remotos
const unsigned long REINTENTO_WIFI_MS   = 30000;  // forzar reconexión si no conecta
const uint32_t      WDT_TIMEOUT_S       = 10;     // watchdog
const int           MAX_EVENTOS         = 50;     // buffer de eventos sin red

// ---------------- Tipos ----------------
struct Lectura {
  float  temp;
  float  gas_v;
  bool   calor, gas, falla, sin_agua, precalentando;
  float  agua_ml;
  time_t epoch;   // 0 si todavía no hay hora NTP
};

// ---------------- Estado (solo lo toca el loop, core 1) ----------------
float temp = 0, gasV = 0;
bool  calor = false, gas = false, falla = false, sinAgua = false, precalentando = true;
bool  bombasEncendidas = false;
float aguaMl = CAPACIDAD_ML;
bool  prevCalor = false, prevGas = false, prevFalla = false, prevSinAgua = false;
unsigned long ultimaLectura = 0, ultimoEnvio = 0, ultimoTickAgua = 0;

QueueHandle_t colaUltima;    // última lectura periódica (largo 1)
QueueHandle_t colaEventos;   // cambios de estado pendientes de envío

// ============================================================
//  Sensores (fórmulas en uso, sin cambios)
// ============================================================
float leerTemperatura() {
  float lectemp = analogReadMilliVolts(PIN_LM35);
  return ((lectemp * 3.3) / 4095.0) * 100.0;
}

float leerGas() {
  float lecmq7 = analogReadMilliVolts(PIN_MQ7);
  return ((lecmq7 * 3.3) / 4095.0) * FACTOR_DIVISOR_MQ7;
}

// ============================================================
//  Actuadores
// ============================================================
void apagarRele(int pin) {
  if (APAGAR_RELE_CON_INPUT) {
    pinMode(pin, INPUT);
  } else {
    digitalWrite(pin, HIGH);
    pinMode(pin, OUTPUT);
  }
}

void encenderRele(int pin) {
  digitalWrite(pin, LOW);   // primero el nivel, luego la salida: sin pulsos
  pinMode(pin, OUTPUT);
}

void aplicarBombas(bool encender) {
  if (encender == bombasEncendidas) return;
  if (encender) { encenderRele(PIN_BOMBA1); encenderRele(PIN_BOMBA2); }
  else          { apagarRele(PIN_BOMBA1);   apagarRele(PIN_BOMBA2); }
  bombasEncendidas = encender;
  Serial.println(encender ? ">> Bombas ENCENDIDAS" : ">> Bombas APAGADAS");
}

// Patrones del buzzer (prioridad: gas > falla > sin agua)
void actualizarBuzzer(unsigned long ahora) {
  bool on = false;
  if (gas) {
    on = true;                                       // gas: continuo
  } else if (falla) {
    unsigned long f = ahora % 1000;                  // falla: 2 pitidos cortos por segundo
    on = (f < 100) || (f >= 200 && f < 300);
  } else if (sinAgua) {
    on = (ahora % 2000) < 1000;                      // sin agua: largo y alterno
  }
  digitalWrite(PIN_BUZZER, on ? HIGH : LOW);
}

// ============================================================
//  Lecturas y eventos
// ============================================================
float autonomiaSegundos() {
  if (!AGUA_CALIBRADA) return 0;
  float util = aguaMl - RESERVA_ML;
  if (util < 0) util = 0;
  return util / (NUM_BOMBAS * CAUDAL_ML_POR_S);
}

Lectura armarLectura() {
  Lectura l;
  l.temp = temp;
  l.gas_v = gasV;
  l.calor = calor;
  l.gas = gas;
  l.falla = falla;
  l.sin_agua = sinAgua;
  l.precalentando = precalentando;
  l.agua_ml = aguaMl;
  time_t t = time(nullptr);
  l.epoch = (t > 1700000000) ? t : 0;
  return l;
}

// Guarda el evento; si el buffer está lleno, descarta el más antiguo.
void encolarEvento() {
  Lectura l = armarLectura();
  if (xQueueSend(colaEventos, &l, 0) != pdTRUE) {
    Lectura descartada;
    xQueueReceive(colaEventos, &descartada, 0);
    xQueueSend(colaEventos, &l, 0);
    Serial.println("[Buffer] Lleno: se descartó el evento más antiguo");
  }
}

void revisarCambios() {
  if (calor != prevCalor || gas != prevGas || falla != prevFalla || sinAgua != prevSinAgua) {
    encolarEvento();
    prevCalor = calor; prevGas = gas; prevFalla = falla; prevSinAgua = sinAgua;
  }
}

void controlAgua(unsigned long ahora) {
  float dt = (ahora - ultimoTickAgua) / 1000.0;
  ultimoTickAgua = ahora;
  if (!AGUA_CALIBRADA || !bombasEncendidas) return;   // sin calibrar: no se inventa el consumo

  aguaMl -= NUM_BOMBAS * CAUDAL_ML_POR_S * dt;
  if (aguaMl <= RESERVA_ML) {
    if (aguaMl < 0) aguaMl = 0;
    sinAgua = true;
    aplicarBombas(false);
    Serial.println("!! SIN AGUA: bombas bloqueadas. Recargar el depósito y reiniciar (web o botón EN).");
    revisarCambios();
  }
}

void cicloSensores(unsigned long ahora) {
  temp = leerTemperatura();
  gasV = leerGas();
  precalentando = ahora < PRECALENTAMIENTO_MS;

  bool fallaTemp = (temp < TEMP_MIN_VALIDA) || (temp > TEMP_MAX_VALIDA);
  bool fallaGas  = !precalentando && (gasV < GAS_MIN_VALIDO);

  // Calor con histéresis. Si el LM35 falla, se conserva el último estado:
  // en un incendio el sensor puede quemarse y las bombas deben seguir.
  if (!fallaTemp) {
    if (!calor && temp > TEMP_ON)  calor = true;
    else if (calor && temp < TEMP_OFF) calor = false;
  }

  // Gas con histéresis (no se evalúa durante el precalentamiento)
  if (precalentando || fallaGas) {
    gas = false;
  } else {
    if (!gas && gasV > GAS_ON)  gas = true;
    else if (gas && gasV < GAS_OFF) gas = false;
  }

  falla = fallaTemp || fallaGas;

  aplicarBombas(calor && !sinAgua);
  revisarCambios();

  if (ahora - ultimoEnvio >= ENVIO_MS) {
    ultimoEnvio = ahora;
    Lectura l = armarLectura();
    xQueueOverwrite(colaUltima, &l);
  }

  char textoAgua[24];
  if (AGUA_CALIBRADA) snprintf(textoAgua, sizeof(textoAgua), "%.0f ml%s", aguaMl, sinAgua ? " SIN AGUA" : "");
  else                snprintf(textoAgua, sizeof(textoAgua), "sin calibrar");
  Serial.printf("Temp: %.2f °C | Gas (V): %.2f%s | calor=%d gas=%d falla=%d | agua=%s | WiFi=%s\n",
                temp, gasV, precalentando ? " (precalentando)" : "",
                calor, gas, falla, textoAgua,
                WiFi.status() == WL_CONNECTED ? "ok" : "sin conexión");
}

// ============================================================
//  Red (tarea en core 0)
// ============================================================
const char* b(bool v) { return v ? "true" : "false"; }

int llamarRPC(WiFiClientSecure& cliente, const char* funcion, const String& cuerpo, String* respuesta) {
  HTTPClient http;
  String url = String(SUPABASE_URL) + "/rest/v1/rpc/" + funcion;
  if (!http.begin(cliente, url)) return -1;
  http.setConnectTimeout(3000);
  http.setTimeout(3000);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("apikey", SUPABASE_KEY);
  http.addHeader("Authorization", String("Bearer ") + SUPABASE_KEY);

  int codigo = http.POST(cuerpo);
  if (codigo > 0) {
    String cuerpoResp = http.getString();
    if (respuesta) *respuesta = cuerpoResp;
    if (codigo >= 300) Serial.printf("[Supabase] %s -> HTTP %d: %s\n", funcion, codigo, cuerpoResp.c_str());
  } else {
    Serial.printf("[Supabase] %s -> error de conexión (%d)\n", funcion, codigo);
  }
  http.end();
  return codigo;
}

bool enviarLectura(WiFiClientSecure& cliente, const Lectura& l) {
  String json = "{\"p_token\":\"" + String(DEVICE_TOKEN) + "\"";
  json += ",\"p_temperatura\":"   + String(l.temp, 2);
  json += ",\"p_gas\":"           + String(l.gas_v, 2);
  json += ",\"p_calor\":"         + String(b(l.calor));
  json += ",\"p_alerta_gas\":"    + String(b(l.gas));
  json += ",\"p_falla\":"         + String(b(l.falla));
  json += ",\"p_sin_agua\":"      + String(b(l.sin_agua));
  json += ",\"p_precalentando\":" + String(b(l.precalentando));
  if (AGUA_CALIBRADA) json += ",\"p_agua_ml\":" + String(l.agua_ml, 1);   // sin calibrar: se guarda null
  // Configuración del depósito: la base la guarda en "dispositivos", no en cada lectura
  json += ",\"p_capacidad_ml\":"    + String(CAPACIDAD_ML, 1);
  json += ",\"p_caudal_ml_por_s\":" + String(CAUDAL_ML_POR_S, 2);
  json += ",\"p_reserva_ml\":"      + String(RESERVA_ML, 1);
  json += ",\"p_num_bombas\":"      + String(NUM_BOMBAS);
  if (l.epoch > 0) {
    char buf[25];
    struct tm t;
    gmtime_r(&l.epoch, &t);
    strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &t);
    json += ",\"p_fecha\":\"" + String(buf) + "\"";
  }
  json += "}";

  int codigo = llamarRPC(cliente, "registrar_lectura", json, nullptr);
  return codigo >= 200 && codigo < 300;
}

void revisarComandos(WiFiClientSecure& cliente) {
  String resp;
  String cuerpo = "{\"p_token\":\"" + String(DEVICE_TOKEN) + "\"}";
  if (llamarRPC(cliente, "obtener_comando", cuerpo, &resp) != 200) return;
  if (resp.indexOf("\"comando\":\"reiniciar\"") < 0) return;

  int i = resp.indexOf("\"id\":");
  if (i < 0) return;
  long id = resp.substring(i + 5).toInt();

  String confirmar = "{\"p_token\":\"" + String(DEVICE_TOKEN) + "\",\"p_id\":" + String(id) + "}";
  int codigo = llamarRPC(cliente, "confirmar_comando", confirmar, nullptr);
  if (codigo >= 200 && codigo < 300) {
    Serial.println(">> Comando remoto: reiniciando (depósito recargado)...");
    delay(200);
    ESP.restart();
  }
}

void tareaRed(void* parametro) {
  WiFiClientSecure cliente;
  cliente.setInsecure();          // prototipo: sin validar el certificado
  cliente.setHandshakeTimeout(5);

  bool ntpConfigurado = false;
  unsigned long espera = 0, inicioEspera = 0, ultimoComando = 0, ultimoIntentoWifi = millis();

  for (;;) {
    if (WiFi.status() != WL_CONNECTED) {
      if (millis() - ultimoIntentoWifi >= REINTENTO_WIFI_MS) {
        ultimoIntentoWifi = millis();
        WiFi.disconnect();
        WiFi.begin(WIFI_SSID, WIFI_PASS);
      }
      vTaskDelay(pdMS_TO_TICKS(500));
      continue;
    }
    ultimoIntentoWifi = millis();

    if (!ntpConfigurado) {
      configTime(-4 * 3600, 0, "pool.ntp.org", "time.google.com");   // Bolivia: UTC-4
      ntpConfigurado = true;
    }

    if (espera > 0 && millis() - inicioEspera < espera) {
      vTaskDelay(pdMS_TO_TICKS(200));
      continue;
    }

    bool ok = true;
    Lectura l;

    // 1. Eventos pendientes (incluye los guardados mientras no había red)
    while (ok && xQueueReceive(colaEventos, &l, 0) == pdTRUE) {
      ok = enviarLectura(cliente, l);
      if (!ok) xQueueSendToFront(colaEventos, &l, 0);
      else vTaskDelay(pdMS_TO_TICKS(1100));   // la RPC acepta 1 envío por segundo
    }

    // 2. Última lectura periódica
    if (ok && xQueueReceive(colaUltima, &l, 0) == pdTRUE) {
      ok = enviarLectura(cliente, l);
      if (ok) vTaskDelay(pdMS_TO_TICKS(1100));
    }

    // 3. Comandos remotos
    if (ok && millis() - ultimoComando >= COMANDO_MS) {
      ultimoComando = millis();
      revisarComandos(cliente);
    }

    if (ok) {
      espera = 0;
    } else {
      espera = (espera == 0) ? 5000 : min(espera * 2, 60000UL);
      inicioEspera = millis();
      Serial.printf("[Red] Fallo de envío, reintento en %lu s\n", espera / 1000);
    }
    vTaskDelay(pdMS_TO_TICKS(200));
  }
}

// ============================================================
//  Arranque
// ============================================================
const char* motivoReinicio() {
  switch (esp_reset_reason()) {
    case ESP_RST_POWERON:  return "encendido normal";
    case ESP_RST_SW:       return "reinicio por software (comando remoto)";
    case ESP_RST_EXT:      return "botón EN / reinicio externo";
    case ESP_RST_PANIC:    return "error del programa (panic)";
    case ESP_RST_INT_WDT:
    case ESP_RST_TASK_WDT:
    case ESP_RST_WDT:      return "WATCHDOG: el programa se colgó";
    case ESP_RST_BROWNOUT: return "CAÍDA DE TENSIÓN (brownout): revisar fuente, bombas, diodos y capacitor";
    default:               return "otro";
  }
}

void iniciarWatchdog() {
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  esp_task_wdt_config_t cfg = {};
  cfg.timeout_ms = WDT_TIMEOUT_S * 1000;
  cfg.idle_core_mask = 0;
  cfg.trigger_panic = true;
  if (esp_task_wdt_reconfigure(&cfg) != ESP_OK) esp_task_wdt_init(&cfg);
#else
  esp_task_wdt_init(WDT_TIMEOUT_S, true);
#endif
  esp_task_wdt_add(NULL);   // vigila el loop
}

void setup() {
  // Estado seguro ANTES que nada: buzzer apagado y bombas apagadas
  digitalWrite(PIN_BUZZER, LOW);
  pinMode(PIN_BUZZER, OUTPUT);
  apagarRele(PIN_BOMBA1);
  apagarRele(PIN_BOMBA2);

  Serial.begin(115200);
  delay(200);
  Serial.printf("\n=== Detector v3 ===\nMotivo del reinicio: %s\n", motivoReinicio());

  colaUltima  = xQueueCreate(1, sizeof(Lectura));
  colaEventos = xQueueCreate(MAX_EVENTOS, sizeof(Lectura));

  iniciarWatchdog();

  // WiFi sin bloquear: el control local funciona aunque no haya red
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  xTaskCreatePinnedToCore(tareaRed, "red", 12288, nullptr, 1, nullptr, 0);

  aguaMl = CAPACIDAD_ML;   // al arrancar se asume el depósito recargado
  ultimoTickAgua = millis();
  if (AGUA_CALIBRADA) {
    Serial.printf("Depósito: %.0f ml | Autonomía con %d bombas: %.0f s\n",
                  CAPACIDAD_ML, NUM_BOMBAS, autonomiaSegundos());
  } else {
    Serial.println("⚠️ Caudal SIN CALIBRAR: control de agua desactivado. Las bombas funcionan mientras haya calor.");
    Serial.println("   Vigilar el depósito a la vista. Medir el caudal y ponerlo en CAUDAL_ML_POR_S.");
  }
  Serial.println("Precalentando MQ-7 (60 s): la alarma de gas se activa al terminar. La temperatura ya funciona.");
}

void loop() {
  esp_task_wdt_reset();
  unsigned long ahora = millis();

  controlAgua(ahora);
  if (ahora - ultimaLectura >= LECTURA_MS) {
    ultimaLectura = ahora;
    cicloSensores(ahora);
  }
  actualizarBuzzer(ahora);

  delay(10);
}
