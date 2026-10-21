/// Tabelle per decodificare UUID di servizio (SDP) e Class of Device.
class ServiceInfo {
  final String code;
  final String name;
  final String note;
  const ServiceInfo(this.code, this.name, this.note);
}

const _base = '-0000-1000-8000-00805f9b34fb';

/// Servizi Bluetooth Classic più comuni (Assigned Numbers, Service Class IDs).
const Map<int, ServiceInfo> _services = {
  0x1101: ServiceInfo('SPP', 'Serial Port', 'Porta seriale RFCOMM generica'),
  0x1103: ServiceInfo('DUN', 'Dial-up Networking', ''),
  0x1105: ServiceInfo('OPP', 'OBEX Object Push', 'Invio file/vCard'),
  0x1106: ServiceInfo('FTP', 'OBEX File Transfer', ''),
  0x1108: ServiceInfo('HSP', 'Headset', 'Profilo cuffia (vecchio, precursore di HFP)'),
  0x110A: ServiceInfo('A2DP-SRC', 'Audio Source', 'Il dispositivo invia audio'),
  0x110B: ServiceInfo('A2DP-SNK', 'Audio Sink', 'Il dispositivo riceve audio (es. autoradio)'),
  0x110C: ServiceInfo('AVRCP-TG', 'A/V Remote Control Target', 'Può essere comandato (play/pausa)'),
  0x110D: ServiceInfo('A2DP', 'Advanced Audio Distribution', ''),
  0x110E: ServiceInfo('AVRCP', 'A/V Remote Control', 'Telecomando multimediale'),
  0x110F: ServiceInfo('AVRCP-CT', 'A/V Remote Control Controller', 'Invia comandi play/pausa/traccia'),
  0x1112: ServiceInfo('HSP-AG', 'Headset Audio Gateway', 'Lato telefono di HSP'),
  0x1115: ServiceInfo('PANU', 'PAN User', 'Tethering'),
  0x1116: ServiceInfo('NAP', 'Network Access Point', 'Tethering'),
  0x111E: ServiceInfo('HFP-HF', 'Handsfree', 'Lato vivavoce (autoradio) di HFP'),
  0x111F: ServiceInfo('HFP-AG', 'Handsfree Audio Gateway', 'Lato telefono di HFP'),
  0x112D: ServiceInfo('SAP', 'SIM Access', ''),
  0x112E: ServiceInfo('PBAP-PCE', 'Phonebook Access Client', 'Scarica la rubrica dal telefono'),
  0x112F: ServiceInfo('PBAP-PSE', 'Phonebook Access Server', 'Fornisce la rubrica'),
  0x1130: ServiceInfo('PBAP', 'Phonebook Access', ''),
  0x1131: ServiceInfo('HSP-HS', 'Headset (HS)', ''),
  0x1132: ServiceInfo('MAP-MAS', 'Message Access Server', 'Fornisce gli SMS'),
  0x1133: ServiceInfo('MAP-MNS', 'Message Notification Server', 'Riceve notifiche SMS (es. autoradio)'),
  0x1134: ServiceInfo('MAP', 'Message Access', ''),
  0x1200: ServiceInfo('DID', 'PnP Information (Device ID)', 'Vendor/product/versione del dispositivo'),
  0x1203: ServiceInfo('GA', 'Generic Audio', ''),
  0x1800: ServiceInfo('GAP', 'Generic Access (LE)', ''),
  0x1801: ServiceInfo('GATT', 'Generic Attribute (LE)', ''),
  0x184E: ServiceInfo('ASCS', 'Audio Stream Control (LE Audio)', ''),
  0x184F: ServiceInfo('BASS', 'Broadcast Audio Scan (LE Audio)', ''),
};

int? shortUuid(String uuid) {
  final u = uuid.toLowerCase();
  if (u.length == 36 && u.startsWith('0000') && u.endsWith(_base)) {
    return int.tryParse(u.substring(4, 8), radix: 16);
  }
  return null;
}

String uuidFromShort(int short) =>
    '0000${short.toRadixString(16).padLeft(4, '0')}$_base';

ServiceInfo serviceInfo(String uuid) {
  final s = shortUuid(uuid);
  if (s != null && _services.containsKey(s)) return _services[s]!;
  if (s != null) {
    return ServiceInfo('0x${s.toRadixString(16).toUpperCase().padLeft(4, '0')}', 'Servizio standard non in tabella', '');
  }
  return ServiceInfo('vendor', 'Servizio proprietario', uuid);
}

bool hasService(List<String> uuids, int short) => uuids.any((u) => shortUuid(u) == short);

const _majors = {
  0x0000: 'Varie',
  0x0100: 'Computer',
  0x0200: 'Telefono',
  0x0300: 'Rete',
  0x0400: 'Audio/Video',
  0x0500: 'Periferica',
  0x0600: 'Imaging',
  0x0700: 'Indossabile',
  0x0800: 'Giocattolo',
  0x0900: 'Salute',
  0x1F00: 'Non categorizzato',
};

const _deviceClasses = {
  0x0404: 'Cuffia con microfono',
  0x0408: 'Vivavoce',
  0x0410: 'Microfono',
  0x0414: 'Altoparlante',
  0x0418: 'Cuffie',
  0x041C: 'Audio portatile',
  0x0420: 'Autoradio (Car Audio)',
  0x0424: 'Set-top box',
  0x0428: 'Hi-Fi',
  0x043C: 'Display con altoparlanti',
  0x0204: 'Cellulare',
  0x020C: 'Smartphone',
  0x0104: 'Desktop',
  0x010C: 'Laptop',
};

const _serviceBits = {
  13: 'Limited discoverable',
  16: 'Positioning',
  17: 'Networking',
  18: 'Rendering',
  19: 'Capturing',
  20: 'Object transfer',
  21: 'Audio',
  22: 'Telephony',
  23: 'Information',
};

String majorName(int? major) => major == null ? '?' : (_majors[major] ?? '0x${major.toRadixString(16)}');

String deviceClassName(int? dc) =>
    dc == null ? '?' : (_deviceClasses[dc] ?? '0x${dc.toRadixString(16).padLeft(4, '0')}');

List<String> codServiceClasses(int? cod) {
  if (cod == null) return const [];
  return [
    for (final e in _serviceBits.entries)
      if (cod & (1 << e.key) != 0) e.value,
  ];
}

String codHex(int? cod) => cod == null ? '?' : '0x${cod.toRadixString(16).padLeft(6, '0').toUpperCase()}';
