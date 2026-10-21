import 'package:flutter/material.dart';

import '../app_state.dart';
import '../bt_api.dart';
import '../bt_labels.dart';
import 'device_detail_screen.dart';

/// Scansione Bluetooth Classic: utile per vedere se l'autoradio è visibile e con quale Class of Device.
class ScanScreen extends StatelessWidget {
  const ScanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Scansione')),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final list = app.scanResults.values.toList()
            ..sort((a, b) => (int.tryParse(b.extras['rssi'] ?? '') ?? -999).compareTo(int.tryParse(a.extras['rssi'] ?? '') ?? -999));
          return Column(children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Expanded(
                  child: Text(
                    'Trova i dispositivi Classic visibili nei dintorni (~12 s). L\'autoradio compare solo se è in modalità pairing/visibile.',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: 8),
                app.scanning
                    ? OutlinedButton.icon(onPressed: app.stopScan, icon: const Icon(Icons.stop), label: const Text('Stop'))
                    : FilledButton.icon(onPressed: app.startScan, icon: const Icon(Icons.radar), label: const Text('Scansiona')),
              ]),
            ),
            if (app.scanning) const LinearProgressIndicator(),
            Expanded(
              child: list.isEmpty
                  ? Center(child: Text(app.scanning ? 'Ricerca in corso…' : 'Nessun dispositivo trovato.'))
                  : ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final e = list[i];
                        final dc = int.tryParse(e.extras['deviceClass'] ?? '');
                        final cod = int.tryParse(e.extras['cod'] ?? '');
                        final type = int.tryParse(e.extras['type'] ?? '');
                        final bonded = e.extras['bond'] == '12';
                        return ListTile(
                          leading: Icon(dc == 0x0420 ? Icons.directions_car : Icons.bluetooth_searching),
                          title: Text(e.name ?? e.address ?? '?'),
                          subtitle: Text(
                            '${e.address}  ·  ${deviceClassName(dc)}  ·  CoD ${codHex(cod)}'
                            '${type != null ? '  ·  ${(type >= 0 && type <= 3 ? const ['UNKNOWN', 'CLASSIC', 'LE', 'DUAL'][type] : '?')}' : ''}'
                            '${bonded ? '  ·  accoppiato' : ''}',
                          ),
                          trailing: Text('${e.extras['rssi'] ?? '?'} dBm'),
                          onTap: e.address == null
                              ? null
                              : () {
                                  BtApi.cancelDiscovery();
                                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => DeviceDetailScreen(address: e.address!)));
                                },
                        );
                      },
                    ),
            ),
          ]);
        },
      ),
    );
  }
}
