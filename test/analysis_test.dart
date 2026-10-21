import 'package:bt_debugger/analysis.dart';
import 'package:bt_debugger/bt_api.dart';
import 'package:bt_debugger/bt_labels.dart';
import 'package:flutter_test/flutter_test.dart';

const radio = 'AA:BB:CC:DD:EE:FF';
var _id = 0;
final _t0 = DateTime(2026, 10, 21, 8, 0, 0);

BtEvent ev(int sec, String cat, String action, String summary,
        {String? address = radio, Map<String, String> extras = const {}, int ms = 0}) =>
    BtEvent(
      id: ++_id,
      ts: _t0.add(Duration(seconds: sec, milliseconds: ms)),
      cat: cat,
      action: action,
      summary: summary,
      address: address,
      extras: extras,
    );

Map<String, String> prof(int prev, int st) => {'profile.extra.PREVIOUS_STATE': '$prev', 'profile.extra.STATE': '$st'};

void main() {
  test('nessun ACL → errore "nessun tentativo"', () {
    final a = analyzeSession([ev(0, 'note', 'NOTE', 'Accendo l\'auto', address: null)], radio);
    expect(a.findings.any((f) => f.severity == Severity.error && f.title.contains('Nessun tentativo')), isTrue);
  });

  test('ACL breve senza profili → link chiuso subito', () {
    final a = analyzeSession([
      ev(0, 'note', 'NOTE', 'x', address: null),
      ev(5, 'acl', 'ACL_CONNECTED', 'Link ACL STABILITO'),
      ev(6, 'acl', 'ACL_DISCONNECTED', 'Link ACL CHIUSO — reason=5'),
    ], radio);
    expect(a.aclSessions.length, 1);
    expect(a.findings.any((f) => f.title == 'Link aperto e chiuso subito'), isTrue);
  });

  test('HFP + A2DP → connessione completa', () {
    final a = analyzeSession([
      ev(5, 'acl', 'ACL_CONNECTED', 'Link ACL STABILITO'),
      ev(6, 'hfp', 'CONNECTION_STATE_CHANGED', 'HFP (vivavoce): CONNECTING → CONNECTED'),
      ev(7, 'a2dp', 'CONNECTION_STATE_CHANGED', 'A2DP (audio): CONNECTING → CONNECTED'),
    ], radio);
    expect(a.findings.any((f) => f.severity == Severity.ok), isTrue);
    expect(a.findings.any((f) => f.severity == Severity.error), isFalse);
  });

  test('bond perso con AUTH_FAILED', () {
    final a = analyzeSession([
      ev(1, 'bond', 'BOND_STATE_CHANGED', 'Bond: BONDED → NONE — motivo: AUTH_FAILED (autenticazione fallita)'),
    ], radio);
    expect(a.findings.first.title, 'Bond perso');
  });

  test('since esclude gli eventi precedenti', () {
    final events = [
      ev(1, 'acl', 'ACL_CONNECTED', 'Link ACL STABILITO'),
      ev(10, 'note', 'NOTE', 'Accendo', address: null),
    ];
    final a = analyzeSession(events, radio, since: events.last.ts);
    expect(a.aclSessions, isEmpty);
  });

  test('decodifica UUID e Class of Device', () {
    expect(serviceInfo('0000111e-0000-1000-8000-00805f9b34fb').code, 'HFP-HF');
    expect(shortUuid(uuidFromShort(0x110B)), 0x110B);
    expect(deviceClassName(0x0420), contains('Autoradio'));
    expect(codServiceClasses(0x240420), containsAll(['Audio', 'Rendering']));
  });

  test('caso Alpine: avviata dal telefono, pairing ripetuto, autenticazione lenta', () {
    final a = analyzeSession([
      ev(0, 'note', 'NOTE', 'Accendo', address: null),
      ev(49, 'a2dp', 'CONNECTION_STATE_CHANGED', 'A2DP (audio): DISCONNECTED → CONNECTING', extras: prof(0, 1)),
      ev(49, 'hfp', 'CONNECTION_STATE_CHANGED', 'HFP (vivavoce): DISCONNECTED → CONNECTING', extras: prof(0, 1)),
      ev(50, 'acl', 'ACL_CONNECTED', 'Link ACL STABILITO'),
      ev(61, 'security', 'ENCRYPTION_CHANGE', 'Cifratura ATTIVA', extras: {'device.extra.ENCRYPTION_ENABLED': 'true'}),
      ev(61, 'bond', 'BOND_STATE_CHANGED', 'Bond: BONDED → BONDING',
          ms: 500, extras: {'device.extra.PREVIOUS_BOND_STATE': '12', 'device.extra.BOND_STATE': '11'}),
      ev(62, 'pairing', 'PAIRING_REQUEST', 'Richiesta di pairing: CONSENT (SSP Just Works)'),
      ev(63, 'hfp', 'CONNECTION_STATE_CHANGED', 'HFP (vivavoce): CONNECTING → DISCONNECTED (motivo 1405)', extras: prof(1, 0)),
      ev(63, 'bond', 'BOND_STATE_CHANGED', 'Bond: BONDING → BONDED'),
      ev(64, 'acl', 'ACL_DISCONNECTED', 'Link ACL CHIUSO — motivo HCI 0x16'),
      ev(64, 'a2dp', 'CONNECTION_STATE_CHANGED', 'A2DP (audio): CONNECTING → DISCONNECTED', extras: prof(1, 0)),
    ], radio);
    final titles = a.findings.map((f) => f.title).toList();
    expect(a.findings.first.title, 'Nuovo pairing a ogni connessione');
    expect(titles, contains('La radio non ha mai avviato la connessione'));
    expect(titles, contains('Autenticazione lenta'));
    expect(a.aclSessions.single.initiator, 'telefono');
  });

  test('caso Jabra: rimbalzo iniziale seguito da connessione riuscita non è un errore', () {
    final a = analyzeSession([
      ev(0, 'acl', 'ACL_CONNECTED', 'Link ACL STABILITO'),
      ev(0, 'acl', 'ACL_DISCONNECTED', 'Link ACL CHIUSO — motivo HCI 0x13', ms: 600),
      ev(1, 'acl', 'ACL_CONNECTED', 'Link ACL STABILITO', ms: 300),
      ev(1, 'hfp', 'CONNECTION_STATE_CHANGED', 'HFP (vivavoce): DISCONNECTED → CONNECTING', ms: 600, extras: prof(0, 1)),
      ev(1, 'hfp', 'CONNECTION_STATE_CHANGED', 'HFP (vivavoce): CONNECTING → CONNECTED', ms: 700, extras: prof(1, 2)),
      ev(4, 'a2dp', 'CONNECTION_STATE_CHANGED', 'A2DP (audio): CONNECTING → CONNECTED', extras: prof(1, 2)),
    ], radio);
    expect(a.findings.any((f) => f.severity == Severity.error), isFalse);
    expect(a.findings.any((f) => f.title == 'Rimbalzo iniziale innocuo'), isTrue);
    expect(a.aclSessions.last.initiator, 'radio');
  });
}
