import 'dart:convert';

import 'bt_api.dart';

/// Dispositivo "mio" a cui l'utente ha dato un nickname.
///
/// Si riconosce per indirizzo; in alternativa per nome pubblicizzato, utile per i
/// dispositivi BLE che ruotano il MAC (l'indirizzo cambia, il nome di solito no).
class KnownDevice {
  final String nickname;
  final String? address;
  final String? matchName;

  const KnownDevice({required this.nickname, this.address, this.matchName});

  factory KnownDevice.fromJson(Map<String, dynamic> m) => KnownDevice(
        nickname: m['nickname'] as String? ?? '?',
        address: m['address'] as String?,
        matchName: m['matchName'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'nickname': nickname,
        if (address != null) 'address': address,
        if (matchName != null) 'matchName': matchName,
      };

  bool matches(DiscoveredDevice d) =>
      (address != null && address!.toUpperCase() == d.address.toUpperCase()) ||
      (matchName != null && matchName!.isNotEmpty && matchName == d.name);
}

List<KnownDevice> decodeKnown(String json) {
  try {
    final raw = jsonDecode(json);
    if (raw is! List) return [];
    return [for (final e in raw) if (e is Map) KnownDevice.fromJson(e.map((k, v) => MapEntry('$k', v)))];
  } catch (_) {
    return [];
  }
}

String encodeKnown(List<KnownDevice> list) => jsonEncode([for (final k in list) k.toJson()]);

/// Tipo di indirizzo, utile per capire se il dispositivo è riconoscibile nel tempo.
enum AddrKind { public, staticRandom, rotating, nonResolvable, unknown }

String addrKindLabel(AddrKind k) => switch (k) {
      AddrKind.public => 'MAC fisso',
      AddrKind.staticRandom => 'MAC random statico',
      AddrKind.rotating => 'MAC random che ruota',
      AddrKind.nonResolvable => 'MAC random usa e getta',
      AddrKind.unknown => 'tipo MAC ignoto',
    };

/// [addrType]: 0 pubblico, 1 random (da Android 15), null se non disponibile.
/// Per un indirizzo random, i due bit alti del primo byte ne danno il sottotipo.
AddrKind addrKind(String address, int? addrType, {required bool le}) {
  final first = int.tryParse(address.split(':').first, radix: 16);
  if (addrType == 0) return AddrKind.public;
  if (first == null) return AddrKind.unknown;
  final top = first >> 6;
  if (addrType == 1) {
    return switch (top) {
      3 => AddrKind.staticRandom,
      1 => AddrKind.rotating,
      0 => AddrKind.nonResolvable,
      _ => AddrKind.unknown,
    };
  }
  // Senza il tipo esplicito: un indirizzo solo-BLE con bit 01 è quasi sempre un RPA.
  if (le && top == 1) return AddrKind.rotating;
  return AddrKind.unknown;
}

/// Company ID Bluetooth SIG più frequenti negli advertising.
const _companies = {
  0x0006: 'Microsoft',
  0x000A: 'Qualcomm (CSR)',
  0x000F: 'Broadcom',
  0x004C: 'Apple',
  0x0059: 'Nordic Semiconductor',
  0x0067: 'GN Netcom (Jabra)',
  0x0075: 'Samsung',
  0x0087: 'Garmin',
  0x009E: 'Bose',
  0x00E0: 'Google',
  0x012D: 'Sony',
  0x0157: 'Huami (Amazfit/Zepp)',
  0x0171: 'Amazon',
  0x02E5: 'Espressif (ESP32)',
  0x038F: 'Xiaomi',
};

String companyName(int id) => _companies[id] ?? 'produttore 0x${id.toRadixString(16).toUpperCase().padLeft(4, '0')}';

/// Servizi BLE a 16 bit che dicono cosa è il dispositivo.
const _leServices = {
  0xFCB2: 'Tracker (standard anti-tracciamento DULT)',
  0xFD5A: 'Samsung SmartTag',
  0xFE2C: 'Google Fast Pair',
  0xFEAA: 'Eddystone / rete Trova il mio dispositivo',
  0xFEEC: 'Tile',
  0xFEED: 'Tile',
  0x180D: 'Fascia/sensore cardio',
  0x180F: 'Batteria',
  0x1812: 'Tastiera/mouse/telecomando (HID)',
  0x1816: 'Sensore bici (velocità/cadenza)',
  0x1826: 'Attrezzo fitness',
  0x184E: 'LE Audio',
};

int? _short(String uuid) {
  final u = uuid.toLowerCase();
  if (u.length == 36 && u.startsWith('0000') && u.endsWith('-0000-1000-8000-00805f9b34fb')) {
    return int.tryParse(u.substring(4, 8), radix: 16);
  }
  return null;
}

/// Dispositivo visto durante la discovery (Classic e/o BLE), aggregato per indirizzo.
class DiscoveredDevice {
  final String address;
  String? name;
  int? rssi;
  DateTime firstSeen;
  DateTime lastSeen;
  int seen = 0;
  bool classic = false;
  bool le = false;
  bool bonded = false;
  bool? connectable;
  int? addrType;
  int? cod;
  int? deviceClass;
  int? txPower;

