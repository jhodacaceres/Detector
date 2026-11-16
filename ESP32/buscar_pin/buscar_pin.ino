// ============================================================
//  Pruebas de hardware del Detector (todas las pruebas van aquí).
//  Monitor Serie: 115200 baudios y "Nueva línea". Escribe un comando y Enter:
//
//    w      -> prueba de WiFi: busca redes y diagnostica la conexión
//    0      -> pone todos los pines de prueba en LOW
//    número -> ese pin en HIGH 2 s, el resto en LOW (buscar en qué pin está algo)
//
//  ¡Ojo! Los comandos de pines ponen LOW en 25/26: eso ENCIENDE las bombas.
//  Desconectar IN1 e IN2 del relé antes de usarlos.
// ============================================================
#include <WiFi.h>
// Credenciales del proyecto (no se copian aquí: este archivo sí se sube a GitHub)
#include "C:/Users/jhona/Desktop/Detector/ESP32/detector/secrets.h"

const int pines[] = {2, 4, 5, 12, 13, 14, 15, 16, 17, 18, 19,
                     21, 22, 23, 25, 26, 27, 32, 33};
const int N = sizeof(pines) / sizeof(pines[0]);

// ---------------- Pines ----------------
void todosEnLow() {
  for (int i = 0; i < N; i++) {
    pinMode(pines[i], OUTPUT);
    digitalWrite(pines[i], LOW);
  }
}

bool esValido(int pin) {
  for (int i = 0; i < N; i++) {
    if (pines[i] == pin) return true;
  }
  return false;
}

void probarPin(int pin) {
  if (!esValido(pin)) {
    Serial.printf("GPIO %d no esta en la lista\n", pin);
    return;
  }
  todosEnLow();
  Serial.printf(">>> GPIO %d en HIGH por 2 s\n", pin);
  digitalWrite(pin, HIGH);
  delay(2000);
  digitalWrite(pin, LOW);
  Serial.println("Listo.");
}

// ---------------- WiFi ----------------
volatile int ultimaRazon = -1;

const char* nombreSeguridad(int tipo) {
  switch (tipo) {
    case 0: return "ABIERTA";
    case 1: return "WEP (no recomendada)";
    case 2: return "WPA";
    case 3: return "WPA2";
    case 4: return "WPA/WPA2";
    case 5: return "WPA2-Enterprise (NO compatible)";
    case 6: return "WPA3 (puede fallar en ESP32)";
    case 7: return "WPA2/WPA3";
    default: return "otra";
  }
}

const char* explicarRazon(int r) {
  switch (r) {
    case 2:   return "autenticacion vencida";
    case 8:   return "desconexion normal";
    case 15:  return "CONTRASEÑA INCORRECTA (fallo del saludo de 4 vias)";
    case 201: return "NO ENCONTRO LA RED (nombre distinto o red solo de 5 GHz)";
    case 202: return "FALLO DE AUTENTICACION (contraseña o seguridad incompatible)";
    case 203: return "el router rechazo la asociacion (filtro MAC o limite de equipos)";
    case 204: return "CONTRASEÑA INCORRECTA (tiempo agotado en el saludo)";
    case 205: return "fallo de conexion";
    case 210: return "la red usa una SEGURIDAD que el ESP32 no acepta (WPA3 o similar)";
    case 211: return "la seguridad de la red es mas baja que la exigida";
    case 212: return "SEÑAL DEMASIADO DEBIL";
    default:  return "otra (anotar el numero)";
  }
}

void alDesconectar(WiFiEvent_t evento, WiFiEventInfo_t info) {
  ultimaRazon = info.wifi_sta_disconnected.reason;
}

void pruebaWifi() {
  Serial.println("\n===== PRUEBA DE WIFI =====");
  Serial.printf("Buscando: [%s] (los corchetes muestran espacios sobrantes)\n", WIFI_SSID);

  WiFi.disconnect(true);
  WiFi.mode(WIFI_STA);
  delay(200);

  Serial.println("Escaneando redes de 2.4 GHz (el ESP32 no ve las de 5 GHz)...");
  int n = WiFi.scanNetworks();
  bool exacta = false, parecida = false;
  for (int i = 0; i < n; i++) {
    String nombre = WiFi.SSID(i);
    bool esLaMia = (nombre == WIFI_SSID);
    bool similar = !esLaMia && nombre.equalsIgnoreCase(WIFI_SSID);
    if (esLaMia) exacta = true;
    if (similar) parecida = true;
    Serial.printf("%s [%s]  señal %d dBm  canal %d  %s\n",
                  esLaMia ? ">>" : (similar ? "~ " : "  "),
                  nombre.c_str(), WiFi.RSSI(i), WiFi.channel(i),
                  nombreSeguridad((int)WiFi.encryptionType(i)));
  }
  if (n <= 0) Serial.println("No se encontro ninguna red.");
  WiFi.scanDelete();

  if (exacta) {
    Serial.println("=> La red aparece en 2.4 GHz con el nombre exacto (marcada con >>).");
  } else if (parecida) {
    Serial.println("=> Hay una red con el MISMO nombre pero distintas mayusculas (marcada con ~). Corregir WIFI_SSID.");
  } else {
    Serial.println("=> La red NO aparece: o el nombre es distinto, o el router no esta emitiendo en 2.4 GHz.");
  }

  Serial.println("\nIntentando conectar (20 s maximo)...");
  ultimaRazon = -1;
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  unsigned long inicio = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - inicio < 20000) {
    delay(500);
    Serial.print(".");
  }
  Serial.println();

  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("CONECTADO. IP: %s  señal: %d dBm\n",
                  WiFi.localIP().toString().c_str(), WiFi.RSSI());
    if (WiFi.RSSI() < -75) Serial.println("Aviso: señal debil (menos de -75 dBm). Acercar el ESP32 al router.");
  } else {
    Serial.printf("NO CONECTO. Estado: %d\n", (int)WiFi.status());
    if (ultimaRazon >= 0) {
      Serial.printf("Motivo informado por el router: %d -> %s\n", ultimaRazon, explicarRazon(ultimaRazon));
    }
  }
  Serial.println("===== FIN =====\n");
}

// ---------------- Menú ----------------
void ayuda() {
  Serial.println("Comandos: w = prueba de WiFi | 0 = todos los pines en LOW | numero = probar ese pin");
}

void setup() {
  Serial.begin(115200);
  delay(500);
  WiFi.onEvent(alDesconectar, ARDUINO_EVENT_WIFI_STA_DISCONNECTED);
  Serial.println("\n=== Pruebas del Detector ===");
  ayuda();
}

void loop() {
  if (!Serial.available()) return;
  String cmd = Serial.readStringUntil('\n');
  cmd.trim();
  if (cmd.length() == 0) return;

  if (cmd.equalsIgnoreCase("w")) {
    pruebaWifi();
  } else if (cmd == "0") {
    todosEnLow();
    Serial.println("Todos los pines en LOW. Si el buzzer se callo: esta en un GPIO.");
  } else if (cmd.toInt() > 0) {
    probarPin(cmd.toInt());
  } else {
    ayuda();
  }
}
