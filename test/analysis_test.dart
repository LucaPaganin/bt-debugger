import 'package:bt_debugger/analysis.dart';
import 'package:bt_debugger/bt_api.dart';
import 'package:bt_debugger/bt_labels.dart';
import 'package:flutter_test/flutter_test.dart';

const radio = 'AA:BB:CC:DD:EE:FF';
var _id = 0;
final _t0 = DateTime(2026, 10, 21, 8, 0, 0);

BtEvent ev(int sec, String cat, String action, String summary, {String? address = radio}) => BtEvent(
      id: ++_id,
      ts: _t0.add(Duration(seconds: sec)),
      cat: cat,
      action: action,
      summary: summary,
      address: address,
    );

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
}
