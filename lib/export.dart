import 'analysis.dart';
import 'app_state.dart';
import 'bt_api.dart';
import 'widgets/event_tile.dart';

/// Testo esportabile del log, con analisi in testa: pensato per essere letto da una persona o incollato in chat.
Future<String> buildExport() async {
  final app = AppState.instance;
  final info = await BtApi.adapterInfo();
  final b = StringBuffer()
    ..writeln('BT Debugger — log esportato ${fmtDate(DateTime.now())}')
    ..writeln('Telefono: ${info['phone']} · Android ${info['android']} · build ${info['build']}')
    ..writeln('Dispositivo monitorato: ${app.targetName ?? '-'} (${app.targetAddress ?? '-'})')
    ..writeln();
  if (app.targetAddress != null) {
    final markers = sessionMarkers(app.events);
    final since = markers.isEmpty ? null : markers.last.ts;
    final a = analyzeSession(app.events, app.targetAddress!, since: since);
    b.writeln('== Analisi dall\'ultimo segnaposto${since == null ? '' : ' (${fmtDate(since)})'} ==');
    for (final f in a.findings) {
      b.writeln('- [${f.severity.name.toUpperCase()}] ${f.title}: ${f.detail}');
    }
    b.writeln();
  }
  b.writeln('== Eventi (${app.events.length}) ==');
  for (final e in app.events) {
    b.writeln('${fmtDate(e.ts)}  [${e.cat}] ${e.summary}${e.who.isEmpty ? '' : '  <${e.who}${e.address != null && e.name != null ? ' ${e.address}' : ''}>'}');
    if (e.extras.isNotEmpty) {
      b.writeln('    ${e.extras.entries.map((x) => '${x.key}=${x.value}').join('  ')}');
    }
  }
  return b.toString();
}

String exportFileName() {
  final n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return 'bt_debugger_${n.year}${two(n.month)}${two(n.day)}_${two(n.hour)}${two(n.minute)}${two(n.second)}.txt';
}