  /// Company ID → payload esadecimale (troncato).
  final Map<int, String> manufacturer = {};
  final Set<String> services = {};

  /// UUID di servizio → payload esadecimale (troncato).
  final Map<String, String> serviceData = {};

  DiscoveredDevice(this.address, DateTime t)
      : firstSeen = t,
        lastSeen = t;

  void update(BtEvent e) {
    final x = e.extras;
    lastSeen = e.ts;
    seen++;
    final n = x['advName'] ?? e.name;
    if (n != null && n.isNotEmpty) name = n;
    rssi = int.tryParse(x['rssi'] ?? '') ?? rssi;
    if (e.action == 'LE_FOUND') {
      le = true;
    } else {
      classic = true;
    }
    if (x['bond'] == '12') bonded = true;
    if (x['connectable'] != null) connectable = x['connectable'] == 'true';
    addrType = int.tryParse(x['addrType'] ?? '') ?? addrType;
    cod = int.tryParse(x['cod'] ?? '') ?? cod;
    deviceClass = int.tryParse(x['deviceClass'] ?? '') ?? deviceClass;
    txPower = int.tryParse(x['txPower'] ?? '') ?? txPower;
    for (final part in (x['mfr'] ?? '').split(',')) {
      final i = part.indexOf(':');
      if (i <= 0) continue;
      final id = int.tryParse(part.substring(0, i), radix: 16);
      if (id != null) manufacturer[id] = part.substring(i + 1);
    }
    for (final s in (x['svc'] ?? '').split(',')) {
      if (s.isNotEmpty) services.add(s.toLowerCase());
    }
    for (final part in (x['svcData'] ?? '').split(',')) {
      final i = part.lastIndexOf(':');
      if (i <= 0) continue;
      final uuid = part.substring(0, i).toLowerCase();
      serviceData[uuid] = part.substring(i + 1);
      services.add(uuid);
    }
  }

  AddrKind get kind => addrKind(address, addrType, le: le && !classic);

  Iterable<int> get _shortServices => services.map(_short).whereType<int>();

  String? get vendor => manufacturer.isEmpty ? null : companyName(manufacturer.keys.first);

  /// Ipotesi su cosa sia, dagli advertising. null se non c'è nulla di riconoscibile.
  String? get hint {
    for (final s in _shortServices) {
      if (s == 0xFEAA) {
        final data = serviceData['0000feaa-0000-1000-8000-00805f9b34fb'] ?? '';
        final frame = data.length >= 2 ? data.substring(0, 2) : '';
        if (frame == '40' || frame == '41') return 'Tracker rete Trova il mio dispositivo (Google)';
        return 'Beacon Eddystone';
      }
    }
    for (final s in _shortServices) {
      final h = _leServices[s];
      if (h != null) return h;
    }
    final apple = manufacturer[0x004C];
    if (apple != null && apple.length >= 2) {
      switch (apple.substring(0, 2)) {
        case '12':
          return 'Apple Dov\'è (AirTag o dispositivo Apple smarrito)';
        case '07':
          return 'Auricolari Apple/Beats';
        case '02':
          return 'iBeacon';
        case '10':
        case '0C':
          return 'iPhone/iPad/Mac nelle vicinanze';
      }
      return 'Dispositivo Apple';
    }
    if (manufacturer.containsKey(0x0006)) return 'PC Windows o accessorio Microsoft';
    return null;
  }

  bool get isTracker {
    final h = hint ?? '';
    return h.contains('Tracker') || h.contains('Tile') || h.contains('SmartTag') || h.contains('AirTag');
  }
}

/// Gruppi mostrati nella schermata Discovery.
enum DiscoveryGroup { mine, bonded, unknown }

DiscoveryGroup groupOf(DiscoveredDevice d, List<KnownDevice> known) {
  if (known.any((k) => k.matches(d))) return DiscoveryGroup.mine;
  if (d.bonded) return DiscoveryGroup.bonded;
  return DiscoveryGroup.unknown;
}

KnownDevice? knownFor(DiscoveredDevice d, List<KnownDevice> known) {
  for (final k in known) {
    if (k.matches(d)) return k;
  }
  return null;
}
