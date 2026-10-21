import 'package:bt_debugger/bt_api.dart';
import 'package:bt_debugger/discovery.dart';
import 'package:flutter_test/flutter_test.dart';

BtEvent found(String address, Map<String, String> extras, {String action = 'LE_FOUND', String? name}) => BtEvent(
      id: 1,
      ts: DateTime(2026, 10, 21, 20, 0),
      cat: 'scan',
      action: action,
      summary: '',
      address: address,
      name: name,
      extras: extras,
      persist: false,
    );

DiscoveredDevice dev(String address, Map<String, String> extras, {String action = 'LE_FOUND', String? name}) {
  final e = found(address, extras, action: action, name: name);
  return DiscoveredDevice(address, e.ts)..update(e);
}

void main() {
  test('tracker FMDN riconosciuto dal frame 0x40 su 0xFEAA', () {
    final d = dev('5B:3D:5C:9E:A3:42', {'rssi': '-70', 'svcData': '0000feaa-0000-1000-8000-00805f9b34fb:40AABBCC'});
    expect(d.hint, contains('Trova il mio dispositivo'));
    expect(d.isTracker, isTrue);
    expect(d.kind, AddrKind.rotating);
  });

  test('Apple Dov\'è dal tipo 0x12 nei manufacturer data', () {
    final d = dev('C1:22:33:44:55:66', {'mfr': '004C:1219AABB'});
    expect(d.hint, contains('AirTag'));
    expect(d.vendor, 'Apple');
  });

  test('Classic + BLE si fondono sullo stesso indirizzo', () {
    final d = dev('00:0A:08:BD:38:C4', {'rssi': '-50', 'cod': '2360344', 'deviceClass': '1056', 'bond': '12'},
        action: 'FOUND', name: 'Alpine CD Receiver');
    d.update(found('00:0A:08:BD:38:C4', {'rssi': '-55', 'connectable': 'true'}));
    expect(d.classic && d.le, isTrue);
    expect(d.bonded, isTrue);
    expect(d.rssi, -55);
    expect(d.name, 'Alpine CD Receiver');
  });

  test('tipo di indirizzo random dai bit alti', () {
    expect(addrKind('C1:00:00:00:00:00', 1, le: true), AddrKind.staticRandom);
    expect(addrKind('41:00:00:00:00:00', 1, le: true), AddrKind.rotating);
    expect(addrKind('11:00:00:00:00:00', 1, le: true), AddrKind.nonResolvable);
    expect(addrKind('41:00:00:00:00:00', 0, le: true), AddrKind.public);
    expect(addrKind('41:00:00:00:00:00', null, le: false), AddrKind.unknown);
  });

  test('gruppi: nickname per MAC o per nome, accoppiati, sconosciuti', () {
    final jabra = dev('4E:D5:A0:D6:5A:05', {}, name: 'Jabra Evolve2 65');
    final radio = dev('00:0A:08:BD:38:C4', {'bond': '12'}, action: 'FOUND');
    final other = dev('E4:8C:73:97:3F:9A', {}, name: 'Maja');
    final known = [
      const KnownDevice(nickname: 'Cuffie lavoro', matchName: 'Jabra Evolve2 65'),
    ];
    expect(groupOf(jabra, known), DiscoveryGroup.mine);
    expect(groupOf(radio, known), DiscoveryGroup.bonded);
    expect(groupOf(other, known), DiscoveryGroup.unknown);

    final byMac = [const KnownDevice(nickname: 'Autoradio', address: '00:0a:08:bd:38:c4')];
    expect(groupOf(radio, byMac), DiscoveryGroup.mine);
  });

  test('nickname: serializzazione JSON andata e ritorno', () {
    final list = [
      const KnownDevice(nickname: 'Autoradio', address: '00:0A:08:BD:38:C4'),
      const KnownDevice(nickname: 'Cuffie', matchName: 'Jabra'),
    ];
    final back = decodeKnown(encodeKnown(list));
    expect(back.length, 2);
    expect(back[0].address, '00:0A:08:BD:38:C4');
    expect(back[1].matchName, 'Jabra');
    expect(decodeKnown('non json'), isEmpty);
  });
}
