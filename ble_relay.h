// Relais BLE vers l'app iPhone "Kona Relay" — NimBLE-Arduino 2.x (h2zero)
// v5 (ws-2.5) : files d'attente (4 messages) pour les commandes et les accusés : une commande arrivée pendant qu'une
//               autre attend n'est plus perdue ; seule la déconnexion de l'iPhone abonné coupe l'envoi des données
// v4 : caractéristique OTA (firmware envoyé par l'iPhone, écriture chiffrée)
// v3 : accusés de réception de la synchro des trajets (caractéristique ACK, non chiffrée)
// v2 : caractéristique de commande (écriture chiffrée, appairage par code à 6 chiffres)
// Le JSON est envoyé en morceaux (taille selon le MTU) et se termine par un saut de ligne.
#pragma once
#include <NimBLEDevice.h>
#include <esp_task_wdt.h>

#define KR_SVC  "6E4B0001-9A3C-4F2B-8C11-4B4F4E415343"
#define KR_DATA "6E4B0002-9A3C-4F2B-8C11-4B4F4E415343"
#define KR_CMD  "6E4B0003-9A3C-4F2B-8C11-4B4F4E415343"
#define KR_ACK  "6E4B0004-9A3C-4F2B-8C11-4B4F4E415343"
#define KR_OTA  "6E4B0005-9A3C-4F2B-8C11-4B4F4E415343"
#ifndef KR_PASSKEY
#define KR_PASSKEY 123456
#endif

namespace kr {
static NimBLEServer* srv = nullptr;
static NimBLECharacteristic* data = nullptr;
static volatile bool active = false, connected = false, ready = false;
static volatile uint16_t conn = 0xFFFF;                   // iPhone abonné aux données
static const uint8_t NQ = 4;                              // files : écrites par la tâche NimBLE, lues par loop()
static char pend[NQ][256];
static volatile uint8_t pendW = 0, pendR = 0;
static char ackBuf[NQ][32];
static volatile uint8_t ackW = 0, ackR = 0;
static void (*otaSink)(const uint8_t*, size_t) = nullptr;   // fourni par le .ino

template <size_t N>
static void qPush(char (&q)[NQ][N], volatile uint8_t& w, volatile uint8_t& r, const uint8_t* d, size_t len) {
  uint8_t i = w, nx = (i + 1) % NQ;
  if (nx == r) return;                                    // file pleine : message ignoré
  size_t n = len < N - 1 ? len : N - 1;
  memcpy(q[i], d, n); q[i][n] = 0;
  __sync_synchronize();
  w = nx;
}
template <size_t N>
static bool qTake(char (&q)[NQ][N], volatile uint8_t& w, volatile uint8_t& r, String& out) {
  uint8_t i = r;
  if (i == w) return false;
  __sync_synchronize();
  out = String(q[i]);
  __sync_synchronize();
  r = (i + 1) % NQ;
  return true;
}

class SCb : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer*, NimBLEConnInfo&) override { connected = true; }
  void onDisconnect(NimBLEServer*, NimBLEConnInfo& i, int) override {
    if (i.getConnHandle() == conn) { connected = false; ready = false; conn = 0xFFFF; }
    if (active) NimBLEDevice::startAdvertising();
  }
  uint32_t onPassKeyDisplay() override { return KR_PASSKEY; }
};
class WCb : public NimBLECharacteristicCallbacks {      // commande reçue (lien chiffré et authentifié)
  void onWrite(NimBLECharacteristic* ch, NimBLEConnInfo&) override {
    NimBLEAttValue v = ch->getValue();
    qPush(pend, pendW, pendR, v.data(), v.size());
  }
};
class ACb : public NimBLECharacteristicCallbacks {      // accusé de l'app après envoi réussi à Home Assistant
  void onWrite(NimBLECharacteristic* ch, NimBLEConnInfo&) override {
    NimBLEAttValue v = ch->getValue();
    qPush(ackBuf, ackW, ackR, v.data(), v.size());
  }
};
class OCb : public NimBLECharacteristicCallbacks {      // morceaux du firmware
  void onWrite(NimBLECharacteristic* ch, NimBLEConnInfo&) override {
    if (!otaSink) return;
    NimBLEAttValue v = ch->getValue();
    otaSink(v.data(), v.size());
  }
};
class CCb : public NimBLECharacteristicCallbacks {
  void onSubscribe(NimBLECharacteristic*, NimBLEConnInfo& i, uint16_t v) override {
    if (v & 1) { conn = i.getConnHandle(); ready = true; }
    else if (i.getConnHandle() == conn) ready = false;
  }
};

inline void reset() { pendW = 0; pendR = 0; ackW = 0; ackR = 0; conn = 0xFFFF; connected = false; ready = false; }

inline void begin() {
  if (active) return;
  reset();
  NimBLEDevice::init("KonaRelay");
  NimBLEDevice::setMTU(247);
  NimBLEDevice::setSecurityAuth(true, true, true);         // appairage, MITM, Secure Connections
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_DISPLAY_ONLY);  // l'iPhone demande le code à 6 chiffres
  srv = NimBLEDevice::createServer();
  srv->setCallbacks(new SCb());
  NimBLEService* svc = srv->createService(KR_SVC);
  data = svc->createCharacteristic(KR_DATA, NIMBLE_PROPERTY::NOTIFY);
  data->setCallbacks(new CCb());
  NimBLECharacteristic* cmd = svc->createCharacteristic(KR_CMD,
      NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_ENC | NIMBLE_PROPERTY::WRITE_AUTHEN);
  cmd->setCallbacks(new WCb());
  NimBLECharacteristic* ack = svc->createCharacteristic(KR_ACK, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  ack->setCallbacks(new ACb());
  NimBLECharacteristic* ota = svc->createCharacteristic(KR_OTA,
      NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::WRITE_ENC | NIMBLE_PROPERTY::WRITE_AUTHEN);
  ota->setCallbacks(new OCb());
  svc->start();
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(KR_SVC);
  adv->start();
  active = true;
}

inline void end() {
  if (!active) return;
  active = false;
  NimBLEDevice::deinit(true);
  srv = nullptr; data = nullptr;
  reset();                                                 // pas de commande périmée au prochain démarrage du BLE
}

// Commande en attente reçue de l'iPhone (texte), à traiter dans loop()
inline bool take(String& out) { return qTake(pend, pendW, pendR, out); }

inline bool takeAck(String& out) { return qTake(ackBuf, ackW, ackR, out); }

// Envoie un JSON complet, découpé selon le MTU négocié. Renvoie false si l'iPhone n'est pas abonné.
inline bool send(const String& j) {
  if (!active || !ready || !data) return false;
  uint16_t mtu = srv->getPeerMTU(conn);
  size_t room = (mtu > 26 ? mtu : 23) - 3;                 // 3 octets d'en-tête ATT
  if (room > 244) room = 244;
  String m = j + "\n";
  const uint8_t* p = (const uint8_t*)m.c_str();
  size_t len = m.length(), off = 0;
  while (off < len && ready) {
    size_t n = min(room, len - off);
    bool ok = false;
    for (int t = 0; t < 20 && ready && !ok; t++) { ok = data->notify(p + off, n); if (!ok) delay(20); }
    if (!ok) return false;
    off += n;
    delay(12);
    esp_task_wdt_reset();
  }
  return off >= len;
}
}  // namespace kr
