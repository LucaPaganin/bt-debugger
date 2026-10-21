import 'package:flutter/material.dart';

import '../analysis.dart';
import '../app_state.dart';
import '../bt_api.dart';
import '../widgets/event_tile.dart';

class DiagnosisScreen extends StatefulWidget {
  const DiagnosisScreen({super.key});

  @override
  State<DiagnosisScreen> createState() => _DiagnosisScreenState();
}

class _DiagnosisScreenState extends State<DiagnosisScreen> {
  /// id del segnaposto da cui partire; null = ultimo segnaposto; -1 = tutto il log.
  int? _markerId;
  List<String>? _props;

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnosi')),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final markers = sessionMarkers(app.events);
          DateTime? since;
          if (_markerId == null) {
            since = markers.isEmpty ? null : markers.last.ts;
          } else if (_markerId! >= 0) {
            final m = markers.where((e) => e.id == _markerId);
            since = m.isEmpty ? null : m.first.ts;
          }
          final target = app.targetAddress;
          final analysis = target == null ? null : analyzeSession(app.events, target, since: since);
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              if (target == null)
                const Card(
                  margin: EdgeInsets.all(12),
                  child: ListTile(
                    leading: Icon(Icons.star_border),
                    title: Text('Scegli il dispositivo da analizzare'),
                    subtitle: Text('In Dispositivi apri l\'autoradio e premi "Imposta come monitorato".'),
                  ),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text('Analisi di ${app.targetName ?? target}', style: Theme.of(context).textTheme.titleMedium),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DropdownButton<int?>(
                    isExpanded: true,
                    value: _markerId != null && _markerId! >= 0 && !markers.any((m) => m.id == _markerId) ? null : _markerId,
                    items: [
                      const DropdownMenuItem<int?>(value: null, child: Text('Dall\'ultimo segnaposto')),
                      const DropdownMenuItem<int?>(value: -1, child: Text('Tutto il log')),
                      for (final m in markers.reversed)
                        DropdownMenuItem<int?>(
                          value: m.id,
                          child: Text('Da ${fmtDate(m.ts)} — ${m.cat == 'note' ? m.summary : 'avvio monitor'}', overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) => setState(() => _markerId = v),
                  ),
                ),
                for (final f in analysis!.findings) _findingCard(f),
                if (analysis!.aclSessions.isNotEmpty) _aclCard(analysis!.aclSessions),
              ],
              _procedureCard(),
              _snoopCard(),
              _propsCard(),
            ],
          );
        },
      ),
    );
  }

  Widget _findingCard(Finding f) {
    final (icon, color) = switch (f.severity) {
      Severity.ok => (Icons.check_circle, Colors.green),
      Severity.info => (Icons.info, Colors.blueGrey),
      Severity.warn => (Icons.warning_amber, Colors.orange),
      Severity.error => (Icons.error, Colors.red),
    };
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      shape: RoundedRectangleBorder(side: BorderSide(color: color.withValues(alpha: 0.5)), borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(f.title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Padding(padding: const EdgeInsets.only(top: 4), child: Text(f.detail)),
      ),
    );
  }

  Widget _aclCard(List<AclSession> sessions) => Card(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Collegamenti ACL (${sessions.length})', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            for (final s in sessions)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  '${fmtTime(s.start)} → ${s.end == null ? 'ancora aperto' : '${fmtTime(s.end!)} (${(s.duration!.inMilliseconds / 1000).toStringAsFixed(1)} s)'}'
                  '  ·  profili: ${s.profilesUp.isEmpty ? 'nessuno' : s.profilesUp.join(' + ')}',
                ),
              ),
          ]),
        ),
      );

  Widget _procedureCard() => _expCard(
        Icons.checklist,
        'Procedura di test in auto',
        const [
          '1. In Dispositivi apri l\'autoradio e impostala come monitorata. Premi "Rileggi servizi (SDP)" ad autoradio accesa per vedere i profili che dichiara.',
          '2. In Monitor attiva il monitor in background. Su Samsung metti l\'app su batteria "Senza restrizioni", altrimenti One UI può fermarla.',
          '3. Con il Bluetooth del telefono acceso e quadro spento, aggiungi un segnaposto ("Accendo l\'auto") e accendi.',
          '4. Aspetta 1–2 minuti senza toccare nulla. Poi apri questa scheda: l\'analisi parte dall\'ultimo segnaposto.',
          '5. Se non si è connessa, aggiungi un segnaposto ("Connetto a mano"), connetti dalla radio o dal telefono e confronta i due casi.',
          '6. Ripeti con Galaxy Buds/Watch spenti, e dopo aver cambiato AVRCP/MAP nelle opzioni sviluppatore: un segnaposto per ogni prova.',
          '7. Prova il test RFCOMM sicuro dalla scheda del dispositivo: se riesce, la link key è valida e il problema è chi avvia la riconnessione.',
        ],
      );

  Widget _snoopCard() => _expCard(
        Icons.bug_report_outlined,
        'Andare più a fondo: HCI snoop log',
        [
          'Android non espone alle app la versione Bluetooth della radio, i codici di errore LMP né chi ha avviato una connessione. '
              'Queste informazioni stanno nel log HCI, che registra ogni pacchetto tra il sistema e il chip Bluetooth.',
          '1. Opzioni sviluppatore → "Attiva log di analisi HCI Bluetooth" (su Samsung: "Abilitato"). Spegni e riaccendi il Bluetooth.',
          '2. Riproduci il problema in auto (usa i segnaposti per segnare gli orari).',
          '3. Opzioni sviluppatore → "Segnalazione di bug" → completa. Nello zip il file è in FS/data/misc/bluetooth/logs/btsnoop_hci.log (su Samsung a volte in FS/data/log/bt/).',
          '4. Aprilo con Wireshark. Filtri utili: "bthci_evt.code == 0x03" (Connection Complete, con status), "bthci_cmd.opcode == 0x0405" (Create Connection: chi chiama), '
              '"bthci_evt.code == 0x0b || bthci_evt.code == 0x0c" (feature e versione LMP remota), "bthci_evt.code == 0x17 || bthci_evt.code == 0x18" (richiesta/notifica link key).',
          'Cosa cercare: se all\'accensione arriva un "Connection Request" dalla radio; se dopo "Link Key Request" il telefono risponde con la chiave o con "Negative Reply"; il codice di "Disconnection Complete".',
        ],
        trailing: [
          Wrap(spacing: 8, children: [
            OutlinedButton(onPressed: () => BtApi.openSettings('developer'), child: const Text('Opzioni sviluppatore')),
            OutlinedButton(onPressed: () => BtApi.openSettings('bluetooth'), child: const Text('Impostazioni Bluetooth')),
          ]),
        ],
      );

  Widget _propsCard() => Card(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: ExpansionTile(
          leading: const Icon(Icons.tune),
          title: const Text('Proprietà Bluetooth di sistema'),
          subtitle: const Text('Versioni AVRCP/MAP impostate, stato snoop log, codec…'),
          onExpansionChanged: (open) async {
            if (open && _props == null) {
              final p = await BtApi.systemProps();
              if (mounted) setState(() => _props = p);
            }
          },
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_props == null) const LinearProgressIndicator(),
            if (_props != null && _props!.isEmpty) const Text('Nessuna proprietà leggibile.'),
            for (final p in _props ?? const <String>[])
              SelectableText(p, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ],
        ),
      );

  Widget _expCard(IconData icon, String title, List<String> lines, {List<Widget> trailing = const []}) => Card(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: ExpansionTile(
          leading: Icon(icon),
          title: Text(title),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final l in lines) Padding(padding: const EdgeInsets.only(bottom: 8), child: SelectableText(l)),
            ...trailing,
          ],
        ),
      );
}
